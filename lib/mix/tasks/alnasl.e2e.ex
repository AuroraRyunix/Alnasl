defmodule Mix.Tasks.Alnasl.E2e do
  @shortdoc "Plays a round of simulated boards into a real results server and checks what arrived"

  @moduledoc """
  The whole chain against a real OpenResults: simulated boards, the tracker,
  the outbox, the server's ingest - and then the server's own PGN of each
  game, fetched and compared move for move with the game that was played.

      mix alnasl.e2e --url http://localhost:4031 --slug live-demo --key orrk_...
      mix alnasl.e2e --url ... --slug ... --key ... --boards 3 --speed 40 --faults rough

  It uses its own data directory (`data/e2e`, emptied first) and serves the
  management site on `--port` (4042) while it runs, so the round can be
  watched. Boards 1 to `--boards` (3) of round `--round` (1) each get a
  simulator playing a bundled game with the hands of `--faults` (`none`,
  `mild`, `rough`); the tournament on the server must have that many boards
  in that round, for the server takes moves only for a board it has.

  While it runs it prints a line every few seconds: how far each board is,
  and how the connection stands. **Stop and start the results server during
  the run** to see the outbox hold and drain - the task does not care, it
  waits (up to `--timeout` seconds, 900) until every game is finished and
  nothing is waiting.

  When a simulated game is over the task sets its result, as the arbiter
  would. Then it fetches `/t/<slug>/live/<round>/<board>/pgn` for each board
  and reports, per board, whether the moves and the result are the ones
  played. The exit status is 0 only if all of them are.
  """

  use Mix.Task

  @faults %{
    "none" => %{},
    "mild" => %{"lift" => 0.08, "hover" => 0.05, "slide" => 0.1, "takeback" => 0.03},
    "rough" => %{
      "lift" => 0.15,
      "knock" => 0.08,
      "hover" => 0.1,
      "slide" => 0.2,
      "takeback" => 0.08,
      "swap" => 0.03,
      "clock_miss" => 0.1
    }
  }

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          url: :string,
          slug: :string,
          key: :string,
          boards: :integer,
          speed: :integer,
          faults: :string,
          round: :integer,
          port: :integer,
          timeout: :integer
        ]
      )

    for required <- [:url, :slug, :key], opts[required] == nil do
      Mix.raise("--#{required} is required. See mix help alnasl.e2e.")
    end

    data = Path.expand("data/e2e")
    File.rm_rf!(data)
    File.mkdir_p!(data)

    Mix.Task.run("app.config")
    Application.put_env(:alnasl, :data_dir, data)

    Application.put_env(
      :alnasl,
      Alnasl.Repo,
      Keyword.put(
        Application.get_env(:alnasl, Alnasl.Repo, []),
        :database,
        Path.join(data, "alnasl.db")
      )
    )

    endpoint = Application.get_env(:alnasl, AlnaslWeb.Endpoint, [])
    http = endpoint |> Keyword.get(:http, []) |> Keyword.put(:port, opts[:port] || 4042)

    Application.put_env(
      :alnasl,
      AlnaslWeb.Endpoint,
      endpoint
      |> Keyword.put(:http, http)
      |> Keyword.put(:server, true)
      |> Keyword.put(:watchers, [])
    )

    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    ok? = play(opts)
    unless ok?, do: exit({:shutdown, 1})
  end

  defp play(opts) do
    alias Alnasl.{Boards, Pgn, Settings, Tournaments}

    round = opts[:round] || 1
    url = Settings.normalize_url(opts[:url])
    Settings.put("box_name", "e2e")

    Tournaments.default()
    |> Tournaments.update!(%{
      server_url: url,
      slug: opts[:slug],
      relay_key: opts[:key],
      round: round
    })

    info("Test connection:")

    for {step, result} <- Alnasl.OpenResults.test(url, opts[:slug], opts[:key]) do
      info("  #{step}: #{inspect(result)}")
    end

    numbers = Enum.to_list(1..(opts[:boards] || 3))

    games =
      Pgn.all_bundled()
      |> Enum.filter(&(length(&1.moves) in 30..90 and &1.result in ["1-0", "0-1", "1/2-1/2"]))
      |> Enum.take(length(numbers))

    faults = Map.get(@faults, opts[:faults] || "mild", @faults["mild"])

    plan =
      for {number, game} <- Enum.zip(numbers, games) do
        [board] =
          Boards.add_simulators(1, round,
            games: [game],
            first: number,
            faults: faults,
            speed: opts[:speed] || 40
          )

        info(
          "board #{number}: #{game.headers["White"]} - #{game.headers["Black"]}, #{length(game.moves)} plies, #{game.result}"
        )

        %{number: number, board: board, game: game}
      end

    info("\nwatch it at http://localhost:#{opts[:port] || 4042}\n")
    deadline = System.monotonic_time(:second) + (opts[:timeout] || 900)
    wait(plan, round, deadline, MapSet.new())
    verify(plan, round, url, opts[:slug])
  end

  # Until every game has its result and nothing waits to be sent.
  defp wait(plan, round, deadline, done) do
    alias Alnasl.{Boards, Outbox}

    snapshots = for p <- plan, do: {p, Boards.snapshot(p.board.id)}

    done =
      Enum.reduce(snapshots, done, fn {p, snap}, done ->
        finished? =
          (snap.player && snap.player.finished?) and length(snap.plies) == length(p.game.moves)

        if finished? and p.number not in done do
          :ok = Boards.set_result(p.board.id, p.game.result)
          MapSet.put(done, p.number)
        else
          done
        end
      end)

    link = Outbox.status()

    progress =
      Enum.map_join(snapshots, "  ", fn {p, snap} ->
        "b#{p.number} #{length(snap.plies)}/#{length(p.game.moves)} #{snap.status}"
      end)

    info("#{progress}  | server: #{link.state}, #{link.pending} waiting")
    stuck = for {p, snap} <- snapshots, snap.status == :out_of_sync, do: p.number

    cond do
      MapSet.size(done) == length(plan) and link.pending == 0 ->
        :ok

      System.monotonic_time(:second) > deadline ->
        info("TIMED OUT (boards out of sync: #{inspect(stuck)})")
        :timeout

      true ->
        Process.sleep(3_000)
        _ = round
        wait(plan, round, deadline, done)
    end
  end

  defp verify(plan, round, url, slug) do
    alias Alnasl.{Log, Outbox, Pgn}

    info("\nWhat the server holds:")

    results =
      for p <- plan do
        path = "#{url}/t/#{slug}/live/#{round}/#{p.number}/pgn"

        case Req.get(path, retry: false) do
          {:ok, %{status: 200, body: body}} ->
            {games, problems} = Pgn.load(to_string(body))
            served = List.first(games)

            moves_ok? =
              served != nil and Pgn.first_difference(served.moves, p.game.moves) == :same

            result_ok? = served != nil and served.result == p.game.result

            info(
              "  board #{p.number}: #{if moves_ok?, do: "moves identical (#{length(p.game.moves)} plies)", else: "MOVES DIFFER #{inspect(served && Pgn.first_difference(served.moves, p.game.moves))}"}, " <>
                "result #{inspect(served && served.result)} #{if result_ok?, do: "as played", else: "EXPECTED #{p.game.result}"}" <>
                if(problems == [], do: "", else: " (unreadable: #{inspect(problems)})")
            )

            moves_ok? and result_ok?

          other ->
            info(
              "  board #{p.number}: could not fetch #{path}: #{inspect(other) |> String.slice(0, 200)}"
            )

            false
        end
      end

    counts = Outbox.counts()
    kinds = Log.list(limit: 5_000) |> Enum.frequencies_by(& &1.kind)

    info("""

    Outbox: #{inspect(counts)}
    Went offline #{kinds["outbox.offline"] || 0} time(s), came back #{kinds["outbox.online"] || 0} time(s).
    Tracker: #{kinds["move.recovered"] || 0} recovery(ies), #{kinds["move.corrected"] || 0} correction(s), #{kinds["board.out_of_sync"] || 0} out-of-sync alarm(s).
    #{if Enum.all?(results), do: "PASS", else: "FAIL"}: #{Enum.count(results, & &1)}/#{length(results)} boards arrived complete and in order.
    """)

    Enum.all?(results)
  end

  defp info(text), do: Mix.shell().info(text)
end

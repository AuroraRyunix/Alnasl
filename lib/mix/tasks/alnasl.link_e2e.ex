defmodule Mix.Tasks.Alnasl.LinkE2e do
  @shortdoc "Runs the board link against a real OpenPairings and checks both ends"

  @moduledoc """
  The link with OpenPairings, end to end, against the real thing: a running
  OpenPairings, a connect code it made, simulated boards on this side.

      mix alnasl.link_e2e --code "http://localhost:4061/api/boards/v1#oplg_..." \\
        --hook "sh tools/link_e2e_hook.sh"

  It uses its own data directory (`data/link-e2e`, emptied first) and serves
  the management site on `--port` (4046) while it runs, so it can be watched.

  ## What it needs on the other side

  A group code (`--code`, the first one given) that reaches at least two
  tournaments with round 1 paired and at least two boards each. More codes
  may be given (`--code` again): they are added and must be accepted.
  `tools/link_e2e_openpairings.exs seed`, run inside an OpenPairings
  checkout on a throwaway database, makes exactly that and prints the codes.

  ## The steps on the other side

  Some of what is checked only happens when an arbiter does something in
  OpenPairings: pairs round 2, swaps two players, adds a tournament to the
  group, withdraws the code. With `--hook CMD` the task runs `CMD <step>`
  at each of those moments (`games`, `pair-round-2`, `clear-result`,
  `restore-result`, `swap`, `add-to-group`, `withdraw`) - a script that runs
  `tools/link_e2e_openpairings.exs <step>` in the OpenPairings checkout.
  Without a hook it says what to do and waits (`--timeout` seconds, 180)
  for a person to do it in OpenPairings' own pages; the checks that read
  OpenPairings' side of things (`games`) are then skipped, and said to be.

  ## What it checks

  The code is accepted and its tournaments arrive with players and round 1;
  two tournaments get two tables each and each board shows its own
  tournament's names; the simulated games are reported, and OpenPairings
  holds them with the result the board saw; round 2 paired there starts
  here, for that tournament only; a result cleared in an earlier round does
  not walk the boards back; two players swapped under games with moves
  flags both, and the arbiter's two answers work; a tournament added to the
  group appears; the same code works through `http://127.0.0.1:<port>` (the
  desktop copy's shape) when the server is on this machine; a withdrawn
  code stops the box asking, with the reason in words.

  The exit status is 0 only if every check passed. It is not part of
  `mix test` and is not run in CI: it needs a second program running.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          code: :keep,
          hook: :string,
          port: :integer,
          speed: :integer,
          timeout: :integer
        ]
      )

    if Keyword.get_values(opts, :code) == [],
      do: Mix.raise("--code is required. See mix help alnasl.link_e2e.")

    data = Path.expand("data/link-e2e")
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
    http = endpoint |> Keyword.get(:http, []) |> Keyword.put(:port, opts[:port] || 4046)

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
    Process.put(:checks, [])

    try do
      play(opts)
    catch
      {:stop, why} -> check("the run got to its end", false, why)
    end

    checks = Enum.reverse(Process.get(:checks))
    failed = Enum.reject(checks, &elem(&1, 1))

    info("""

    #{if failed == [], do: "PASS", else: "FAIL"}: #{length(checks) - length(failed)}/#{length(checks)} checks.
    """)

    for {name, _ok, _detail} <- failed, do: info("  failed: #{name}")
    unless failed == [], do: exit({:shutdown, 1})
  end

  defp info(text), do: Mix.shell().info(text)

  defp check(name, ok?, detail \\ nil) do
    ok? = ok? == true
    Process.put(:checks, [{name, ok?, detail} | Process.get(:checks)])

    info(
      "  #{if ok?, do: "ok  ", else: "FAIL"} #{name}#{if detail, do: " - #{detail}", else: ""}"
    )

    ok?
  end

  # Waits until `fun` is truthy; `nil` when it never was.
  defp wait(opts, fun) do
    deadline = System.monotonic_time(:second) + (opts[:timeout] || 180)
    wait_until(fun, deadline)
  end

  defp wait_until(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:second) > deadline do
          nil
        else
          Process.sleep(500)
          wait_until(fun, deadline)
        end

      value ->
        value
    end
  end

  # Something an arbiter does in OpenPairings: the hook does it, or a person.
  defp other_side(opts, step, instruction) do
    case opts[:hook] do
      nil ->
        info("\n  >>> In OpenPairings now: #{instruction}")
        nil

      hook ->
        {out, status} = System.shell(hook <> " " <> step, stderr_to_stdout: true)

        if status != 0,
          do: throw({:stop, "the hook failed at #{step}: #{String.slice(out, -400, 400)}"})

        out
    end
  end

  defp play(opts) do
    alias Alnasl.{Boards, Games, OpenPairings, Pgn, Repo, Tables, Tournaments}
    alias Alnasl.Destination.OpenPairings, as: Reports
    alias Alnasl.OpenPairings.{Client, Code}
    alias Alnasl.Tournaments.Link

    Alnasl.Settings.put("box_name", "link-e2e")

    # --- 1. the codes ---------------------------------------------------------
    info("\n1. Connect codes")

    for {code, index} <- Enum.with_index(Keyword.get_values(opts, :code), 1) do
      case OpenPairings.add_code(code) do
        {:ok, link, found} ->
          check(
            "code #{index} is accepted",
            true,
            "#{AlnaslWeb.LinkWords.about(link)}, #{length(found)} tournament(s), #{link.server_name} #{link.server_version}"
          )

        other ->
          check("code #{index} is accepted", false, inspect(other) |> String.slice(0, 300))
          throw({:stop, "no link"})
      end
    end

    [link | _] = Tournaments.links()
    arrived = Tournaments.of_link(link)

    for t <- Tournaments.list(), t.kind == "linked" do
      info(
        "     #{Tournaments.title(t)}: round #{inspect(t.remote_round)}, " <>
          "#{length(Tournaments.boards(t.id, t.remote_round || 1))} board(s), " <>
          "#{Tournaments.info(t.id).time_control || "no rate of play"}, " <>
          if(Tournaments.openresults_configured?(t),
            do: "results page #{t.server_url} #{t.slug}",
            else: "no results page"
          )
      )
    end

    unless check(
             "the first code reaches two tournaments with round 1 paired",
             length(arrived) >= 2 and
               Enum.all?(Enum.take(arrived, 2), &(length(Tournaments.boards(&1.id, 1)) >= 2)),
             "#{length(arrived)} arrived"
           ),
           do: throw({:stop, "the other side is not set up as the task needs"})

    [first, second | _] = arrived
    check("round 1 is the round on", first.remote_round == 1 and first.round == 1)

    # --- 2. tables -------------------------------------------------------------
    info(
      "\n2. Tables 1-2 play in #{Tournaments.title(first)}, 3-4 in #{Tournaments.title(second)}"
    )

    games =
      Pgn.all_bundled()
      |> Enum.filter(&(length(&1.moves) in 20..60 and &1.result in ["1-0", "0-1", "1/2-1/2"]))
      |> Enum.take(4)

    boards =
      for {game, n} <- Enum.with_index(games, 1) do
        {:ok, board} =
          Boards.create(%{
            name: "Sim #{n}",
            driver: "simulator",
            port: "sim-#{n}",
            enabled: false,
            options: %{
              "speed" => opts[:speed] || 60,
              "faults" => %{},
              "seed" => n,
              "start_delay_ms" => 2_000 * n,
              "moves" => game.moves,
              "start_fen" => game[:start_fen]
            }
          })

        {:ok, board} = Tables.set_table(board, n)
        %{id: board.id, game: game, table: n}
      end

    {:ok, _} = Tournaments.assign_tables(first, 1, 2)
    {:ok, _} = Tournaments.assign_tables(second, 3, 4)
    for b <- boards, do: Boards.connect(Boards.get!(b.id))

    expected = fn b ->
      t = if b.table <= 2, do: first, else: second
      no = if b.table <= 2, do: b.table, else: b.table - 2
      {t, no, Tournaments.board(t.id, 1, no)}
    end

    for b <- boards do
      {t, no, pairing} = expected.(b)
      row = Boards.get!(b.id)

      named =
        wait(opts, fn ->
          snap = Boards.snapshot(b.id)
          snap.white == pairing.white and snap.black == pairing.black
        end)

      check(
        "table #{b.table} is board #{no} of #{Tournaments.title(t)} with its names",
        {row.tournament_id, row.round, row.board_no} == {t.id, 1, no} and named == true,
        "#{pairing.white} - #{pairing.black}"
      )
    end

    # --- 3. the games -----------------------------------------------------------
    info("\n3. Four simulated games, reported as they are played")

    played =
      wait(opts, fn ->
        Enum.all?(boards, fn b ->
          snap = Boards.snapshot(b.id)

          done? =
            (snap.player && snap.player.finished?) and length(snap.plies) == length(b.game.moves)

          if done? and snap.game_status != "finished", do: Boards.set_result(b.id, b.game.result)
          done? and snap.game_status == "finished"
        end)
      end)

    check("every game was followed to its last move and given its result", played == true)
    sent = wait(opts, fn -> Reports.pending_count() == 0 end)

    check(
      "nothing waits for OpenPairings, and nothing was refused",
      sent == true and Reports.refused() == [],
      inspect(Alnasl.Destination.status(Reports) |> Map.take([:state, :pending, :last_error]))
    )

    held =
      other_side(opts, "games", "(nothing: the games held there are not read without a hook)")

    if held do
      for b <- boards do
        {t, no, _pairing} = expected.(b)
        game = Games.current(t.id, 1, no)
        line = held |> String.split("\n") |> Enum.find(&String.contains?(&1, game.remote_game))
        fields = if line, do: String.split(String.trim(line), "|"), else: []

        check(
          "OpenPairings holds #{Tournaments.title(t)} board #{no}: the moves, finished, and the result the board saw",
          match?(
            [_name, _uid, plies, "finished", result | _]
            when is_binary(plies) and is_binary(result),
            fields
          ) and Enum.at(fields, 2) == to_string(length(b.game.moves)) and
            Enum.at(fields, 4) == b.game.result,
          line || "not there"
        )
      end
    else
      info("     (skipped: what OpenPairings holds is only read with --hook)")
    end

    # --- 4. round 2 -------------------------------------------------------------
    info("\n4. Round 2 is paired in OpenPairings")

    other_side(
      opts,
      "pair-round-2",
      "enter the results of round 1 of #{Tournaments.title(first)} and pair round 2."
    )

    started = wait(opts, fn -> Tournaments.get(first.id).round == 2 end)
    check("the box started round 2 of #{Tournaments.title(first)} by itself", started == true)

    for b <- boards do
      row = Boards.get!(b.id)

      if b.table <= 2 do
        pairing = Tournaments.board(first.id, 2, b.table)

        named =
          pairing &&
            wait(opts, fn ->
              snap = Boards.snapshot(b.id)
              snap.round == 2 and snap.white == pairing.white and snap.black == pairing.black
            end)

        check(
          "table #{b.table} shows round 2 with its names",
          named == true,
          pairing && "#{pairing.white} - #{pairing.black}"
        )
      else
        check(
          "table #{b.table} (#{Tournaments.title(second)}) was not touched",
          {row.tournament_id, row.round} == {second.id, 1}
        )
      end
    end

    check(
      "#{Tournaments.title(second)} is still on round 1",
      Tournaments.get(second.id).round == 1
    )

    # --- 5. a pairing changed under a game --------------------------------------
    info("\n5. Moves in round 2, then two players are swapped in OpenPairings")
    [one, two | _] = boards
    for b <- [one, two], do: Boards.append(b.id, ~w(e4 e5))

    begun =
      wait(opts, fn ->
        Enum.all?([1, 2], &(Games.sans(Games.current(first.id, 2, &1)) == ~w(e4 e5))) and
          Reports.pending_count() == 0
      end)

    check(
      "both round 2 games have moves and are reported",
      begun == true and Reports.refused() == []
    )

    other_side(
      opts,
      "clear-result",
      "clear one result of round 1 of #{Tournaments.title(first)}."
    )

    # An OpenPairings with the mended rule never says so: a short wait.
    back = wait([timeout: 12], fn -> Tournaments.get(first.id).remote_round == 1 end)
    Process.sleep(1_500)

    check(
      "a result cleared in round 1 does not walk the boards back",
      Tournaments.get(first.id).round == 2 and Boards.get!(one.id).round == 2,
      if(back,
        do: "OpenPairings said round 1 was on",
        else: "OpenPairings went on saying round 2"
      )
    )

    other_side(opts, "restore-result", "enter that result again.")
    wait(opts, fn -> Tournaments.get(first.id).remote_round == 2 end)

    names = for n <- [1, 2], g = Games.current(first.id, 2, n), do: {g.white, g.black}

    other_side(
      opts,
      "swap",
      "in round 2 of #{Tournaments.title(first)}, swap the White players of boards 1 and 2."
    )

    flagged =
      wait(opts, fn ->
        Enum.all?([1, 2], &(Games.current(first.id, 2, &1).pairing_flag == "changed"))
      end)

    check("both games are flagged 'pairing changed'", flagged == true)

    check(
      "they kept their moves and the names they had",
      Enum.all?([1, 2], &(Games.sans(Games.current(first.id, 2, &1)) == ~w(e4 e5))) and
        names == for(n <- [1, 2], g = Games.current(first.id, 2, n), do: {g.white, g.black})
    )

    {:ok, adopted} = Boards.adopt_pairing(Games.current(first.id, 2, 1))
    now = Tournaments.board(first.id, 2, 1)

    check(
      "'These moves are that game': board 1 carries the new names",
      {adopted.white, adopted.black} == {now.white, now.black} and adopted.pairing_flag == nil,
      "#{adopted.white} - #{adopted.black}"
    )

    Boards.set_aside(Games.current(first.id, 2, 2))
    history = Games.history(first.id, 2, 2)

    check(
      "'Set it aside': board 2 has the old game kept and a new one for the new pairing",
      match?([%{local: true}, %{local: false, game_no: 2, pairing_flag: nil}], history)
    )

    again = wait(opts, fn -> Reports.pending_count() == 0 end)

    check(
      "the adopted game is reported under the new pairing and taken",
      again == true and not Enum.any?(Reports.refused(), fn {g, _} -> g.id == adopted.id end),
      inspect(Enum.map(Reports.refused(), fn {g, m} -> {g.round, g.board_no, m} end))
    )

    # --- 6. the group grows -----------------------------------------------------
    info("\n6. A tournament is added to the group")
    before = length(Tournaments.of_link(link))
    other_side(opts, "add-to-group", "add another tournament (round 1 paired) to the group.")
    grown = wait(opts, fn -> length(Tournaments.of_link(link)) > before end)

    check(
      "it appears on the box without a new code",
      grown == true,
      Tournaments.of_link(link) |> Enum.map_join(", ", &Tournaments.title/1)
    )

    # --- 7. the desktop copy's shape --------------------------------------------
    info("\n7. The same code through http://127.0.0.1")
    uri = URI.parse(link.root)

    if uri.host in ["localhost", "127.0.0.1"] do
      loopback = %Link{link | root: "http://127.0.0.1:#{uri.port}#{uri.path}"}

      check(
        "plain http on loopback, as a desktop copy's code reads",
        match?({:ok, %{"api" => 1}, _etag}, Client.listing(loopback)) and
          match?(
            {:ok, %{root: "http://127.0.0.1" <> _}},
            Code.parse(loopback.root <> "#" <> link.secret)
          ),
        loopback.root
      )
    else
      info("     (skipped: OpenPairings is not on this machine)")
    end

    # --- 8. the code is withdrawn -----------------------------------------------
    info("\n8. The code is withdrawn in OpenPairings")
    other_side(opts, "withdraw", "withdraw the group's connect code (Settings, Live boards).")
    refused = wait(opts, fn -> Repo.get!(Link, link.id).state == "unauthorized" end)
    link = Repo.get!(Link, link.id)

    check(
      "the box stops asking and says why",
      refused == true and not OpenPairings.polled?(link),
      AlnaslWeb.LinkWords.why(link)
    )

    Boards.append(one.id, ~w(Nf3))
    Process.sleep(3_000)
    status = Alnasl.Destination.status(Reports)

    check(
      "the sender is refused too, and keeps what it has",
      status.state == :blocked and status.pending >= 1,
      "#{inspect(status.state)}, #{status.pending} waiting: #{AlnaslWeb.DestinationWords.error(status.last_error)}"
    )

    check(
      "the pairings are still on the box",
      length(Tournaments.boards(first.id, 2)) >= 2
    )

    for other <- Tournaments.links(), other.id != link.id do
      check("the other code still works", match?({:ok, _}, OpenPairings.poll(other, force: true)))
    end

    :ok
  end
end

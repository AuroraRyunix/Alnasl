defmodule Mix.Tasks.Alnasl.Demo do
  @shortdoc "Starts Alnasl with simulator boards playing bundled games: the whole site, no hardware"

  @moduledoc """
  The management site with a round in progress and nothing plugged in.

      mix alnasl.demo
      mix alnasl.demo --boards 12 --speed 30 --port 4040
      mix alnasl.demo --faults rough
      mix alnasl.demo --faults bullet --speed 1

  Starts the application on its own data directory (`data/demo`, emptied on
  every run unless `--keep`), makes up a tournament from the players of the
  bundled games, adds `--boards` (8) simulator boards that play those games
  `--speed` (12) times faster than life with the hands of `--faults`
  (`none`, `mild` - the default - `rough`, or `bullet`: fast play, a move
  every 0.3-2 seconds with slammed and knocked-over pieces, best watched at
  `--speed 1`), links them to boards 1..N of round 1, and prints the
  address to open.

  One of the boards is made to go wrong on purpose (`--no-trouble` to leave
  that out): on the last board a player makes an illegal move at move 9 and
  plays on, so there is an "Out of sync" board to open and repair.

  No results server is set up - the connection badge says "Not set up" and
  the outbox keeps everything, which is itself worth seeing. To send to a
  real server, give all three of `--server`, `--slug` and `--key`: the
  made-up tournament's moves then go to that results page. A tournament of
  OpenPairings is added on the Setup page of the running demo, with its
  connect code.

  Stop it with Ctrl+C twice.
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
      "missed" => 0.05,
      "clock_miss" => 0.1
    }
  }

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          boards: :integer,
          speed: :integer,
          port: :integer,
          faults: :string,
          keep: :boolean,
          trouble: :boolean,
          server: :string,
          slug: :string,
          key: :string
        ]
      )

    count = opts[:boards] || 8
    port = opts[:port] || String.to_integer(System.get_env("PORT", "4040"))
    data = Path.expand("data/demo")

    unless opts[:keep], do: File.rm_rf!(data)
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
    http = endpoint |> Keyword.get(:http, []) |> Keyword.put(:port, port)

    Application.put_env(
      :alnasl,
      AlnaslWeb.Endpoint,
      endpoint |> Keyword.put(:http, http) |> Keyword.put(:server, true)
    )

    # The page needs its script and stylesheet; build them once here so the
    # demo does not depend on a watcher having run.
    Mix.Task.run("esbuild.install", ["--if-missing"])
    Mix.Task.run("esbuild", ["alnasl"])
    Mix.Task.run("app.start")

    unless opts[:keep] && Alnasl.Boards.list() != [] do
      set_up(count, opts)
    end

    Mix.shell().info("""

    Alnasl demo: #{count} simulated boards, round 1.

        http://localhost:#{port}

    Data in #{data}. Ctrl+C twice stops it.
    """)

    unless iex?(), do: Process.sleep(:infinity)
  end

  defp iex?, do: Code.ensure_loaded?(IEx) and IEx.started?()

  defp set_up(count, opts) do
    alias Alnasl.{Boards, Pgn, Settings, Tournaments}

    # Not the very short ones: a demo should last a few minutes.
    games = Pgn.all_bundled() |> Enum.filter(&(length(&1.moves) >= 40)) |> Enum.take(count)
    count = length(games)
    Settings.put("box_name", "Demo")
    own = Tournaments.default()
    Tournaments.set_round(own.id, 1)
    {:ok, own} = Tournaments.import_snapshot(own, snapshot(games))

    if opts[:server] && opts[:slug] && opts[:key] do
      Tournaments.update!(own, %{
        server_url: Settings.normalize_url(opts[:server]),
        slug: opts[:slug],
        relay_key: opts[:key]
      })
    end

    bullet? = opts[:faults] == "bullet"
    faults = if bullet?, do: %{}, else: Map.get(@faults, opts[:faults] || "mild", @faults["mild"])

    boards =
      Boards.add_simulators(count, 1,
        games: games,
        faults: faults,
        profile: if(bullet?, do: "bullet"),
        speed: opts[:speed] || 12
      )

    # One board on which a player makes an illegal move and plays on.
    if Keyword.get(opts, :trouble, true) and boards != [] do
      board = List.last(boards)
      options = board |> Alnasl.Boards.Board.options() |> Map.put("illegal_at", 17)
      {:ok, _board} = Boards.update(board, %{options: options})
    end

    :ok
  end

  # A tournament made of the bundled games' own players, so the tiles carry
  # names. Shaped like the public snapshot of a results server.
  defp snapshot(games) do
    players =
      games
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {game, n} ->
        [
          %{"no" => n * 2 - 1, "name" => game.headers["White"] || "White #{n}"},
          %{"no" => n * 2, "name" => game.headers["Black"] || "Black #{n}"}
        ]
      end)

    %{
      "tournament" => %{"name" => "Classics, replayed", "city" => "Alnasl demo"},
      "players" => players,
      "rounds" => [
        %{
          "number" => 1,
          "boards" =>
            for(
              n <- 1..max(length(games), 1),
              do: %{"board" => n, "white" => n * 2 - 1, "black" => n * 2, "result" => nil}
            )
        }
      ]
    }
  end
end

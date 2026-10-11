defmodule Alnasl.Games do
  @moduledoc """
  The games of the rounds, as the box holds them: the move list with its
  flags and clock times, the result, and the PGN written from them.

  A game is found by `(round, board_no)` - the same pair the results server
  keys it by. It exists from the moment a board is linked to it (or a PGN is
  attached), and every change is in the database before anything else
  happens with it.
  """

  import Ecto.Query

  alias Alnasl.{Chess, Paths, Pgn, Repo, Settings, Tournament}
  alias Alnasl.Games.Game

  @flags %{
    "recovered" => :recovered,
    "guessed" => :guessed,
    "long_gap" => :long_gap,
    "assumed" => :assumed,
    "unseen" => :unseen,
    "arbiter" => :arbiter,
    "imported" => :imported
  }

  def get(round, board_no), do: Repo.get_by(Game, round: round, board_no: board_no)
  def get!(id), do: Repo.get!(Game, id)

  def list(round) do
    Game |> where([g], g.round == ^round) |> order_by([g], g.board_no) |> Repo.all()
  end

  def rounds do
    Game |> select([g], g.round) |> distinct(true) |> order_by([g], g.round) |> Repo.all()
  end

  @doc "The game of that board of that round, made if it is not there yet. Player names are refreshed."
  def ensure(round, board_no, attrs \\ %{}) do
    names = Map.take(Map.new(attrs), [:white, :black, :start_fen])

    case get(round, board_no) do
      nil ->
        %Game{round: round, board_no: board_no}
        |> Game.changeset(names)
        |> Repo.insert!()

      game ->
        names =
          Map.reject(names, fn {key, value} ->
            value in [nil, ""] or (key == :start_fen and game.plies != "[]")
          end)

        game |> Game.changeset(names) |> Repo.update!()
    end
  end

  # --- moves -------------------------------------------------------------------

  @doc "The plies of a game: `[%{san, flags, at, clock}]`."
  def plies(%Game{plies: json}) do
    json
    |> Jason.decode!()
    |> Enum.map(fn ply ->
      %{
        san: ply["san"],
        flags: for(flag <- ply["flags"] || [], is_map_key(@flags, flag), do: @flags[flag]),
        at: ply["at"],
        clock:
          case ply["clock"] do
            %{} = clock -> %{white_ms: clock["white_ms"], black_ms: clock["black_ms"]}
            _none -> nil
          end
      }
    end)
  end

  def sans(%Game{} = game), do: game |> plies() |> Enum.map(& &1.san)

  @doc "The FEN after the last move, and the squares of that move (`{from, to}` or `nil`)."
  def position(%Game{} = game) do
    start = game.start_fen || Chess.start_fen()

    case Chess.replay(start, sans(game)) do
      {:ok, []} ->
        {start, nil}

      {:ok, played} ->
        before = if length(played) > 1, do: Enum.at(played, -2).fen, else: start
        {List.last(played).fen, Chess.last_squares(before, List.last(played).san)}

      _broken ->
        {start, nil}
    end
  end

  @doc """
  Applies what the tracker reported to the stored game. `now` is wall-clock
  milliseconds: a ply is stamped with the time it was accepted. Returns the
  game and whether the server must be told to replace what it holds.
  """
  def apply_event(%Game{} = game, event, now) do
    current = Jason.decode!(game.plies)

    case event do
      {:moves, plies} ->
        {save(game, %{plies: current ++ encode(plies, now)}), false}

      {:correction, keep, plies, _reason} ->
        {save(game, %{plies: Enum.take(current, keep) ++ encode(plies, now)}), true}

      {:restart, fen} ->
        fen = if fen == Chess.start_fen(), do: nil, else: fen
        {save(game, %{plies: [], start_fen: fen}), true}
    end
  end

  defp encode(plies, now) do
    Enum.map(plies, fn ply ->
      %{
        "san" => ply.san,
        "flags" => Enum.map(ply[:flags] || [], &Atom.to_string/1),
        "at" => now,
        "clock" => ply[:clock]
      }
    end)
  end

  defp save(game, changes) do
    changes =
      case changes do
        %{plies: plies} when is_list(plies) -> %{changes | plies: Jason.encode!(plies)}
        other -> other
      end

    # `start_fen: nil` is a change too, which `cast` would drop.
    game
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
    |> tap(&write_pgn/1)
  end

  @doc "Replaces the whole game by moves read from a PGN: a game that was not captured."
  def attach(%Game{} = game, sans, result, start_fen \\ nil) do
    plies = Enum.map(sans, &%{"san" => &1, "flags" => ["imported"], "at" => nil, "clock" => nil})

    save(game, %{
      plies: plies,
      start_fen: start_fen,
      source: "pgn",
      status: "finished",
      result: result,
      suggestion: nil,
      finished_at: DateTime.utc_now(:second)
    })
  end

  # --- result and state --------------------------------------------------------

  def finish(%Game{} = game, result) when result in ["1-0", "0-1", "1/2-1/2", "*"] do
    save(game, %{
      status: "finished",
      result: result,
      suggestion: nil,
      finished_at: game.finished_at || DateTime.utc_now(:second)
    })
  end

  def reopen(%Game{} = game), do: save(game, %{status: "live", result: nil, finished_at: nil})
  def suggest(%Game{} = game, result), do: save(game, %{suggestion: result})
  def pause(%Game{} = game, paused?), do: save(game, %{paused: paused?})

  def remember_clock(%Game{} = game, nil), do: game

  def remember_clock(%Game{} = game, reading) do
    game |> Ecto.Changeset.change(%{clock: Jason.encode!(reading)}) |> Repo.update!()
  end

  # --- what the server is told -------------------------------------------------

  @doc """
  The body of a live-boards update for this game: the whole move list, every
  time (docs/live-boards-api.md). `clock` is a reading or `nil`.
  """
  def body(%Game{} = game, clock \\ nil, replace? \\ false) do
    %{"round" => game.round, "board" => game.board_no, "moves" => sans(game)}
    |> put_if("start_fen", game.start_fen)
    |> put_clock(clock, game.status)
    |> put_if("status", if(game.status == "finished", do: "finished"))
    |> put_if("result", if(game.status == "finished", do: game.result))
    |> put_if("replace", if(replace?, do: true))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp put_clock(map, nil, _status), do: map

  defp put_clock(map, clock, status) do
    running = if status == "finished", do: :none, else: clock[:running] || :none

    map
    |> put_if("white_ms", clock[:white_ms])
    |> put_if("black_ms", clock[:black_ms])
    |> Map.put("running", Atom.to_string(running))
  end

  # --- PGN ---------------------------------------------------------------------

  @doc "The game as PGN, with the clock after a move as a `[%clk]` comment."
  def pgn(%Game{} = game) do
    plies = plies(game)
    info = Tournament.info()

    date =
      case List.first(plies) do
        %{at: at} when is_integer(at) ->
          at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y.%m.%d")

        _none ->
          Calendar.strftime(game.inserted_at || DateTime.utc_now(), "%Y.%m.%d")
      end

    mover = fn index -> if rem(index, 2) == 0, do: :white_ms, else: :black_ms end
    offset = if black_first?(game), do: 1, else: 0

    Pgn.write(%{
      headers: [
        {"Event", info.name || Settings.get("slug") || "?"},
        {"Site", info.city || "?"},
        {"Date", date},
        {"Round", Integer.to_string(game.round)},
        {"White", game.white || "?"},
        {"Black", game.black || "?"},
        {"Board", Integer.to_string(game.board_no)}
      ],
      moves: Enum.map(plies, & &1.san),
      clocks:
        plies
        |> Enum.with_index()
        |> Enum.map(fn {ply, index} -> ply.clock && ply.clock[mover.(index + offset)] end),
      result: if(game.status == "finished", do: game.result || "*", else: "*"),
      start_fen: game.start_fen
    })
  end

  defp black_first?(%Game{start_fen: nil}), do: false

  defp black_first?(%Game{start_fen: fen}) do
    match?({:ok, %{turn: :b}}, Chess.parse_fen(fen))
  end

  @doc "Every game of a round as one PGN file."
  def round_pgn(round), do: round |> list() |> Enum.map_join("\n", &pgn/1)

  @doc "Where a game's PGN is kept on the box."
  def pgn_path(%Game{} = game) do
    dir = Path.join(Paths.pgn(), "round-#{game.round}")
    File.mkdir_p!(dir)
    Path.join(dir, "board-#{game.board_no}.pgn")
  end

  # Written on every change, through a temporary file: a power cut leaves
  # the old PGN or the new one, never half of one.
  defp write_pgn(%Game{} = game) do
    path = pgn_path(game)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, pgn(game)), :ok <- File.rename(tmp, path) do
      :ok
    else
      _error -> :error
    end
  rescue
    _error -> :error
  end
end

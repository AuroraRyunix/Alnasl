defmodule Alnasl.Games do
  @moduledoc """
  The games of the rounds, as the box holds them: the move list with its
  flags and clock times, the result, and the PGN written from them.

  A game is found by tournament, round and board - within a tournament the
  same pair the results server keys it by. It exists from the moment a
  board is linked to it (or a PGN is attached), and every change is in the
  database before anything else happens with it.
  """

  import Ecto.Query

  alias Alnasl.{Chess, Paths, Pgn, Repo, Tournaments}
  alias Alnasl.Games.Game

  @flags %{
    "recovered" => :recovered,
    "guessed" => :guessed,
    "rewritten" => :rewritten,
    "alone" => :alone,
    "long_gap" => :long_gap,
    "assumed" => :assumed,
    "unseen" => :unseen,
    "arbiter" => :arbiter,
    "imported" => :imported
  }

  # --- finding a game ----------------------------------------------------------

  @doc "The game being played on that board of that round of that tournament: the last one begun there."
  def current(tournament_id, round, board_no),
    do: tournament_id |> history(round, board_no) |> List.last()

  @doc "One particular game of that board, by its number (from 1)."
  def fetch(tournament_id, round, board_no, game_no) do
    Repo.get_by(Game,
      tournament_id: tournament_id,
      round: round,
      board_no: board_no,
      game_no: game_no
    )
  end

  def get!(id), do: Repo.get!(Game, id)

  @doc "Every game that board of that round has seen, in the order they were played."
  def history(tournament_id, round, board_no) do
    Game
    |> where(
      [g],
      g.tournament_id == ^tournament_id and g.round == ^round and g.board_no == ^board_no
    )
    |> order_by([g], g.game_no)
    |> Repo.all()
  end

  @doc "The games of a round of a tournament, one a board: the one being played there."
  def list(tournament_id, round) do
    tournament_id
    |> all(round)
    |> Enum.group_by(& &1.board_no)
    |> Enum.map(fn {_board_no, games} -> List.last(games) end)
    |> Enum.sort_by(& &1.board_no)
  end

  @doc "Every game of a round of a tournament, earlier games on a board included."
  def all(tournament_id, round) do
    Game
    |> where([g], g.tournament_id == ^tournament_id and g.round == ^round)
    |> order_by([g], [g.board_no, g.game_no])
    |> Repo.all()
  end

  @doc "The rounds a tournament has games of."
  def rounds(tournament_id) do
    Game
    |> where([g], g.tournament_id == ^tournament_id)
    |> select([g], g.round)
    |> distinct(true)
    |> order_by([g], g.round)
    |> Repo.all()
  end

  # The same, for the box's own tournament: what "round 3, board 2" means on
  # a box that serves one.

  @doc "`current/3` in the box's own tournament."
  def get(round, board_no), do: current(Tournaments.default_id(), round, board_no)

  @doc "`fetch/4` in the box's own tournament."
  def get(round, board_no, game_no),
    do: fetch(Tournaments.default_id(), round, board_no, game_no)

  def history(round, board_no), do: history(Tournaments.default_id(), round, board_no)
  def list(round), do: list(Tournaments.default_id(), round)
  def all(round), do: all(Tournaments.default_id(), round)
  def rounds, do: rounds(Tournaments.default_id())
  def round_pgn(round), do: round_pgn(Tournaments.default_id(), round)

  def ensure(round, board_no), do: ensure(Tournaments.default_id(), round, board_no, %{})

  def ensure(round, board_no, %{} = attrs),
    do: ensure(Tournaments.default_id(), round, board_no, attrs)

  @doc """
  A new game on the board of `game`: the next number, the same players, no
  moves. The game before it is left as it is - finished, or not. The new
  one stays on the box: the places games go to have room for one a board.
  """
  def next(%Game{} = game) do
    %Game{
      tournament_id: game.tournament_id,
      round: game.round,
      board_no: game.board_no,
      game_no: game.game_no + 1
    }
    |> Game.changeset(%{white: game.white, black: game.black, local: true})
    |> Repo.insert!()
  end

  @doc """
  What a pairing (`Alnasl.Tournaments.board/3`) says about a game: the names,
  and - for a pairing program's - the game's id there and its two players.
  """
  def pairing_attrs(nil), do: %{}

  def pairing_attrs(%{} = pairing) do
    %{
      white: pairing[:white],
      black: pairing[:black],
      remote_game: pairing[:game],
      remote_white: pairing[:white_id],
      remote_black: pairing[:black_id]
    }
  end

  @doc """
  The game of that board of that round, made if it is not there yet.

  Names given are filled in. What a pairing program says about the game
  (`remote_game` and its players) is taken when the game is new or has
  nothing to contradict it; a game that already belongs to another pairing
  is left as it is - that is `Alnasl.OpenPairings.Sync`'s to judge, and
  the arbiter's.
  """
  def ensure(tournament_id, round, board_no, attrs) do
    attrs = Map.new(attrs)

    case current(tournament_id, round, board_no) do
      nil ->
        %Game{tournament_id: tournament_id, round: round, board_no: board_no}
        |> Game.changeset(
          Map.take(attrs, [:white, :black, :start_fen, :remote_game, :remote_white, :remote_black])
        )
        |> Repo.insert!()

      game ->
        names =
          attrs
          |> Map.take([:white, :black, :start_fen])
          |> Map.reject(fn {key, value} ->
            value in [nil, ""] or (key == :start_fen and game.plies != "[]")
          end)

        cond do
          # A game kept on the box is nobody's pairing.
          game.local ->
            game

          # Another pairing than the one this game was begun for.
          attrs[:remote_game] != nil and game.remote_game != nil and
              not same_pairing?(game, attrs) ->
            game

          attrs[:remote_game] != nil ->
            game
            |> Game.changeset(
              Map.merge(names, Map.take(attrs, [:remote_game, :remote_white, :remote_black]))
            )
            |> Repo.update!()

          true ->
            game |> Game.changeset(names) |> Repo.update!()
        end
    end
  end

  @doc "Is the game the one that pairing describes: the same id there, the same two players, the same colours?"
  def same_pairing?(%Game{} = game, attrs) do
    game.remote_game == attrs[:remote_game] and game.remote_white == attrs[:remote_white] and
      game.remote_black == attrs[:remote_black]
  end

  @doc "Has anything been played in it?"
  def begun?(%Game{plies: plies}), do: plies != "[]"

  @doc """
  The game is taken to be the one `pairing` describes: its names, its id at
  the pairing program, its players. With `nil`, the game is nobody's.
  Clears a pairing flag.
  """
  def adopt(%Game{} = game, pairing) do
    attrs =
      Map.merge(
        %{white: nil, black: nil, remote_game: nil, remote_white: nil, remote_black: nil},
        pairing_attrs(pairing)
      )

    game
    |> Ecto.Changeset.change(Map.put(attrs, :pairing_flag, nil))
    |> Repo.update!()
    |> tap(&write_pgn/1)
  end

  @doc "Marks a game whose pairing changed under it (`\"changed\"`, `\"gone\"`), or clears the mark (`nil`)."
  def flag(%Game{pairing_flag: flag} = game, flag), do: game

  def flag(%Game{} = game, flag) when flag in [nil, "changed", "gone"],
    do: game |> Ecto.Changeset.change(%{pairing_flag: flag}) |> Repo.update!()

  @doc """
  The game is set aside - kept on the box, closed without a result if it
  had none - and a new one begins on its board for `pairing`, which is the
  one that leaves the box from now on. `{set aside, new}`.
  """
  def set_aside(%Game{} = game, pairing) do
    aside =
      game
      |> Ecto.Changeset.change(%{
        local: true,
        pairing_flag: nil,
        status: "finished",
        result: game.result || "*",
        suggestion: nil,
        finished_at: game.finished_at || DateTime.utc_now(:second)
      })
      |> Repo.update!()
      |> tap(&write_pgn/1)

    fresh =
      %Game{
        tournament_id: game.tournament_id,
        round: game.round,
        board_no: game.board_no,
        game_no: game.game_no + 1
      }
      |> Game.changeset(pairing_attrs(pairing))
      |> Repo.insert!()

    {aside, fresh}
  end

  @doc """
  The game is played on another tournament's board now: a board was given to
  a tournament while the game was under way. It takes the next game number
  of its new place, its PGN follows, and what was waiting to be sent for the
  tournament it left is not sent (the new place has its own). `:taken` when
  the place holds a game with moves already.
  """
  def carry(%Game{} = game, tournament_id, round, board_no) do
    there = history(tournament_id, round, board_no)

    if Enum.any?(there, &begun?/1) do
      :taken
    else
      # What the board's process made when it was linked: an empty game.
      for empty <- there, do: Repo.delete(empty)
      File.rm(pgn_path(game))

      Alnasl.Outbox.drop_pending(game)

      moved =
        game
        |> Ecto.Changeset.change(%{
          tournament_id: tournament_id,
          round: round,
          board_no: board_no,
          game_no: 1,
          pairing_flag: nil
        })
        |> Repo.update!()
        |> tap(&write_pgn/1)

      {:ok, moved}
    end
  end

  @doc """
  Moves a game to another board of its round: the pairing program gave it
  another number. A number below 1 is a place to wait while two games
  change places.
  """
  def move(%Game{} = game, board_no) do
    if game.board_no > 0, do: File.rm(pgn_path(game))
    moved = game |> Ecto.Changeset.change(%{board_no: board_no}) |> Repo.update!()
    if board_no > 0, do: write_pgn(moved)
    moved
  end

  # --- moves -------------------------------------------------------------------

  @doc """
  The plies of a game: `[%{san, flags, at, clock, read, span}]`. `read` is
  what a rewritten move was first read as (`nil` for every other move).
  """
  def plies(%Game{plies: json}) do
    json
    |> Jason.decode!()
    |> Enum.map(fn ply ->
      %{
        san: ply["san"],
        flags: for(flag <- ply["flags"] || [], is_map_key(@flags, flag), do: @flags[flag]),
        at: ply["at"],
        read: ply["read"],
        span: ply["span"],
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
      |> then(fn stored ->
        if ply[:read],
          do: Map.merge(stored, %{"read" => ply.read, "span" => ply[:span]}),
          else: stored
      end)
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
    info = Tournaments.info(game.tournament_id)

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
        {"Event", info.name || "?"},
        {"Site", info.city || "?"},
        {"Date", date},
        {"Round", Integer.to_string(game.round)},
        {"White", game.white || "?"},
        {"Black", game.black || "?"},
        {"Board", Integer.to_string(game.board_no)}
        # The rate of play, when the pairing program gave it in PGN's own
        # notation. Never worked out from the words: a wrong one is worse
        # than none.
        | if(info.time_control_pgn, do: [{"TimeControl", info.time_control_pgn}], else: [])
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

  @doc "Every game of a round of a tournament as one PGN file, earlier games on a board included."
  def round_pgn(tournament_id, round),
    do: tournament_id |> all(round) |> Enum.map_join("\n", &pgn/1)

  @doc """
  Where a game's PGN is kept on the box: `round-3/board-2.pgn` for the
  box's own tournament, as it always was, and under `t<id>/` for another.
  """
  def pgn_path(%Game{} = game) do
    base =
      if game.tournament_id in [nil, Tournaments.default_id()],
        do: Paths.pgn(),
        else: Path.join(Paths.pgn(), "t#{game.tournament_id}")

    dir = Path.join(base, "round-#{game.round}")
    File.mkdir_p!(dir)
    Path.join(dir, pgn_name(game))
  end

  @doc "`board-3.pgn`, and `board-3-game-2.pgn` for the games after the first."
  def pgn_name(%Game{game_no: 1} = game), do: "board-#{game.board_no}.pgn"
  def pgn_name(%Game{} = game), do: "board-#{game.board_no}-game-#{game.game_no}.pgn"

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

defmodule Alnasl.Seating do
  @moduledoc """
  Which of the box's boards play in the tournament a connect code brought.

  A box starts with its own tournament, and every board belongs to it. A
  code adds a tournament of OpenPairings, and nothing tells the boards to
  play there: the first arbiter to try it had a board reading a game that
  went nowhere, and a box that said so nowhere. So the box takes the next
  step itself, or asks the one question that is left.

  ## After a code

  `after_code/1` looks at what the code brought:

    * **one tournament, and the box's own tournament is unused** (no round
      started, no game with a move in it): every board the box knows plays
      there, its table number being its board. A board without a table
      number gets the next free one. The step is remembered (`auto/0`) so
      that the page can say "All 2 boards now play in Open" with an Undo
      (`undo_auto/0`);
    * **anything else** - a group of tournaments, or boards busy in the
      box's own - is a question, `ask/0`: which tables play in which, with
      ranges already filled in (`suggest/0`). The tournament may also be
      declared to have no boards on this box (`decline/1`).

  ## Never silently outside

  `outside/0` lists the boards that play in no linked tournament while one
  exists, and for each the tournaments it could be put in. `put/3` puts it
  there - giving it a table number if it has none - and says what became of
  a game under way on it (`Alnasl.Tables.assign_carry/3`).

  A board that is added while exactly one linked tournament exists and the
  box's own is unused joins the linked one (`default_tournament/0`, used by
  `Alnasl.Boards.create/1`).
  """

  alias Alnasl.{Boards, Games, Log, Placements, Settings, Tables, Tournaments}
  alias Alnasl.Tournaments.Tournament

  @auto_key "seating_auto"
  @declined_key "seating_declined"

  # --- what is linked ----------------------------------------------------------

  @doc """
  The linked tournaments the pairing program still names, in the box's own
  hall. What this module does by itself - boards outside, the question,
  seating after a code - it does for the boards on the box's own ports; a
  hall that is a bridge's seats its boards by its tables
  (`Alnasl.Tables`), and is never mixed with this one.
  """
  def linked do
    own = Alnasl.Halls.own_id()

    Enum.filter(
      Tournaments.list(),
      &(&1.kind == "linked" and not &1.gone and Placements.in_hall?(&1, own))
    )
  end

  # The boards on the box's own hall.
  defp own_boards do
    own = Alnasl.Halls.own_id()
    Enum.filter(Boards.list(), &((&1.hall_id || own) == own))
  end

  # The boards and tournaments of a hall.
  defp hall_boards(hall_id) do
    own = Alnasl.Halls.own_id()
    Enum.filter(Boards.list(), &((&1.hall_id || own) == (hall_id || own)))
  end

  @doc """
  Has the box's own tournament never been used: no round beyond the first,
  and no game with a move in it, finished or not?
  """
  def own_unused? do
    own = Tournaments.default()

    own.round == 1 and
      not Enum.any?(Games.rounds(own.id), fn round ->
        Enum.any?(Games.all(own.id, round), &Games.begun?/1)
      end)
  end

  @doc """
  The tournament a board that is added with no tournament named plays in:
  the only linked one, when the box's own is unused; else `nil` (the box's
  own).
  """
  def default_tournament do
    case linked() do
      [only] -> if own_unused?(), do: only
      _none_or_many -> nil
    end
  end

  # --- tables ------------------------------------------------------------------

  # The smallest table number of the hall free for this tournament: not on
  # any board and not inside another tournament's range. A range of its own
  # there is made to reach it.
  defp free_table(%Tournament{} = tournament, hall_id) do
    taken = for b <- hall_boards(hall_id), b.table_no, into: MapSet.new(), do: b.table_no

    others =
      for t <- Tournaments.list(),
          t.id != tournament.id,
          %{table_from: from, table_to: to} when from != nil <- [Placements.in_hall(t, hall_id)],
          do: from..(to || from)

    start =
      case Placements.in_hall(tournament, hall_id) do
        %{table_from: from} when is_integer(from) -> from
        _none -> 1
      end

    Stream.iterate(start, &(&1 + 1))
    |> Enum.find(fn n -> not MapSet.member?(taken, n) and not Enum.any?(others, &(n in &1)) end)
  end

  defp numbered(%Boards.Board{table_no: nil} = board, tournament) do
    hall_id = Alnasl.Halls.of(board)
    number = free_table(tournament, hall_id)

    with %{table_from: from, table_to: to} when is_integer(from) <-
           Placements.in_hall(tournament, hall_id),
         true <- number > (to || from) do
      Placements.put(tournament, hall_id, %{table_to: number})
    end

    {:ok, board} = Boards.update(board, %{table_no: number})
    board
  end

  defp numbered(board, _tournament), do: board

  # --- boards outside ----------------------------------------------------------

  @doc """
  Boards that play in no linked tournament while one exists:
  `[%{board, game, targets}]`. `game` is the game under way on it, or `nil`;
  `targets` the tournaments it could be put in, each
  `%{tournament, round, board_no, pairing}` - what its table would stand for
  there, and who is paired on it (`nil` when nobody).
  """
  def outside do
    linked = linked()
    ids = Enum.map(linked, & &1.id)

    if linked == [] do
      []
    else
      for board <- own_boards(), board.tournament_id not in ids do
        %{
          board: board,
          game: under_way(board),
          targets: Enum.map(linked, &target(board, &1))
        }
      end
    end
  end

  defp under_way(%{round: round, board_no: no, tournament_id: tid})
       when is_integer(round) and is_integer(no) do
    case Games.current(tid, round, no) do
      %{local: false, status: "live"} = game -> if Games.begun?(game), do: game
      _none -> nil
    end
  end

  defp under_way(_board), do: nil

  defp target(board, tournament) do
    hall_id = Alnasl.Halls.of(board)
    number = board.table_no || free_table(tournament, hall_id)
    no = Tournaments.board_of_table(tournament, number, nil, hall_id)

    %{
      tournament: tournament,
      round: tournament.round,
      board_no: no,
      pairing: no && Tournaments.board(tournament.id, tournament.round, no)
    }
  end

  @doc """
  Puts a board in a linked tournament. `carry:` says what becomes of a game
  under way on it: `:adopt` (the default; the moves are the game of the
  board its table stands for) or `:fresh`. `{:ok, board, carried}` as
  `Alnasl.Tables.assign_carry/3`.
  """
  def put(%Boards.Board{} = board, %Tournament{} = tournament, opts \\ []) do
    board = numbered(board, tournament)
    result = Tables.assign_carry(board, tournament, opts)
    Tournaments.notify(tournament.id)
    result
  end

  # --- after a code ------------------------------------------------------------

  @doc """
  The box has just taken a code that reached `tournaments`. What it did:

    * `{:joined, tournament, boards}` - all of them play there now;
    * `{:ask, tournaments}` - the question is open;
    * `:nothing` - nothing to decide (no boards, or no tournament).
  """
  def after_code(tournaments) do
    own = Alnasl.Halls.own_id()

    tournaments =
      Enum.filter(
        tournaments,
        &(&1.kind == "linked" and not &1.gone and Placements.in_hall?(&1, own))
      )

    boards = own_boards()
    stray = strays(boards)

    cond do
      tournaments == [] or stray == [] ->
        :nothing

      match?([_one], tournaments) and length(linked()) == 1 and own_unused?() and
          not busy?(stray) ->
        [tournament] = tournaments
        join_all(tournament, stray)

      true ->
        {:ask, tournaments}
    end
  end

  defp strays(boards) do
    ids = Enum.map(linked(), fn t -> t.id end)
    Enum.reject(boards, fn b -> b.tournament_id in ids end)
  end

  defp busy?(boards), do: Enum.any?(boards, &(under_way(&1) != nil))

  defp join_all(tournament, boards) do
    previous =
      for b <- boards, do: %{id: b.id, tournament_id: b.tournament_id, table_no: b.table_no}

    ordered = Enum.sort_by(boards, &{&1.table_no || 1_000_000, &1.id})
    moved = for b <- ordered, do: elem(put(b, tournament), 1)
    tables = for b <- Boards.list(), b.id in Enum.map(moved, & &1.id), do: b.table_no

    # The range is what the boards stand on, so a board that comes later
    # with the next number is inside it.
    own = Alnasl.Halls.own_id()

    if tables != [] and Tournaments.tables(tournament, own) == {nil, nil},
      do:
        Tournaments.assign_tables(
          Tournaments.get!(tournament.id),
          Enum.min(tables),
          Enum.max(tables),
          own
        )

    Settings.put(@auto_key, %{
      "tournament_id" => tournament.id,
      "boards" => Enum.map(moved, & &1.id),
      "previous" => Enum.map(previous, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
    })

    Log.add(:info, "seating.joined", %{
      count: length(moved),
      tournament: Tournaments.title(tournament) || ""
    })

    Tournaments.notify(tournament.id)
    {:joined, Tournaments.get!(tournament.id), moved}
  end

  @doc "What the box did by itself last, while the arbiter has not answered: `nil` or `%{tournament, count}`."
  def auto do
    with %{"tournament_id" => tid, "boards" => ids} <- Settings.get(@auto_key),
         %Tournament{} = tournament <- Tournaments.get(tid) do
      %{tournament: tournament, count: length(ids)}
    else
      _none -> nil
    end
  end

  @doc "The arbiter has seen it: the Undo goes away."
  def dismiss_auto do
    Settings.put(@auto_key, nil)
    :ok
  end

  @doc """
  Takes the automatic step back: the boards play in the tournaments they
  played in, and the tournament has no range of tables. A table number
  given to a board stays.
  """
  def undo_auto do
    with %{"tournament_id" => tid, "previous" => previous} <- Settings.get(@auto_key),
         %Tournament{} = tournament <- Tournaments.get(tid) do
      Tournaments.assign_tables(tournament, nil, nil, Alnasl.Halls.own_id())

      for %{"id" => id, "tournament_id" => from} <- previous,
          board = Boards.get(id),
          target = Tournaments.get(from) do
        Tables.assign(board, target)
      end

      Settings.put(@auto_key, nil)
      Log.add(:info, "seating.undone", %{tournament: Tournaments.title(tournament) || ""})
      Tournaments.notify(tid)
      :ok
    else
      _none -> {:error, :nothing_to_undo}
    end
  end

  # --- the question ------------------------------------------------------------

  @doc "Tournaments whose tables are not said yet, with the ranges the box would suggest: `[%{tournament, from, to}]`."
  def ask do
    stray = strays(own_boards())
    declined = Settings.get(@declined_key) || []

    own = Alnasl.Halls.own_id()

    open =
      Enum.filter(linked(), fn t ->
        Tournaments.tables(t, own) == {nil, nil} and t.id not in declined and
          not Enum.any?(own_boards(), &(&1.tournament_id == t.id))
      end)

    if stray == [] or open == [], do: [], else: suggest(open, stray)
  end

  @doc "Ranges of tables for tournaments, from the tables the boards carry and how many boards each tournament has."
  def suggest(tournaments, boards) do
    given = for b <- boards, b.table_no, do: b.table_no
    plain = Enum.count(boards, &(&1.table_no == nil))

    tables =
      Enum.sort(
        given ++ Enum.take(Stream.iterate(Enum.max(given, fn -> 0 end) + 1, &(&1 + 1)), plain)
      )

    first = List.first(tables)
    last = List.last(tables)

    {rows, _next} =
      Enum.map_reduce(tournaments, first, fn t, from ->
        cond do
          first == nil ->
            {%{tournament: t, from: nil, to: nil}, from}

          from > last ->
            {%{tournament: t, from: nil, to: nil}, from}

          true ->
            size = length(Tournaments.boards(t.id, t.remote_round || t.round))

            to =
              if size == 0 or t == List.last(tournaments),
                do: last,
                else: min(from + size - 1, last)

            {%{tournament: t, from: from, to: to}, to + 1}
        end
      end)

    rows
  end

  @doc "This tournament has no boards on this box: stop asking."
  def decline(%Tournament{id: id}) do
    Settings.put(@declined_key, Enum.uniq([id | Settings.get(@declined_key) || []]))
    Tournaments.notify(id)
    :ok
  end

  @doc """
  Gives a range of tables of hall `hall_id` (the tournament's own hall when
  none is named) to a tournament, and says what became of games under way
  on the boards that moved with it: `{:ok, tournament, [carried]}`.
  """
  def assign_range(%Tournament{} = tournament, from, to, hall_id \\ nil),
    do: Tournaments.assign_tables_carry(tournament, from, to, hall_id)
end

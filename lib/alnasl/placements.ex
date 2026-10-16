defmodule Alnasl.Placements do
  @moduledoc """
  Where each tournament is played: in which halls, on which tables, and
  which of its boards each table plays.

  A tournament has one placement or more (`Alnasl.Tournaments.Placement`),
  at most one a hall. Two shapes cover what halls do:

    * **two tournaments, one hall** - the Open on tables 1-8, the
      under-twelves on 9-16: a placement each, both in the hall, table 9
      being board 1 of the under-twelves. As before placements existed.
    * **one tournament, two halls** - boards 1-8 in the main hall on its
      tables 1-8, boards 9-16 in the annex on its tables 1-8: two
      placements, the second with `first_board` 9.

  ## Tables to boards, and back

  A board in hall H at table T plays in the tournament whose placement in
  H holds T (`for_table/2`), and its board is
  `first_board + (T - table_from)` (`board_at/4`). Board N of a tournament
  is at the placement whose boards hold N (`place_of/2`): hall H, table
  `table_from + (N - first_board)`.

  A placement without a range has every table of its hall that no range
  holds, table 1 playing `first_board`; its boards run up to the next
  placement's first board, or for ever when there is none.

  ## What is refused

  Two ranges of one hall holding the same table (`put/4`, unless the old
  "these tables play here" asks to take them over, `give_up: true`), two
  placements of one tournament holding the same board, and taking a
  tournament out of the last hall it is in.

  ## Rows from before

  A tournament with no placement row is played in its own hall
  (`tournaments.hall_id`) on every free table, board 1 on table 1: what
  it always meant. The first change writes that down as a row.
  """

  import Ecto.Query, only: [from: 2]

  alias Alnasl.{Boards, Halls, Log, Repo, Tables, Tournaments}
  alias Alnasl.Accounts.Scope
  alias Alnasl.Tournaments.{Placement, Tournament}

  @rank %{"viewer" => 1, "arbiter" => 2, "owner" => 3}

  # --- rows --------------------------------------------------------------------

  @doc """
  The placements of a tournament, by first board: the rows it has, or the
  one it is taken to have (its own hall, every free table) when it has
  none. Never empty.
  """
  def list(%Tournament{id: id} = tournament) do
    case stored(id) do
      [] -> [implied(tournament)]
      rows -> rows
    end
  end

  def list(id) when is_integer(id) do
    case Tournaments.get(id) do
      nil -> []
      tournament -> list(tournament)
    end
  end

  def list(nil), do: []

  defp stored(id) do
    Repo.all(from p in Placement, where: p.tournament_id == ^id, order_by: [p.first_board, p.id])
  end

  defp implied(%Tournament{} = tournament),
    do: %Placement{tournament_id: tournament.id, hall_id: Halls.of(tournament), first_board: 1}

  def get(nil), do: nil
  def get(id), do: Repo.get(Placement, id)

  @doc "The tournament's placement in `hall_id`, or `nil`."
  def in_hall(tournament, hall_id) do
    hall_id = hall_id || Halls.own_id()
    Enum.find(list(tournament), &(&1.hall_id == hall_id))
  end

  @doc "The halls a row is in: every hall a tournament is placed in; the one hall of anything else."
  def halls_of(%Tournament{} = tournament),
    do: tournament |> list() |> Enum.map(& &1.hall_id) |> Enum.uniq()

  def halls_of(nil), do: []
  def halls_of(%Alnasl.Halls.Hall{id: id}), do: [id]
  def halls_of(row), do: [Halls.of(row)]

  @doc "Is the row in hall `hall_id`?"
  def in_hall?(row, hall_id), do: hall_id in halls_of(row)

  @doc """
  What `halls_of/2` needs to answer for many rows without a query a row:
  the own hall's id, and the halls of every tournament with placements.
  """
  def index do
    halls =
      Repo.all(
        from p in Placement,
          order_by: [p.first_board, p.id],
          select: {p.tournament_id, p.hall_id}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {tid, ids} -> {tid, Enum.uniq(ids)} end)

    %{own: Halls.own_id(), halls: halls}
  end

  @doc "`halls_of/1`, answered from an `index/0`."
  def halls_of(%Tournament{} = t, %{own: own, halls: halls}),
    do: Map.get(halls, t.id) || [t.hall_id || own]

  def halls_of(nil, _index), do: []
  def halls_of(%Alnasl.Halls.Hall{id: id}, _index), do: [id]
  def halls_of(%{hall_id: id}, _index) when is_integer(id), do: [id]
  def halls_of(_row, %{own: own}), do: [own]

  # --- who may ------------------------------------------------------------------

  @doc """
  The role a scope has for a row: for a tournament the highest it has in
  any hall the tournament is placed in, for anything else its role in the
  row's hall.
  """
  def role(scope, row) do
    row
    |> halls_of()
    |> Enum.map(&Scope.role(scope, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&@rank[&1], fn -> nil end)
  end

  @doc "May the scope do what needs `need` (`:viewer`, `:arbiter`, `:owner`) to the row?"
  def can?(%Scope{} = scope, need, row) when need in [:viewer, :arbiter, :owner] do
    case role(scope, row) do
      nil -> false
      role -> @rank[role] >= @rank[Atom.to_string(need)]
    end
  end

  def can?(_scope, _need, _row), do: false

  @doc "The halls a tournament could be added to by the scope: arbiter or owner there, not placed there yet."
  def addable_halls(scope, %Tournament{} = tournament) do
    placed = halls_of(tournament)

    for hall <- Halls.list(),
        hall.id not in placed,
        Scope.can?(scope, :arbiter, hall.id),
        do: hall
  end

  # --- boards and tables --------------------------------------------------------

  @doc """
  The boards a placement holds among its tournament's placements:
  `{first, last}`, `last` being `:infinity` for a placement without a
  range that no later placement stops.
  """
  def boards(%Placement{} = placement, placements) do
    if placement.table_from do
      {placement.first_board,
       placement.first_board + (placement.table_to || placement.table_from) -
         placement.table_from}
    else
      next =
        placements
        |> Enum.map(& &1.first_board)
        |> Enum.filter(&(&1 > placement.first_board))
        |> Enum.min(fn -> nil end)

      {placement.first_board, if(next, do: next - 1, else: :infinity)}
    end
  end

  defp holds?({first, :infinity}, n), do: n >= first
  defp holds?({first, last}, n), do: n >= first and n <= last

  @doc """
  The place in the tournament's board order that table `table` of hall
  `hall_id` plays: `first_board + (table - table_from)`. `nil` below the
  placement's first table, or on a board another placement holds. A
  tournament not placed in that hall at all counts by its one placement
  when it has one (as a board put in it by hand always did), else `nil`.
  """
  def board_at(tournament, hall_id, table, all \\ nil)

  def board_at(tournament, hall_id, table, all) when is_integer(table) do
    all = all || list(tournament)

    placement =
      Enum.find(all, &(&1.hall_id == (hall_id || Halls.own_id()))) ||
        case all do
          [only] -> only
          _many -> nil
        end

    with %Placement{} <- placement,
         from = placement.table_from || 1,
         true <- table >= from do
      n = placement.first_board + table - from
      others = Enum.reject(all, &(&1 == placement))
      if Enum.any?(others, &holds?(boards(&1, all), n)), do: nil, else: n
    else
      _none -> nil
    end
  end

  def board_at(_tournament, _hall_id, _table, _all), do: nil

  @doc "Where board `n` of a tournament is played: `{hall_id, table}`, or `nil`."
  def place_of(tournament, n) when is_integer(n) do
    all = list(tournament)

    case Enum.find(all, &holds?(boards(&1, all), n)) do
      nil -> nil
      p -> {p.hall_id, (p.table_from || 1) + n - p.first_board}
    end
  end

  @doc "The tournament still listed whose range in hall `hall_id` holds table `number`, if any."
  def for_table(number, hall_id) when is_integer(number) do
    hall_id = hall_id || Halls.own_id()

    Repo.all(
      from p in Placement,
        where:
          p.hall_id == ^hall_id and not is_nil(p.table_from) and p.table_from <= ^number and
            coalesce(p.table_to, p.table_from) >= ^number,
        order_by: p.id
    )
    |> Enum.find_value(fn p ->
      case Tournaments.get(p.tournament_id) do
        %Tournament{gone: false} = t -> t
        _gone -> nil
      end
    end)
  end

  def for_table(_number, _hall_id), do: nil

  # --- changes -----------------------------------------------------------------

  @doc """
  Places a tournament in hall `hall_id`, or changes where it is there:
  `attrs` may say `table_from`, `table_to` (both `nil`: every free table)
  and `first_board`. Every board of the hall carrying one of the tables
  moves to the tournament. `{:ok, placement, [carried]}` (what became of
  games under way, as `Alnasl.Tables.assign_carry/3`), or

    * `{:error, :tables, other}` - another tournament's range in the hall
      holds one of the tables (with `give_up: true` that range is given up
      instead, as "these tables play here" always did);
    * `{:error, :boards}` - another placement of the tournament holds one
      of its boards;
    * `{:error, :range}` - the numbers are not a range.
  """
  def put(%Tournament{} = tournament, hall_id, attrs, opts \\ []) do
    hall_id = hall_id || Halls.own_id()
    materialize(tournament)

    current =
      Repo.get_by(Placement, tournament_id: tournament.id, hall_id: hall_id) ||
        %Placement{
          tournament_id: tournament.id,
          hall_id: hall_id,
          first_board: suggest(tournament, hall_id).first_board
        }

    changeset = Placement.changeset(current, Map.new(attrs))

    with true <- changeset.valid? || {:error, :range},
         placement = Ecto.Changeset.apply_changes(changeset),
         :ok <- boards_free(tournament, placement),
         :ok <- tables_free(placement, Keyword.get(opts, :give_up, false)) do
      placement = Repo.insert_or_update!(changeset)
      carried = take_tables(tournament, placement)
      Tournaments.notify(tournament.id)
      Halls.notify()
      {:ok, placement, carried}
    end
  end

  @doc """
  Adds a hall to a tournament with the place `suggest/2` gives - or what
  `attrs` says instead. A board of those tables with a game under way in
  another tournament is not taken: `{:error, :busy, board}`.
  """
  def add(%Tournament{} = tournament, hall_id, attrs \\ %{}) do
    if in_hall(tournament, hall_id) do
      {:error, :already}
    else
      suggested = suggest(tournament, hall_id)

      attrs =
        Map.merge(
          %{
            table_from: suggested.table_from,
            table_to: suggested.table_to,
            first_board: suggested.first_board
          },
          Map.new(attrs)
        )

      case busy(tournament, hall_id, attrs) do
        nil -> put(tournament, hall_id, attrs)
        board -> {:error, :busy, board}
      end
    end
  end

  # A board of the tables asked for with a game under way in another
  # tournament: adding a hall does not pull a running game out from under
  # its players. `nil` when there is none.
  defp busy(tournament, hall_id, attrs) do
    case attrs[:table_from] do
      nil ->
        nil

      from ->
        range = from..(attrs[:table_to] || from)//1

        Enum.find(Boards.list(), fn board ->
          Halls.of(board) == hall_id and board.table_no != nil and board.table_no in range and
            board.tournament_id != tournament.id and Tables.under_way?(board, tournament)
        end)
    end
  end

  @doc """
  Takes a tournament out of a hall. Its boards there go back to the
  hall's own tournament, not linked; its games stay. The last hall a
  tournament is in cannot go: `{:error, :last}`.
  """
  def remove(%Placement{} = placement) do
    tournament = Tournaments.get(placement.tournament_id)
    materialize(tournament)

    if length(stored(placement.tournament_id)) <= 1 do
      {:error, :last}
    else
      home = Halls.local_tournament(placement.hall_id)

      for board <- Boards.list(),
          board.tournament_id == placement.tournament_id,
          Halls.of(board) == placement.hall_id do
        Boards.update(board, %{tournament_id: home.id, round: nil, board_no: nil})
      end

      Repo.delete_all(
        from p in Placement,
          where: p.tournament_id == ^placement.tournament_id and p.hall_id == ^placement.hall_id
      )

      Log.add(:info, "tournament.hall_removed", %{
        tournament: Tournaments.title(tournament) || "",
        hall: hall_name(placement.hall_id)
      })

      Tournaments.notify(placement.tournament_id)
      Halls.notify()
      :ok
    end
  end

  @doc """
  Where a tournament would go in hall `hall_id`: the board after the
  highest one it has placed, and as many tables after the last range of
  that hall as it has boards left in the round (else as many as its last
  range had). `%{table_from, table_to, first_board}`.
  """
  def suggest(%Tournament{} = tournament, hall_id) do
    hall_id = hall_id || Halls.own_id()
    all = Enum.reject(list(tournament), &(&1.hall_id == hall_id))

    first_board =
      case all do
        [] ->
          1

        _some ->
          highest = all |> Enum.map(&highest_board(tournament, &1, all)) |> Enum.max()
          max(highest + 1, (all |> Enum.map(& &1.first_board) |> Enum.max()) + 1)
      end

    ranged =
      Repo.all(
        from p in Placement,
          where:
            p.hall_id == ^hall_id and p.tournament_id != ^tournament.id and
              not is_nil(p.table_from),
          select: coalesce(p.table_to, p.table_from)
      )

    # A tournament without a range sits on tables too: its boards say
    # which. The hall's own tournament is where idle boards wait, not a
    # tenant, so its boards are fair game.
    local = Halls.local_tournament(hall_id).id

    seated =
      for board <- Boards.list(),
          Halls.of(board) == hall_id,
          board.table_no != nil,
          board.tournament_id not in [tournament.id, local],
          do: board.table_no

    last_table = Enum.max(ranged ++ seated, fn -> 0 end)

    left =
      Enum.count(
        Tournaments.boards(tournament.id, tournament.remote_round || tournament.round),
        &(&1.board >= first_board)
      )

    size =
      cond do
        left > 0 -> left
        bounded = Enum.find(Enum.reverse(all), & &1.table_from) -> boards_count(bounded)
        true -> 1
      end

    %{table_from: last_table + 1, table_to: last_table + size, first_board: first_board}
  end

  defp boards_count(%Placement{table_from: from, table_to: to}), do: (to || from) - from + 1

  # The highest board a placement has: the end of its range; for one without
  # a range, the highest board its hall's boards play now.
  defp highest_board(tournament, placement, all) do
    case boards(placement, all) do
      {_first, :infinity} ->
        Boards.list()
        |> Enum.filter(
          &(&1.tournament_id == tournament.id and Halls.of(&1) == placement.hall_id and
              &1.table_no != nil)
        )
        |> Enum.map(&(placement.first_board + &1.table_no - 1))
        |> Enum.max(fn -> placement.first_board - 1 end)

      {_first, last} ->
        last
    end
  end

  # The placement it is taken to have is written down before anything else
  # is: a second hall must not make the first one disappear.
  defp materialize(%Tournament{id: id} = tournament) do
    if stored(id) == [] do
      Repo.insert!(%{implied(tournament) | id: nil})
    end

    :ok
  end

  defp materialize(nil), do: :ok

  defp boards_free(tournament, placement) do
    others =
      Enum.reject(stored(tournament.id), &(&1.hall_id == placement.hall_id))

    all = Enum.sort_by([placement | others], & &1.first_board)

    clash =
      all
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn [a, b] ->
        a.first_board == b.first_board or
          case boards(a, all) do
            {_first, :infinity} -> false
            {_first, last} -> last >= b.first_board
          end
      end)

    if clash, do: {:error, :boards}, else: :ok
  end

  defp tables_free(%Placement{table_from: nil}, _give_up), do: :ok

  defp tables_free(%Placement{} = placement, give_up) do
    from = placement.table_from
    to = placement.table_to || from

    taken =
      Repo.all(
        from p in Placement,
          where:
            p.hall_id == ^placement.hall_id and p.tournament_id != ^placement.tournament_id and
              not is_nil(p.table_from) and p.table_from <= ^to and
              coalesce(p.table_to, p.table_from) >= ^from
      )

    cond do
      taken == [] ->
        :ok

      give_up ->
        for p <- taken do
          p |> Ecto.Changeset.change(table_from: nil, table_to: nil) |> Repo.update!()
          Tournaments.notify(p.tournament_id)
        end

        :ok

      true ->
        {:error, :tables, Tournaments.get(hd(taken).tournament_id)}
    end
  end

  # Every board of the hall carrying one of the tables plays here now.
  defp take_tables(_tournament, %Placement{table_from: nil}), do: []

  defp take_tables(%Tournament{} = tournament, %Placement{} = placement) do
    tournament = Tournaments.get!(tournament.id)
    range = placement.table_from..(placement.table_to || placement.table_from)

    for board <- Boards.list(),
        Halls.of(board) == placement.hall_id,
        board.table_no != nil,
        board.table_no in range,
        {:ok, _board, carried} = Tables.assign_carry(board, tournament),
        carried != nil,
        do: carried
  end

  defp hall_name(id) do
    case Halls.get(id) do
      %{name: name} -> name
      nil -> ""
    end
  end

  @doc """
  Two rows of one tournament made one: the halls `later` is placed in that
  `first` is not go to `first`; a range `first` lacks in a hall both are in
  is taken over. `{:ok, shifted}`: the placements that moved over with
  another first board, whose boards `reseat/2` numbers again once the
  rows are what they will be.
  """
  def merge(%Tournament{} = later, %Tournament{} = first) do
    materialize(first)
    materialize(later)
    mine = stored(first.id)

    shifted =
      for p <- stored(later.id), moved = merge_one(p, mine, first), do: moved

    {:ok, shifted}
  end

  defp merge_one(p, mine, first) do
    case Enum.find(mine, &(&1.hall_id == p.hall_id)) do
      nil ->
        # Both rows may have counted from board 1: this hall's boards
        # come after the ones the first row has placed.
        moved = %{p | tournament_id: first.id}

        first_board =
          if boards_free(first, moved) == :ok,
            do: p.first_board,
            else: suggest(first, p.hall_id).first_board

        placement =
          p
          |> Ecto.Changeset.change(tournament_id: first.id, first_board: first_board)
          |> Repo.update!()

        if first_board != p.first_board, do: placement

      %Placement{table_from: nil} = there when p.table_from != nil ->
        there
        |> Ecto.Changeset.change(table_from: p.table_from, table_to: p.table_to)
        |> Repo.update!()

        Repo.delete!(p)
        nil

      _there ->
        Repo.delete!(p)
        nil
    end
  end

  @doc """
  Numbers the boards of placements again after their first board moved:
  a table plays `first_board + (table - table_from)`, whatever it played
  before. What became of games under way, as `put/4` says.
  """
  def reseat(%Tournament{} = tournament, placements) do
    tournament = Tournaments.get!(tournament.id)

    for p <- placements,
        carried <- reseat_one(tournament, p),
        do: carried
  end

  defp reseat_one(tournament, %Placement{table_from: nil} = placement) do
    for board <- Boards.list(),
        board.tournament_id == tournament.id,
        Halls.of(board) == placement.hall_id,
        board.table_no != nil,
        {:ok, _board, carried} = Tables.assign_carry(board, tournament),
        carried != nil,
        do: carried
  end

  defp reseat_one(tournament, placement), do: take_tables(tournament, placement)

  @doc "Takes every placement of a tournament away (the tournament goes)."
  def delete_all(tournament_id),
    do: Repo.delete_all(from p in Placement, where: p.tournament_id == ^tournament_id)
end

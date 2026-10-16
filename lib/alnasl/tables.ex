defmodule Alnasl.Tables do
  @moduledoc """
  Which physical board is which number - the question an arbiter asks with
  twelve identical boards and twelve identical cables in front of him.

  ## Three things, kept apart

  1. **Which board it is.** A DGT board reports a serial number, and that is
     its identity: it survives a reboot, another cable, another USB port. A
     board on a loop that has not said its serial is the number it answers
     to there (`Alnasl.Loops`); a simulator is its slot. The serial port is only where a board happens to be plugged in
     today (`identity/1`).
  2. **Its table number.** The sticker on the board: "this is table 7". Set
     once for a hall (`set_table/2`, or by touching the boards in order -
     `Alnasl.Finder`), and kept with the identity, not with the port.
  3. **Its board of the round.** Normally the table number. For a round the
     arbiter can say otherwise - "table 7 plays board 3 today" (`remap/2`),
     swap two (`swap/2`), or put it back (`clear_remap/1`). The next round
     starts from the table numbers again.

  ## Tables and tournaments

  A hall with two tournaments has one row of tables and two sets of board
  numbers. A tournament can be given a range of tables
  (`Alnasl.Tournaments.assign_tables/3`): tables 5 to 8 are the under-twelves,
  and table 5 is their board 1. So "the board its table stands for"
  (`home_board/1`) is the table number counted from the first table of the
  board's tournament. A board given a table number inside a tournament's
  range joins that tournament; a single board can also be put in a
  tournament by hand (`assign/2`).

  ## A board that comes back

  A board added on a port is a new row. When it then says who it is and the
  box knows that serial - with a table number, and not connected anywhere
  just now - it is the same board on another port: the known row takes the
  new port and keeps its number, its game and its captures, and the new row
  goes (`recognise/4`). A serial the box has never seen stays a new board,
  and asks for a number.

  And the other way round: a row that has a serial keeps it. When its port
  turns out to hold another board - the ports came up in another order
  after a restart, two cables were swapped at the hub - the rows change
  ports, not identities: table 7 stays the board that carries the sticker.

  ## Ready or not

  `checks/1` is the list to read before a round: everything that would make
  a board feed the wrong game or none, each with the board it is about.
  """

  alias Alnasl.{Boards, Log, Repo, Tournaments}
  alias Alnasl.Boards.Board

  # The round in play in the board's tournament.
  defp round_of(%{tournament_id: id}), do: Tournaments.round_in_play(id)

  # --- identity ----------------------------------------------------------------

  @doc """
  What a board is known by: `{:serial, "06310"}`, `{:address, 5}` (on a
  loop, no serial yet), `{:slot, "sim-3"}` (a simulator or a replay) or
  `{:port, "COM7"}` (a board that has not said who it is). Takes a board
  row or a snapshot.
  """
  def identity(%{serial: serial}) when is_binary(serial) and serial != "", do: {:serial, serial}

  def identity(%{driver: "dgt_bus", address: address}) when address != nil,
    do: {:address, address}

  def identity(%{driver: driver, port: port}) when driver in ["simulator", "replay"],
    do: {:slot, port}

  def identity(%{port: port}), do: {:port, port}

  @doc "Is the board's identity one that survives another port?"
  def lasting_identity?(board), do: match?({:serial, _}, identity(board))

  @doc "A board nobody has given a number yet."
  def new?(%{table_no: nil, board_no: nil}), do: true
  def new?(_board), do: false

  @doc """
  The board of the round a board's table stands for: its table number,
  counted from the first table of its tournament. `nil` without a table
  number, or with one below its tournament's first table. Takes a board row
  or a snapshot. In a team event the count goes match by match
  (`Alnasl.Tournaments.board_of_table/3`), for `round` - the round the
  tournament has on its boards unless another is named.
  """
  def home_board(board, round \\ nil)

  def home_board(%{table_no: nil}, _round), do: nil

  def home_board(%{table_no: table} = board, round) do
    case Tournaments.get(Map.get(board, :tournament_id)) do
      nil -> table
      tournament -> Tournaments.board_of_table(tournament, table, round)
    end
  end

  def home_board(_board, _round), do: nil

  @doc "Does the board feed another board of the round than its table says?"
  def remapped?(%{table_no: table, board_no: board} = row) when table != nil and board != nil,
    do: home_board(row) != board

  def remapped?(_board), do: false

  @doc """
  Puts a board in a tournament: it follows that tournament's round, on the
  board its table stands for there (not linked, when it has no table
  number). Its game in the tournament it leaves stays as it is - unless a
  game is being played on it; see `assign_carry/3`.
  """
  def assign(%Board{} = board, %Tournaments.Tournament{} = tournament, opts \\ []) do
    with {:ok, board, _carried} <- assign_carry(board, tournament, opts), do: {:ok, board}
  end

  @doc """
  `assign/3`, and what became of a game under way on the board: `nil` when
  there was none, else `%{moves, round, board_no, outcome}` with `outcome`

    * `:adopted` - the moves are the game of the board the table stands for
      in the new tournament (the default, `carry: :adopt`): the game moves
      with the board, takes the pairing's names and ids, and every
      destination is told it in full;
    * `:fresh` - `carry: :fresh`: the game is closed without a result and
      kept where it was, and the board begins again;
    * `:left` - no board of the new tournament to carry it to (the board has
      no table number there), or that board has a game of its own already:
      the game stays where it was and is said so in the log.
  """
  def assign_carry(%Board{} = board, %Tournaments.Tournament{} = tournament, opts \\ []) do
    if board.tournament_id == tournament.id and board.round == tournament.round and
         board.board_no == Tournaments.board_of_table(tournament, board.table_no) do
      {:ok, board, nil}
    else
      under_way = under_way(board, tournament)

      Log.add(
        :info,
        "table.tournament",
        %{name: board.name, tournament: Tournaments.title(tournament) || ""},
        ref(board)
      )

      {:ok, board} =
        Boards.update(board, %{tournament_id: tournament.id, round: nil, board_no: nil})

      board =
        case home_board(board) do
          nil -> board
          number -> elem(Boards.link(board, tournament.round, number), 1)
        end

      carried =
        under_way && carry(under_way, board, tournament, Keyword.get(opts, :carry, :adopt))

      {:ok, Boards.get!(board.id), carried}
    end
  end

  # The game being played on the board in another tournament, if there is one.
  defp under_way(%Board{tournament_id: from, round: round, board_no: no}, tournament)
       when is_integer(round) and is_integer(no) and from != tournament.id do
    case Alnasl.Games.current(from, round, no) do
      %{local: false, status: "live"} = game -> if Alnasl.Games.begun?(game), do: game
      _none -> nil
    end
  end

  defp under_way(_board, _tournament), do: nil

  defp carry(game, board, tournament, mode) do
    moves = length(Alnasl.Games.plies(game))
    info = %{moves: moves, round: board.round, board_no: board.board_no, outcome: :left}

    cond do
      mode == :fresh ->
        game |> Alnasl.Games.finish("*") |> Alnasl.Outbox.enqueue(nil, false)

        Log.add(:info, "table.game_fresh", %{name: board.name, moves: moves}, ref(board))
        %{info | outcome: :fresh}

      not (is_integer(board.round) and is_integer(board.board_no)) ->
        Log.add(:warn, "table.game_left", %{name: board.name, moves: moves}, ref(board))
        info

      true ->
        case Alnasl.Games.carry(game, tournament.id, board.round, board.board_no) do
          {:ok, moved} ->
            pairing = Tournaments.board(tournament.id, board.round, board.board_no)
            moved = moved |> Alnasl.Games.adopt(pairing) |> Alnasl.Outbox.enqueue(nil, true)
            Boards.refresh_games(tournament.id)

            Log.add(
              :info,
              "table.game_carried",
              %{name: board.name, moves: moves, tournament: Tournaments.title(tournament) || ""},
              %{board_id: board.id, round: moved.round, board_no: moved.board_no}
            )

            %{info | outcome: :adopted}

          :taken ->
            Log.add(:warn, "table.game_left", %{name: board.name, moves: moves}, ref(board))
            info
        end
    end
  end

  # --- the table number --------------------------------------------------------

  @doc """
  Gives a board its table number (`nil` takes it away). A board that had
  that number loses it: a sticker is on one board. The board of the round
  follows the table number, unless the arbiter remapped it for this round.
  """
  def set_table(%Board{} = board, nil) do
    Log.add(:info, "table.cleared", %{name: board.name, table: board.table_no}, ref(board))
    Boards.update(board, %{table_no: nil})
  end

  def set_table(%Board{} = board, number) when is_integer(number) and number > 0 do
    # Table numbers are a hall's: table 3 here and table 3 in the hall a
    # bridge brings are two tables.
    for other <- in_hall(board.hall_id), other.id != board.id, other.table_no == number do
      Log.add(
        :info,
        "table.moved",
        %{from: other.name, to: board.name, table: number},
        ref(other)
      )

      Boards.update(other, %{table_no: nil})
    end

    # A table inside a tournament's range plays in that tournament.
    owner = Tournaments.for_table(number, board.hall_id)
    moves? = owner != nil and owner.id != board.tournament_id

    follows? =
      moves? or board.board_no == nil or board.round != round_of(board) or
        board.board_no == home_board(board) or board.table_no == nil

    changes =
      if moves?,
        do: %{table_no: number, tournament_id: owner.id, round: nil, board_no: nil},
        else: %{table_no: number}

    with {:ok, board} <- Boards.update(board, changes) do
      Log.add(:info, "table.set", %{name: board.name, table: number}, ref(board))
      round = round_of(board)
      home = home_board(board)

      if follows? and home != nil and {board.round, board.board_no} != {round, home},
        do: Boards.link(board, round, home),
        else: {:ok, board}
    end
  end

  @doc """
  Numbers the boards in the order they were added (not by the number a
  board answers to on a loop, which says nothing of where it stands): table
  and board `first`, `first + 1`, ...
  """
  def number_in_order(round, first \\ 1, hall_id \\ nil) do
    hall_id
    |> in_hall()
    |> Enum.sort_by(& &1.id)
    |> Enum.with_index(first)
    |> Enum.each(fn {board, number} ->
      for other <- in_hall(hall_id), other.id != board.id, other.table_no == number do
        Boards.update(other, %{table_no: nil})
      end

      {:ok, board} = Boards.update(Boards.get!(board.id), %{table_no: number})
      Boards.link(board, round, number)
    end)
  end

  # --- the board of the round --------------------------------------------------

  @doc "For this round, the board feeds board `board_no` - whatever its table number."
  def remap(%Board{} = board, board_no) when is_integer(board_no) and board_no > 0 do
    if board.table_no && board.table_no != board_no do
      Log.add(:info, "table.remapped", %{name: board.name, table: board.table_no}, %{
        board_id: board.id,
        round: round_of(board),
        board_no: board_no
      })
    end

    Boards.link(board, round_of(board), board_no)
  end

  @doc "Back to the board its table says; not linked when it has none."
  def clear_remap(%Board{} = board) do
    case home_board(board) do
      nil -> Boards.unlink(board)
      number -> Boards.link(board, round_of(board), number)
    end
  end

  @doc "Every board with a table number back to the board its table stands for."
  def clear_remaps(hall_id \\ nil) do
    for board <- in_hall(hall_id),
        home = home_board(board),
        home != nil,
        remapped?(board) or board.round != round_of(board) do
      Boards.link(Boards.get!(board.id), round_of(board), home)
    end

    :ok
  end

  @doc """
  Two boards change places for this round: each feeds the board the other
  fed. Within one tournament: two boards of different tournaments have no
  board number to exchange.
  """
  def swap(%Board{tournament_id: one}, %Board{tournament_id: other}) when one != other,
    do: {:error, :other_tournament}

  def swap(%Board{} = a, %Board{} = b) do
    round = round_of(a)
    {a_no, b_no} = {a.board_no, b.board_no}
    {:ok, a} = Boards.update(a, %{round: nil, board_no: nil})
    {:ok, b} = Boards.update(b, %{round: nil, board_no: nil})
    Log.add(:info, "table.swapped", %{a: a.name, b: b.name}, %{round: round})
    if a_no, do: Boards.link(b, round, a_no)
    if b_no, do: Boards.link(a, round, b_no)
    :ok
  end

  # --- a board that comes back -------------------------------------------------

  # A board through a bridge is a DGT board too: one that is carried from
  # the box's own port to a bridge, or back, is recognised by its serial.
  @dgt ["dgt_serial", "dgt_bus", "remote"]

  @doc """
  What a board's process may write to its row when the board says who it
  is. A row that already has a serial IS that board: a different serial
  arriving on its port does not rename it - it means another board is on
  that port, which `recognise/4` sorts out.
  """
  def keep_identity(changes, %Board{serial: serial}) when is_binary(serial) and serial != "",
    do: Map.delete(changes, :serial)

  def keep_identity(changes, _board), do: changes

  @doc """
  The board on the port of row `id` has said it is `seen`. `port` and
  `address` are where the row was when it said so: a row that has been
  moved since is not judged by old news (`:stale`).

  The row's own serial - nothing to do, unless the row is new and the box
  knows that serial on a numbered row that is not connected now: then that
  row takes this one's port and this one goes (`{:recognised, board}`).
  Otherwise `:new`, `:known`, or `:duplicate` (the same serial connected
  twice - see `checks/1`).

  Another serial - another board is on this row's port:

  - the box knows whose it is: the two rows change ports, so that each row
    is where its board is (`{:exchanged, owner}`). This is what happens to a
    whole hall when the ports come up in another order after a restart;
  - nobody's, and the row has no number: the row is that board now (`:new`);
  - nobody's, the row has a number and its game has not begun: the unknown
    board gets a row of its own on this port - "New board", asking for a
    number - and the numbered row waits, disconnected, for its own board to
    turn up (`{:split, new_row}`);
  - nobody's, mid-game: nothing is touched - a serial misread on a noisy
    line must not take a board out of a round - and it is logged and listed
    (`:mismatch`).
  """
  def recognise(id, port, address, seen) do
    with true <- is_binary(seen) and seen != "",
         %Board{} = row when row.driver in @dgt <- Boards.get(id),
         true <- {row.port, row.address} == {port, address} do
      if row.serial == seen, do: arrived(row), else: other_board(row, seen)
    else
      _other -> :stale
    end
  end

  @doc "`recognise/4` for the board that row `id` holds now, by the row's own serial."
  def recognise(id) do
    case Boards.get(id) do
      %Board{} = row -> recognise(id, row.port, row.address, row.serial)
      nil -> :stale
    end
  end

  defp arrived(%Board{serial: serial} = fresh) do
    others =
      for other <- Boards.list(),
          other.id != fresh.id,
          other.serial == serial,
          other.driver in @dgt,
          do: other

    {known, _unknown} = Enum.split_with(others, &(not new?(&1)))
    absent = Enum.reject(known, &connected?/1)

    cond do
      others == [] -> :new
      not new?(fresh) -> if Enum.any?(others, &connected?/1), do: :duplicate, else: :known
      match?([_one], absent) and length(known) == 1 -> take_over(hd(absent), fresh)
      true -> :duplicate
    end
  end

  defp other_board(%Board{} = row, seen) do
    owner =
      Enum.find(Boards.list(), &(&1.id != row.id and &1.serial == seen and &1.driver in @dgt))

    cond do
      # Two rows on one port, and the board is the other one's: step aside.
      owner != nil and {owner.port, owner.address} == {row.port, row.address} ->
        Boards.update(row, %{enabled: false})
        :parked

      owner != nil ->
        exchange(row, owner)

      new?(row) ->
        Boards.update(row, %{serial: seen})
        :new

      started?(row) ->
        Log.add(
          :warn,
          "board.other_serial",
          %{name: row.name, serial: row.serial, seen: seen},
          ref(row)
        )

        :mismatch

      true ->
        split(row, seen)
    end
  end

  defp started?(%Board{tournament_id: tournament, round: round, board_no: no})
       when is_integer(round) and is_integer(no) do
    case Alnasl.Games.current(tournament, round, no) do
      %{plies: plies, status: "live"} -> plies != "[]"
      _none -> false
    end
  end

  defp started?(_board), do: false

  # Each row goes where its board is. The port is let go of before the other
  # row opens it.
  defp exchange(%Board{} = row, %Board{} = owner) do
    here = Map.take(row, [:driver, :port, :address])
    there = Map.take(owner, [:driver, :port, :address])
    Boards.stop(row)
    Boards.stop(owner)
    {:ok, owner} = Boards.update(owner, Map.put(here, :enabled, true))
    {:ok, _row} = Boards.update(Boards.get!(row.id), there)

    Log.add(
      :info,
      "board.recognised",
      %{
        name: owner.name,
        serial: owner.serial,
        from: there.port,
        to: here.port,
        table: owner.table_no
      },
      ref(owner)
    )

    {:exchanged, owner}
  end

  defp split(%Board{} = row, seen) do
    Boards.stop(row)
    {:ok, parked} = Boards.update(row, %{enabled: false})

    {:ok, fresh} =
      Boards.create(%{
        name: "Board " <> seen,
        driver: row.driver,
        port: row.port,
        address: row.address,
        options: Board.options(row),
        serial: seen
      })

    Log.add(
      :warn,
      "board.replaced",
      %{name: parked.name, serial: parked.serial, seen: seen, new: fresh.name},
      ref(parked)
    )

    {:split, fresh}
  end

  defp connected?(%Board{} = board), do: Boards.snapshot(board).connected? == true

  defp take_over(%Board{} = known, %Board{} = fresh) do
    Boards.stop(fresh)
    Repo.delete(fresh)
    Phoenix.PubSub.broadcast(Alnasl.PubSub, "boards", {:board, fresh.id})

    {:ok, board} =
      Boards.update(known, %{
        driver: fresh.driver,
        port: fresh.port,
        address: fresh.address,
        firmware: fresh.firmware || known.firmware,
        enabled: true
      })

    Log.add(
      :info,
      "board.recognised",
      %{
        name: board.name,
        serial: board.serial,
        from: known.port,
        to: fresh.port,
        table: board.table_no
      },
      ref(board)
    )

    {:recognised, board}
  end

  # --- ready or not ------------------------------------------------------------

  @doc """
  What stands between a tournament's boards and its round `round`: a list of
  `%{level, what, board_id}` with `level` `:bad` (a board would feed the
  wrong game, or none), `:warn` (look at this) or `:info` (so you know), and
  `what` a tuple naming the trouble:

  | what | |
  |---|---|
  | `{:duplicate_table, n, names}` | two boards carry the same sticker |
  | `{:duplicate_board, n, names}` | two boards feed the same board of the round |
  | `{:same_serial, serial, names}` | one board seen twice: two adapters on one loop, or the same board added on two ports |
  | `{:other_board, name, serial, seen}` | the board on this row's port says it is another one, mid-game: left alone, and said |
  | `{:no_signal, name, n}` | a numbered board does not answer |
  | `{:start_wrong, name, n, count}` | no move yet and the pieces are not where the game starts: colours swapped, a piece missing |
  | `{:clock_wrong, name, n, side}` | no move yet and the clock is not in its starting position: `side`'s time would run first (`Alnasl.Clock.start_check/1`). Only for a board that has a clock |
  | `{:no_number, name}` | a connected board that feeds no board of this round |
  | `{:no_table, name}` | a board without a table number |
  | `{:gap, n}` | a board of the round, below the highest one that has a physical board, has none |
  | `{:gap_match, n, match, place}` | the same, in a team event: board `place` of match `match` |
  | `{:part_match, match, have, of}` | a team event: `have` of the match's `of` boards are on electronic boards |
  | `{:turned, name, n}` | plugged in turned round - noticed, and read the other way up |
  | `{:remapped, name, table, n}` | feeds another board than its sticker says, as asked |
  | `{:uncovered, count}` | boards of the round beyond the electronic ones |
  | `{:outside, name, titles}` | a board of the box's own tournament while a linked one exists: what it reads goes nowhere |
  """
  def checks(round), do: checks(Tournaments.default_id(), round)

  def checks(tournament_id, round, snapshots \\ nil) do
    all = snapshots || Boards.snapshots()
    # A sticker is on one board and a serial is one board, whatever
    # tournament; the rest is about this tournament's boards.
    snaps = Enum.filter(all, &(&1[:tournament_id] == tournament_id))
    here = Enum.filter(snaps, &(&1.round == round and &1.board_no != nil))
    by_no = Enum.group_by(here, & &1.board_no)
    pairings = Tournaments.boards(tournament_id, round)
    paired = Enum.map(pairings, & &1.board)
    in_match = Map.new(pairings, &{&1.board, &1.match})
    top = here |> Enum.map(& &1.board_no) |> Enum.max(fn -> 0 end)

    duplicates(all, & &1[:table_no], :duplicate_table) ++
      duplicates(here, & &1.board_no, :duplicate_board) ++
      duplicates(
        Enum.filter(all, &(&1.driver in @dgt)),
        &serial/1,
        :same_serial
      ) ++
      outside_checks(tournament_id, snaps) ++
      Enum.flat_map(snaps, &board_checks(&1, round)) ++
      for(n <- paired, n < top, not is_map_key(by_no, n), do: issue(:warn, gap(n, in_match[n]))) ++
      match_checks(pairings, by_no) ++
      case Enum.count(paired, &(&1 > top)) do
        0 -> []
        _all when top == 0 -> []
        count -> [issue(:info, {:uncovered, count})]
      end
  end

  # In a team event a board is named by its match too: "board 7" alone
  # sends the arbiter counting.
  defp gap(n, %{number: match, board: place}), do: {:gap_match, n, match, place}
  defp gap(n, _none), do: {:gap, n}

  # A match the box follows only in part: some of its boards are on
  # electronic boards, some are not. Said, not refused - it may be meant.
  defp match_checks(pairings, by_no) do
    pairings
    |> Enum.filter(&(&1.match != nil and &1.kind == "game"))
    |> Enum.group_by(& &1.match.number)
    |> Enum.sort()
    |> Enum.flat_map(fn {match, boards} ->
      have = Enum.count(boards, &is_map_key(by_no, &1.board))

      if have > 0 and have < length(boards),
        do: [issue(:info, {:part_match, match, have, length(boards)})],
        else: []
    end)
  end

  # A board in the box's own tournament while a linked one exists: it reads
  # a game that goes nowhere.
  defp outside_checks(tournament_id, snaps) do
    with %Tournaments.Tournament{kind: "local"} <- Tournaments.get(tournament_id),
         [_ | _] = linked <- Alnasl.Seating.linked() do
      titles = Enum.map(linked, &(Tournaments.title(&1) || ""))
      for s <- snaps, do: issue(:warn, {:outside, s.name, titles}, s.id)
    else
      _fine -> []
    end
  end

  defp serial(%{serial: serial}) when is_binary(serial) and serial != "", do: serial
  defp serial(_none), do: nil

  defp duplicates(snaps, key, what) do
    snaps
    |> Enum.group_by(key)
    |> Enum.filter(fn {value, group} -> value != nil and length(group) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {value, group} ->
      issue(:bad, {what, value, group |> Enum.map(& &1.name) |> Enum.sort()})
    end)
  end

  defp board_checks(s, round) do
    here? = s.round == round and s.board_no != nil

    List.flatten([
      if(s.connected? and other_serial?(s),
        do: issue(:bad, {:other_board, s.name, s.serial, s.info[:serial]}, s.id),
        else: []
      ),
      if(here? and not s.connected?,
        do: issue(:bad, {:no_signal, s.name, s.board_no}, s.id),
        else: []
      ),
      if(here? and s.connected? and s.plies == [] and s.problems != [],
        do: issue(:bad, {:start_wrong, s.name, s.board_no, length(s.problems)}, s.id),
        else: []
      ),
      # The clock is part of the starting position: a board whose clock would
      # run Black's side first is not ready, however neat its pieces.
      case s[:clock_check] do
        {:wrong, side} when here? and s.connected? and s.plies == [] ->
          issue(:bad, {:clock_wrong, s.name, s.board_no, side}, s.id)

        _fine ->
          []
      end,
      if(not here? and s.running?, do: issue(:warn, {:no_number, s.name}, s.id), else: []),
      if(s[:table_no] == nil and (here? or s.running?),
        do: issue(:warn, {:no_table, s.name}, s.id),
        else: []
      ),
      if(here? and s.flipped, do: issue(:info, {:turned, s.name, s.board_no}, s.id), else: []),
      if(here? and s[:table_no] != nil and home_board(s) != s.board_no,
        do: issue(:info, {:remapped, s.name, s[:table_no], s.board_no}, s.id),
        else: []
      )
    ])
  end

  defp other_serial?(%{serial: serial, info: %{serial: seen}})
       when is_binary(serial) and serial != "" and is_binary(seen),
       do: seen != serial

  defp other_serial?(_snapshot), do: false

  defp issue(level, what, board_id \\ nil), do: %{level: level, what: what, board_id: board_id}

  @doc "Nothing bad and nothing to look at."
  def ready?(checks), do: not Enum.any?(checks, &(&1.level in [:bad, :warn]))

  defp ref(%Board{} = board),
    do: %{board_id: board.id, round: board.round, board_no: board.board_no}

  # The boards of a hall (the box's own for `nil`). Table numbers are a
  # hall's: table 3 here and table 3 in the hall a bridge brings are two
  # tables.
  defp in_hall(hall_id) do
    own = Alnasl.Halls.own_id()
    hall_id = hall_id || own
    Enum.filter(Boards.list(), &((&1.hall_id || own) == hall_id))
  end
end

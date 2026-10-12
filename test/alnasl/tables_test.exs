defmodule Alnasl.TablesTest do
  @moduledoc """
  Which physical board is which number: identity that survives another
  port, the table number and the board of the round kept apart, finding a
  board by touching it, numbering a hall by touching, and the list of what
  is not ready - with emulated DGT boards and simulator boards.
  """

  use Alnasl.HallCase

  alias Alnasl.{Finder, Tables}
  alias Alnasl.Dgt.Emulator
  alias Alnasl.Transport.Fake

  setup do
    Finder.reset()

    on_exit(fn ->
      Application.delete_env(:alnasl, :finder_idle_ms)
      Finder.reset()
    end)

    :ok
  end

  # A DGT board in software that reports `serial`, on `port`.
  defp dgt(port, serial, attrs \\ %{}) do
    start_supervised!({Fake, port: port, device: {Emulator, Emulator.new(serial: serial)}},
      id: port
    )

    {:ok, board} =
      Boards.create(Map.merge(%{name: "DGT " <> port, driver: "dgt_serial", port: port}, attrs))

    eventually(fn -> Boards.get!(board.id).serial == serial end)
    eventually(fn -> Boards.snapshot(board.id).raw != nil end)
    Boards.get!(board.id)
  end

  defp sim(name, attrs \\ %{}) do
    {:ok, board} =
      Boards.create(
        Map.merge(
          %{
            name: name,
            driver: "simulator",
            port: "sim-" <> name,
            options: %{"moves" => ~w(e4 e5), "speed" => 1, "start_delay_ms" => 600_000}
          },
          attrs
        )
      )

    board
  end

  # Lifts the e2 pawn and puts it back: two touches, like a hand.
  defp lift(port) do
    lifted = Position.start() |> put_elem(52, nil)
    set_pieces(port, lifted)
    set_pieces(port, Position.start())
  end

  defp whats(checks), do: Enum.map(checks, & &1.what)

  describe "identity" do
    test "a board is known by its serial; without one by its address, slot or port" do
      board = dgt("FAKE-ID", "06310")
      assert Tables.identity(board) == {:serial, "06310"}
      assert Tables.identity(Boards.snapshot(board.id)) == {:serial, "06310"}
      assert Tables.lasting_identity?(board)

      assert Tables.identity(%{driver: "dgt_bus", address: 5, port: "COM3", serial: nil}) ==
               {:address, 5}

      assert Tables.identity(sim("s")) == {:slot, "sim-s"}

      assert Tables.identity(%{driver: "dgt_serial", port: "COM7", serial: nil}) ==
               {:port, "COM7"}

      refute Tables.lasting_identity?(%{driver: "dgt_serial", port: "COM7", serial: nil})
    end

    test "a known board that comes back on another port keeps its row, its table and its game" do
      board = dgt("FAKE-OLD", "06310", %{name: "Top board"})
      {:ok, _} = Tables.set_table(board, 3)
      assert %{table_no: 3, round: 1, board_no: 3} = Boards.get!(board.id)
      play_on("FAKE-OLD", board.id, ~w(e4 e5))

      # The cable is pulled, the box restarted; the board ends up on another port.
      Boards.disconnect(Boards.get!(board.id))
      stop_supervised!("FAKE-OLD")
      refute Boards.snapshot(board.id).connected?

      start_supervised!(
        {Fake,
         port: "FAKE-NEW",
         device:
           {Emulator, Emulator.new(serial: "06310", board: List.last(boards_after(~w(e4 e5))))}},
        id: "FAKE-NEW"
      )

      {:ok, added} = Boards.create(%{name: "Board 2", driver: "dgt_serial", port: "FAKE-NEW"})
      assert Tables.new?(added)

      # It says who it is, and the box knows it.
      eventually(fn -> Boards.get(added.id) == nil end)

      assert [%{id: id, port: "FAKE-NEW", table_no: 3, board_no: 3, name: "Top board"} = known] =
               Boards.list()

      assert id == board.id and known.enabled
      eventually(fn -> Boards.snapshot(board.id).connected? end)
      assert sans(board.id) == ~w(e4 e5)

      play_on("FAKE-NEW", board.id, ~w(Nf3), ~w(e4 e5))
      assert Games.sans(Games.get(1, 3)) == ~w(e4 e5 Nf3)
      assert Enum.any?(Alnasl.Log.list(), &(&1.kind == "board.recognised"))
    end

    # Another board on the same port: the device behind `port` now reports `serial`.
    defp swap_device(port, serial, position \\ Position.start()) do
      stop_supervised!(port)

      start_supervised!(
        {Fake, port: port, device: {Emulator, Emulator.new(serial: serial, board: position)}},
        id: port
      )
    end

    test "ports that come up in another order: each row finds its own board, tables stay put" do
      a = dgt("FAKE-X", "00001", %{name: "A"})
      b = dgt("FAKE-Y", "00002", %{name: "B"})
      Tables.set_table(a, 1)
      Tables.set_table(b, 2)

      # The box is restarted; what was the first port is now the second.
      Boards.disconnect(Boards.get!(a.id))
      Boards.disconnect(Boards.get!(b.id))
      swap_device("FAKE-X", "00002")
      swap_device("FAKE-Y", "00001")
      Boards.connect(Boards.get!(a.id))
      Boards.connect(Boards.get!(b.id))

      eventually(fn ->
        Boards.get!(a.id).port == "FAKE-Y" and Boards.get!(b.id).port == "FAKE-X" and
          Boards.snapshot(a.id).connected? and Boards.snapshot(b.id).connected?
      end)

      assert %{serial: "00001", table_no: 1, board_no: 1} = Boards.get!(a.id)
      assert %{serial: "00002", table_no: 2, board_no: 2} = Boards.get!(b.id)
      assert length(Boards.list()) == 2

      # And it stays that way: no row goes back and forth.
      lift("FAKE-Y")
      eventually(fn -> Finder.state().last && Finder.state().last.board_id == a.id end)
      assert Boards.get!(a.id).port == "FAKE-Y" and Boards.get!(b.id).port == "FAKE-X"
      assert Tables.ready?(Tables.checks(1))
    end

    test "an unknown board on a known cable, before the round: a new board, and the known one waits" do
      a = dgt("FAKE-X", "00001", %{name: "A"})
      Tables.set_table(a, 7)

      Boards.disconnect(Boards.get!(a.id))
      swap_device("FAKE-X", "09999")
      Boards.connect(Boards.get!(a.id))

      fresh = eventually(fn -> Enum.find(Boards.list(), &(&1.serial == "09999")) end)
      assert %{port: "FAKE-X", table_no: nil, board_no: nil, name: "Board 09999"} = fresh
      assert Tables.new?(fresh)
      # The row that is table 7 is still board 00001: it did not become the stranger.
      assert %{serial: "00001", table_no: 7, board_no: 7, enabled: false} = Boards.get!(a.id)
      eventually(fn -> Boards.snapshot(fresh.id).connected? end)

      whats = whats(Tables.checks(1))
      assert {:no_signal, "A", 7} in whats and {:no_table, "Board 09999"} in whats

      # The arbiter says the spare is table 7 now: it takes the sticker and the board.
      {:ok, _} = Tables.set_table(Boards.get!(fresh.id), 7)
      assert %{table_no: 7, board_no: 7} = Boards.get!(fresh.id)
      assert %{table_no: nil, board_no: nil} = Boards.get!(a.id)
    end

    test "mid-game a different serial changes nothing: it is logged and listed" do
      a = dgt("FAKE-X", "00001", %{name: "A"})
      Tables.set_table(a, 1)
      play_on("FAKE-X", a.id, ~w(e4 e5))

      Boards.disconnect(Boards.get!(a.id))
      swap_device("FAKE-X", "0000?", List.last(boards_after(~w(e4 e5))))
      Boards.connect(Boards.get!(a.id))
      eventually(fn -> Boards.snapshot(a.id).info[:serial] == "0000?" end)
      eventually(fn -> Enum.any?(Alnasl.Log.list(), &(&1.kind == "board.other_serial")) end)

      assert [%{serial: "00001", table_no: 1, board_no: 1, enabled: true}] = Boards.list()
      assert {:other_board, "A", "00001", "0000?"} in whats(Tables.checks(1))
      play_on("FAKE-X", a.id, ~w(Nf3), ~w(e4 e5))
      assert sans(a.id) == ~w(e4 e5 Nf3)
    end

    test "a serial the box has never seen is a new board, asking for a number" do
      known = dgt("FAKE-K", "11111")
      Tables.set_table(known, 1)
      fresh = dgt("FAKE-F", "22222")

      assert Tables.new?(fresh)
      assert Tables.recognise(fresh.id) == :new
      assert length(Boards.list()) == 2
      assert {:no_table, fresh.name} in whats(Tables.checks(1))
    end

    test "the same serial connected twice is not merged: it is reported" do
      one = dgt("FAKE-1", "33333")
      Tables.set_table(one, 1)
      two = dgt("FAKE-2", "33333")

      assert Tables.recognise(two.id) == :duplicate
      assert length(Boards.list()) == 2
      assert {:same_serial, "33333", [one.name, two.name]} in whats(Tables.checks(1))
      refute Tables.ready?(Tables.checks(1))
    end
  end

  describe "table number and board of the round" do
    test "the board of the round follows the table number; a sticker is on one board" do
      a = sim("a")
      b = sim("b")

      {:ok, a} = Tables.set_table(a, 7)
      assert %{table_no: 7, round: 1, board_no: 7} = a

      # The sticker moves to another board: the first one loses it.
      {:ok, b} = Tables.set_table(b, 7)
      assert %{table_no: 7, board_no: 7} = b
      assert %{table_no: nil, board_no: nil} = Boards.get!(a.id)

      {:ok, b} = Tables.set_table(b, nil)
      assert b.table_no == nil and b.board_no == 7
    end

    test "for a round a table can play another board, two can swap, and it can be put back" do
      {:ok, a} = Tables.set_table(sim("a"), 1)
      {:ok, b} = Tables.set_table(sim("b"), 2)
      {:ok, c} = Tables.set_table(sim("c"), 7)

      {:ok, c} = Tables.remap(c, 3)
      assert %{table_no: 7, board_no: 3} = c
      assert Tables.remapped?(c)
      assert {:remapped, "c", 7, 3} in whats(Tables.checks(1))
      # Told to you, not held against you.
      assert Enum.find(Tables.checks(1), &(&1.what == {:remapped, "c", 7, 3})).level == :info

      # Changing the sticker of a remapped board leaves the round alone.
      {:ok, c} = Tables.set_table(c, 8)
      assert %{table_no: 8, board_no: 3} = c

      :ok = Tables.swap(a, b)
      assert %{table_no: 1, board_no: 2} = Boards.get!(a.id)
      assert %{table_no: 2, board_no: 1} = Boards.get!(b.id)

      {:ok, a} = Tables.clear_remap(Boards.get!(a.id))
      assert a.board_no == 1
      # Board 1 has one physical board: the other let go of it.
      assert Boards.get!(b.id).board_no == nil

      Tables.clear_remaps()
      assert %{board_no: 2} = Boards.get!(b.id)
      assert %{board_no: 8} = Boards.get!(c.id)
      refute Enum.any?(Boards.list(), &Tables.remapped?/1)
    end

    test "the next round starts from the table numbers again" do
      {:ok, a} = Tables.set_table(sim("a"), 1)
      {:ok, b} = Tables.set_table(sim("b"), 2)
      Tables.swap(a, b)
      loose = sim("loose", %{round: 1, board_no: 4})

      Boards.move_to_round(2)
      assert %{round: 2, board_no: 1, table_no: 1} = Boards.get!(a.id)
      assert %{round: 2, board_no: 2, table_no: 2} = Boards.get!(b.id)
      # A board without a sticker keeps the board number it had.
      assert %{round: 2, board_no: 4, table_no: nil} = Boards.get!(loose.id)
    end

    test "numbering in connection order gives table and board in one go" do
      a = sim("a")
      b = sim("b")
      c = sim("c")
      Tables.number_in_order(1, 5)

      assert [{5, 5}, {6, 6}, {7, 7}] =
               for(x <- [a, b, c], y = Boards.get!(x.id), do: {y.table_no, y.board_no})
    end
  end

  describe "finding a board by touching it" do
    test "the board that just changed is the board that was touched, with its time" do
      Finder.subscribe()
      a = dgt("FAKE-A", "00001")
      b = dgt("FAKE-B", "00002")
      assert Finder.state().last == nil

      lift("FAKE-B")
      assert_receive {:finder, {:touch, id, at}}, 2_000
      assert id == b.id and is_integer(at)
      assert eventually(fn -> Finder.state().last end).board_id == b.id

      # Several boards touched: the newest wins, each keeps its time.
      lift("FAKE-A")
      eventually(fn -> Finder.state().last.board_id == a.id end)
      touches = Finder.state().touches
      assert Map.keys(touches) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert touches[a.id] >= touches[b.id]
    end

    test "a board read again without a change is not a touch" do
      Finder.subscribe()
      dgt("FAKE-Q", "00009")
      # The driver re-reads the whole board now and then; nothing moved.
      set_pieces("FAKE-Q", Position.start())
      refute_receive {:finder, {:touch, _, _}}, 400
      assert Finder.state().touches == %{}
    end
  end

  describe "a clock is not a board" do
    test "a lever pressed, a clock set or switched off is not a touch, and numbers nothing" do
      Finder.subscribe()
      a = dgt("FAKE-A", "00001")
      Finder.start_wizard(1)

      # Somebody sets the clocks while the arbiter walks the hall.
      set_clock("FAKE-A", {:still, :white})
      eventually(fn -> Boards.snapshot(a.id).clock_check == :ok end)
      set_clock("FAKE-A", {:still, :black})
      eventually(fn -> Boards.snapshot(a.id).clock_check == {:wrong, :black} end)
      set_clock("FAKE-A", :white)
      eventually(fn -> Boards.snapshot(a.id).clock_check == :ok end)
      set_clock("FAKE-A", :off)
      eventually(fn -> Boards.snapshot(a.id).clock_check == nil end)

      refute_receive {:finder, {:touch, _, _}}, 300
      refute_received {:finder, {:assigned, _}}
      assert Finder.state().touches == %{}
      assert %{next: 1, done: []} = Finder.state().wizard
      assert Boards.get!(a.id).table_no == nil

      # A piece is.
      lift("FAKE-A")
      assert_receive {:finder, {:assigned, %{table: 1, serial: "00001"}}}, 2_000
    end
  end

  describe "numbering the boards by touching them" do
    test "each board touched for the first time gets the next number; undo, skip, stop" do
      Finder.subscribe()
      a = dgt("FAKE-A", "00001")
      b = dgt("FAKE-B", "00002")
      c = dgt("FAKE-C", "00003")
      _spare = dgt("FAKE-D", "00004")

      assert %{wizard: %{next: 1, done: []}} = Finder.start_wizard(1)

      # Table 1's board is c: the order of touching is the order of the tables.
      lift("FAKE-C")
      assert_receive {:finder, {:assigned, %{table: 1, serial: "00003", board_id: id}}}, 2_000
      assert id == c.id
      assert %{table_no: 1, round: 1, board_no: 1} = Boards.get!(c.id)

      # Putting the piece back, or touching it again, gives no second number.
      assert_receive {:finder, {:already, %{table: 1}}}, 2_000
      lift("FAKE-C")
      eventually(fn -> Finder.state().wizard.next == 2 end)
      assert length(Finder.state().wizard.done) == 1

      lift("FAKE-A")
      assert_receive {:finder, {:assigned, %{table: 2, serial: "00001"}}}, 2_000
      assert Boards.get!(a.id).table_no == 2

      # Wrong board: take it back. The number is free again, the board as it was.
      assert %{wizard: %{next: 2, done: [%{table: 1}]}} = Finder.undo()
      assert %{table_no: nil, board_no: nil} = Boards.get!(a.id)

      # Table 2 is empty today.
      assert %{wizard: %{next: 3, skipped: [2]}} = Finder.skip()
      # No, it is not: undo undoes the skip.
      assert %{wizard: %{next: 2, skipped: []}} = Finder.undo()
      assert %{wizard: %{next: 3}} = Finder.skip()

      lift("FAKE-B")
      assert_receive {:finder, {:assigned, %{table: 3, serial: "00002"}}}, 2_000
      assert Boards.get!(b.id).table_no == 3

      assert %{wizard: nil} = Finder.stop()
      lift("FAKE-A")
      eventually(fn -> Finder.state().last.board_id == a.id end)
      # Stopped: a touch is only a touch.
      assert Boards.get!(a.id).table_no == nil
    end

    test "the run lives on the box: whoever asks sees the same, and it ends when all are numbered" do
      Finder.subscribe()
      a = dgt("FAKE-A", "00001")
      b = dgt("FAKE-B", "00002")
      Finder.start_wizard(11)

      # Two devices, or one that lost its connection and came back: the
      # state is asked from the box each time, never remembered by the page.
      phone = Task.async(fn -> Finder.state() end) |> Task.await()
      kiosk = Finder.state()
      assert phone == kiosk
      assert phone.wizard.next == 11

      lift("FAKE-B")
      assert_receive {:finder, {:assigned, %{table: 11}}}, 2_000
      assert Task.async(fn -> Finder.state().wizard.next end) |> Task.await() == 12

      lift("FAKE-A")
      assert_receive {:finder, {:assigned, %{table: 12}}}, 2_000
      assert_receive {:finder, :complete}, 2_000
      assert Finder.state().wizard == nil
      assert %{table_no: 12, board_no: 12} = Boards.get!(a.id)
      assert %{table_no: 11, board_no: 11} = Boards.get!(b.id)
    end

    test "a run nobody touches ends by itself" do
      dgt("FAKE-A", "00001")
      Application.put_env(:alnasl, :finder_idle_ms, 50)
      Finder.start_wizard(1)
      eventually(fn -> Finder.state().wizard == nil end)
    end
  end

  describe "ready or not" do
    test "a hall that is ready says nothing bad" do
      a = dgt("FAKE-A", "00001")
      b = dgt("FAKE-B", "00002")
      Tables.set_table(a, 1)
      Tables.set_table(b, 2)
      eventually(fn -> Boards.snapshot(b.id).status == :waiting_start end)

      checks = Tables.checks(1)
      assert Tables.ready?(checks)
      # Boards 3 and 4 of the test tournament have no electronic board: said, not held against.
      assert whats(checks) == [{:uncovered, 2}]
    end

    test "everything that would feed the wrong game or none is listed, with the board" do
      assert length(Alnasl.Tournaments.boards(own().id, 1)) == 4

      a = dgt("FAKE-A", "00001", %{name: "A"})
      b = dgt("FAKE-B", "00002", %{name: "B"})
      c = dgt("FAKE-C", "00003", %{name: "C"})
      d = dgt("FAKE-D", "00003", %{name: "D"})

      Tables.set_table(a, 1)
      Tables.set_table(b, 4)
      eventually(fn -> Boards.snapshot(b.id).status == :waiting_start end)

      # A: king and queen swapped on the white side.
      swapped =
        Position.start() |> put_elem(59, {:w, :k}) |> put_elem(60, {:w, :q})

      set_pieces("FAKE-A", swapped)
      eventually(fn -> Boards.snapshot(a.id).problems != [] end)

      # B: switched off.
      Boards.disconnect(Boards.get!(b.id))

      whats = whats(Tables.checks(1))
      assert {:same_serial, "00003", ["C", "D"]} in whats
      assert Enum.any?(whats, &match?({:start_wrong, "A", 1, _count}, &1))
      assert {:no_signal, "B", 4} in whats
      assert {:no_number, "C"} in whats and {:no_table, "C"} in whats
      assert {:gap, 2} in whats and {:gap, 3} in whats
      refute Tables.ready?(Tables.checks(1))

      # Two boards on one board of the round, and two with the same sticker,
      # cannot be made through the site - but a database can be restored.
      for x <- [c, d] do
        Boards.get!(x.id)
        |> Ecto.Changeset.change(%{table_no: 9, round: 1, board_no: 2})
        |> Repo.update!()

        Boards.restart(Boards.get!(x.id))
      end

      whats = whats(Tables.checks(1))
      assert {:duplicate_table, 9, ["C", "D"]} in whats
      assert {:duplicate_board, 2, ["C", "D"]} in whats
    end

    test "a clock that would run Black's side first is a reason, and goes when the clock is right" do
      a = dgt("FAKE-A", "00001", %{name: "A"})
      Tables.set_table(a, 1)
      eventually(fn -> Boards.snapshot(a.id).status == :waiting_start end)
      assert Tables.ready?(Tables.checks(1))

      set_clock("FAKE-A", {:still, :black})
      eventually(fn -> Boards.snapshot(a.id).clock_check == {:wrong, :black} end)
      checks = Tables.checks(1)
      assert {:clock_wrong, "A", 1, :black} in whats(checks)
      refute Tables.ready?(checks)

      check = Enum.find(checks, &match?(%{what: {:clock_wrong, _, _, _}}, &1))
      assert check.board_id == a.id

      assert {"bad", sentence} = AlnaslWeb.TableWords.check(check)
      assert sentence =~ "Board 1" and sentence =~ "Clock not in starting position"
      assert sentence =~ "Black's side would run first"

      set_clock("FAKE-A", {:still, :white})
      eventually(fn -> Boards.snapshot(a.id).clock_check == :ok end)
      assert Tables.ready?(Tables.checks(1))

      # No clock is no reason either.
      set_clock("FAKE-A", :off)
      eventually(fn -> Boards.snapshot(a.id).clock_check == nil end)
      assert Tables.ready?(Tables.checks(1))
    end

    test "a board plugged in turned round is noticed, read the other way up, and mentioned" do
      start_supervised!(
        {Fake,
         port: "FAKE-T",
         device:
           {Emulator, Emulator.new(serial: "00007", board: Position.rotate(Position.start()))}},
        id: "FAKE-T"
      )

      {:ok, board} =
        Boards.create(%{name: "T", driver: "dgt_serial", port: "FAKE-T", round: 1, board_no: 1})

      eventually(fn -> Boards.get!(board.id).flipped end)
      Tables.set_table(Boards.get!(board.id), 1)
      checks = Tables.checks(1)
      assert {:turned, "T", 1} in whats(checks)
      assert Tables.ready?(checks)
    end
  end
end

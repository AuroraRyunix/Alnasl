defmodule Alnasl.LoopsTest do
  @moduledoc """
  A port is added, and the box works out what is on it: one board or a loop.
  Nobody types an address.

  The boards are emulated (`Arkab.Dgt.Emulator`), set up as the two real
  ones of 2026-10-12 were: 06310 with firmware 1.9, whose address is its
  serial number, and a newer one that answers as 12799 and whose serial
  number is something else.
  """

  use Alnasl.HallCase

  alias Alnasl.{Loops, Tables}
  alias Arkab.Dgt.{Bus, Emulator, Loop}
  alias Arkab.Transport.Fake

  defp old_board(attrs \\ []),
    do: Emulator.new(Keyword.merge([serial: "06310", version: "1.9"], attrs))

  defp new_board(attrs \\ []),
    do: Emulator.new(Keyword.merge([serial: "40730", version: "4.0", address: 12_799], attrs))

  defp line(port, device),
    do: start_supervised!({Fake, port: port, device: {Emulator, device}}, id: port)

  defp loop_rows(port) do
    Boards.list()
    |> Enum.filter(&(&1.port == port and &1.driver != "dgt_serial"))
    |> Enum.sort_by(& &1.address)
  end

  defp connected(board) do
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    Boards.get!(board.id)
  end

  describe "who is on the line" do
    test "two boards, found with no prior knowledge" do
      line("FAKE-L1", [old_board(), new_board()])
      assert Loops.probe("FAKE-L1") == {:ok, [6310, 12_799]}
    end

    test "an old board in single-board mode misses the first ping and is found by the second" do
      line("FAKE-L2", [%{old_board() | deaf?: true}, new_board()])
      {:ok, handle} = Fake.open("FAKE-L2", [])
      assert Loop.discover(Fake, handle) == [6310, 12_799]
    end

    test "one board, nobody, and a port that is not there" do
      line("FAKE-L3", new_board())
      assert Loops.probe("FAKE-L3") == {:ok, [12_799]}

      start_supervised!({Fake, port: "FAKE-L4"}, id: "FAKE-L4")
      assert Loops.probe("FAKE-L4") == {:ok, []}
      assert {:error, _reason} = Loops.probe("FAKE-nowhere")
    end

    test "the boards are left as a program that expects single boards would like them" do
      line("FAKE-L5", [old_board(), new_board()])
      {:ok, _} = Loops.probe("FAKE-L5")
      assert String.ends_with?(Fake.written("FAKE-L5"), Bus.command(:end_busmode, 0))
    end
  end

  describe "adding a port" do
    test "a loop: a row for each board, named after the number it answers to" do
      line("FAKE-A1", [old_board(), new_board()])
      assert {:ok, :loop, [first, second]} = Loops.add("FAKE-A1")

      assert {first.driver, first.port, first.address, first.name} ==
               {"dgt_bus", "FAKE-A1", 6310, "Board 06310"}

      assert {second.driver, second.address, second.name} == {"dgt_bus", 12_799, "Board 12799"}

      # The old board says who it is by its address; it is known by its
      # serial number like any single board.
      first = connected(first)
      eventually(fn -> Boards.get!(first.id).serial == "06310" end)
      assert Tables.identity(Boards.get!(first.id)) == {:serial, "06310"}

      # The new one does not: it is known by the number it answers to.
      second = connected(second)
      eventually(fn -> Boards.get!(second.id).firmware == "4.0" end)
      assert Boards.get!(second.id).serial == nil
      assert Tables.identity(Boards.get!(second.id)) == {:address, 12_799}
      assert AlnaslWeb.TableWords.identity(Boards.get!(second.id)) == "no. 12799 on the loop"

      eventually(fn -> Boards.snapshot(first.id).raw == Position.to_text(Position.start()) end)
    end

    test "one board: a single board as before, and the row keeps the number it would answer to on a loop" do
      line("FAKE-A2", new_board())
      assert {:ok, :single, [board]} = Loops.add("FAKE-A2", "Top board")
      assert {board.driver, board.name, board.address} == {"dgt_serial", "Top board", 12_799}
      connected(board)
      eventually(fn -> Boards.get!(board.id).serial == "40730" end)
    end

    test "nobody answers yet, or the port cannot be opened: a single board that keeps trying" do
      start_supervised!({Fake, port: "FAKE-A3"}, id: "FAKE-A3")
      assert {:ok, :single, [board]} = Loops.add("FAKE-A3")
      assert {board.driver, board.address} == {"dgt_serial", nil}

      assert {:ok, :single, [absent]} = Loops.add("FAKE-not-plugged-in")
      assert absent.driver == "dgt_serial"
    end

    test "adding the port of a loop that is being read adds nobody twice" do
      line("FAKE-A4", [old_board(), new_board()])
      {:ok, :loop, boards} = Loops.add("FAKE-A4")
      for board <- boards, do: connected(board)

      assert {:ok, :loop, again} = Loops.add("FAKE-A4")
      assert Enum.map(again, & &1.id) == Enum.map(boards, & &1.id)
      assert length(Boards.list()) == 2
    end
  end

  describe "a loop that was added as one board" do
    test "is read as a loop by itself, without one single-board command" do
      line("FAKE-S1", [old_board(), new_board()])

      {:ok, row} =
        Boards.create(%{name: "Board 1", driver: "dgt_serial", port: "FAKE-S1", options: %{}})

      # Both boards answered the ping: nobody is asked, the port is read as
      # the loop it is, a row for each board.
      eventually(fn -> length(loop_rows("FAKE-S1")) == 2 end)
      [first, second] = loop_rows("FAKE-S1")
      assert Enum.map([first, second], & &1.address) == [6310, 12_799]
      # Nobody had given the row a number: it is gone.
      assert Boards.get(row.id) == nil
      connected(first)
      connected(second)
      assert "loop.read" in log_kinds()

      # Not one single-board command went out: on a loop every board
      # answers those at once.
      written = Fake.written("FAKE-S1")
      for <<byte <- written>>, byte < 0x80 and byte in 0x40..0x55, do: assert(byte == 0x4A)
    end

    test "a second board plugged into a single board's line is noticed" do
      line("FAKE-S2", old_board())

      {:ok, row} =
        Boards.create(%{name: "Board 1", driver: "dgt_serial", port: "FAKE-S2", options: %{}})

      connected(row)
      assert Boards.snapshot(row.id).info[:loop] == nil

      # Now two boards answer every single-board command at once.
      Fake.update("FAKE-S2", fn one -> {<<>>, [one, new_board()]} end)
      eventually(fn -> length(loop_rows("FAKE-S2")) == 2 end, 30_000)
    end

    test "a numbered row whose board is on the loop becomes that board's row" do
      line("FAKE-S3", old_board())
      {:ok, :single, [row]} = Loops.add("FAKE-S3")
      row = connected(row)
      eventually(fn -> Boards.get!(row.id).serial == "06310" end)
      {:ok, row} = Tables.set_table(Boards.get!(row.id), 7)
      assert row.address == 6310

      Fake.update("FAKE-S3", fn one -> {<<>>, [one, new_board()]} end)
      eventually(fn -> length(loop_rows("FAKE-S3")) == 2 end, 30_000)

      # Table 7 is still table 7, still serial 06310 - now read on the loop.
      kept = Boards.get!(row.id)
      assert kept.id in Enum.map(loop_rows("FAKE-S3"), & &1.id)

      assert {kept.driver, kept.address, kept.table_no, kept.serial} ==
               {"dgt_bus", 6310, 7, "06310"}

      assert length(Boards.list()) == 2
    end
  end

  describe "a board the box met alone" do
    test "is known by its serial number on a loop too, whatever its address says" do
      # The newer board, alone on a port: serial 40730, and it answers as 12799.
      line("FAKE-K1", new_board())
      {:ok, :single, [alone]} = Loops.add("FAKE-K1")
      connected(alone)
      eventually(fn -> Boards.get!(alone.id).serial == "40730" end)
      {:ok, _} = Tables.set_table(Boards.get!(alone.id), 3)
      Boards.disconnect(Boards.get!(alone.id))

      # Later it hangs on a loop with another.
      line("FAKE-K2", [old_board(), new_board()])
      {:ok, :loop, boards} = Loops.add("FAKE-K2")

      kept = Boards.get!(alone.id)
      assert kept.id in Enum.map(boards, & &1.id)
      assert {kept.driver, kept.port, kept.address} == {"dgt_bus", "FAKE-K2", 12_799}
      assert {kept.serial, kept.table_no} == {"40730", 3}
      assert Tables.identity(kept) == {:serial, "40730"}
      assert "board.recognised" in log_kinds()
    end
  end
end

defmodule Alnasl.DgtBusTest do
  @moduledoc """
  The bus driver against a loop of emulated boards: the things the real loop
  of 2026-10-12 could not be asked, because nobody was at the boards.

  What a real loop DID show is in `Alnasl.RealLoopTest`, from its
  recordings; the emulator (`Alnasl.Dgt.Emulator`) answers the way those
  recordings do. What is tested here on top of that - a move arriving as a
  change, a clock, a board leaving and coming back, a board joining - is the
  driver against what `Alnasl.Dgt.Bus` still calls ASSUMED. The driver asks
  for the whole board as well, so that these may turn out slower on a real
  loop but not wrong.
  """

  use Alnasl.HallCase

  alias Alnasl.Dgt.{Bus, Emulator}
  alias Alnasl.Driver.DgtBus
  alias Alnasl.Transport.Fake

  describe "what the module says of itself" do
    test "it has met a real loop, and names what that loop did not show" do
      assert Bus.verified?()
      assert Bus.unverified() == [:live_changes, :clock, :more_than_two]
    end

    test "a board's memory is written as it is read" do
      data =
        Bus.field_event(52, nil) <>
          Bus.field_event(36, {:w, :p}) <> Bus.clock_event(:white, 5_458_000)

      assert Bus.changes(data) == [
               {:field, 52, nil},
               {:field, 36, {:w, :p}},
               {:clock, :white, 5_458_000}
             ]

      assert {[{7, {:changes, ^data}}], <<>>} = Bus.parse(Bus.answer(:changes, 7, data))
    end

    test "an answer arrives in pieces, like any serial data" do
      dump = for _ <- 1..64, into: <<>>, do: <<0>>
      <<a::binary-size(20), b::binary>> = Bus.answer(:board, 7, dump)
      assert {[], rest} = Bus.parse(a)
      assert {[{7, {:board, board}}], <<>>} = Bus.parse(rest <> b)
      assert board == Position.empty()
    end
  end

  describe "a loop of three boards" do
    setup do
      start_supervised!({Fake, port: "FAKEBUS", device: {Emulator, Emulator.loop([1, 2, 3])}})

      boards =
        for address <- 1..3 do
          {:ok, board} =
            Boards.create(%{
              name: "Loop #{address}",
              driver: "dgt_bus",
              port: "FAKEBUS",
              address: address,
              round: 1,
              board_no: address
            })

          board
        end

      for board <- boards,
          do:
            eventually(fn ->
              s = Boards.snapshot(board.id)
              s.connected? && s.raw
            end)

      {:ok, boards: boards}
    end

    defp set_loop_board(address, position),
      do: Fake.update("FAKEBUS", &Emulator.set_board(&1, address, position))

    test "each board is read, and a move on one is a move on that one only", %{
      boards: [one, two, three]
    } do
      for board <- [one, two, three] do
        assert Boards.snapshot(board.id).raw == Position.to_text(Position.start())
        assert Boards.snapshot(board.id).status == :waiting_start
      end

      set_loop_board(2, hd(boards_after(~w(d4))))
      eventually(fn -> sans(two.id) == ~w(d4) end)
      assert sans(one.id) == [] and sans(three.id) == []

      set_loop_board(1, hd(boards_after(~w(e4))))
      set_loop_board(3, hd(boards_after(~w(c4))))
      eventually(fn -> sans(one.id) == ~w(e4) and sans(three.id) == ~w(c4) end)

      assert Outbox.drain() == :empty
      assert FakeIngest.game(1, 1).moves == ~w(e4)
      assert FakeIngest.game(1, 2).moves == ~w(d4)
      assert FakeIngest.game(1, 3).moves == ~w(c4)
    end

    test "firmware 1.x says its serial number with its address, and the row keeps it", %{
      boards: [one | _]
    } do
      eventually(fn -> Boards.get!(one.id).serial == "00001" end)
      assert Boards.get!(one.id).firmware == "1.8"
      assert Alnasl.Tables.identity(Boards.get!(one.id)) == {:serial, "00001"}
    end

    test "a board that leaves the loop is counted, reported and taken back", %{
      boards: [one, two, three]
    } do
      # Board 2 is unplugged from the loop: the others stay.
      Fake.update("FAKEBUS", fn loop -> {<<>>, Enum.reject(loop, &(&1.address == 2))} end)
      eventually(fn -> Boards.snapshot(two.id).status == :no_signal end, 10_000)
      assert Boards.snapshot(two.id).stats.polls_missed >= 5

      set_loop_board(1, hd(boards_after(~w(e4))))
      eventually(fn -> sans(one.id) == ~w(e4) end)
      assert Boards.snapshot(three.id).connected?

      {:ok, bus} = DgtBus.ensure("FAKEBUS")
      stats = DgtBus.stats(bus)
      assert Enum.map(stats, & &1.address) == [1, 2, 3]
      assert Enum.find(stats, &(&1.address == 2)).connected? == false
      assert Enum.find(stats, &(&1.address == 1)).answered > 5
      assert DgtBus.present(bus) == [1, 3]

      # Plugged back in, a move later.
      Fake.update("FAKEBUS", fn loop ->
        {<<>>, loop ++ [%{Emulator.new(address: 2) | board: hd(boards_after(~w(d4)))}]}
      end)

      eventually(fn -> Boards.snapshot(two.id).connected? end, 10_000)
      eventually(fn -> sans(two.id) == ~w(d4) end)
    end

    test "a board plugged into the loop later gets a row by itself, and the log says so" do
      Fake.update("FAKEBUS", fn loop -> {<<>>, loop ++ [Emulator.new(address: 4712)]} end)

      added = eventually(fn -> Enum.find(Boards.list(), &(&1.address == 4712)) end, 10_000)
      assert added.driver == "dgt_bus" and added.port == "FAKEBUS"
      assert added.name == "Board 04712"
      eventually(fn -> Boards.snapshot(added.id).connected? end)
      eventually(fn -> Boards.get!(added.id).serial == "04712" end)
      assert "loop.joined" in log_kinds()

      # Once: it is not found again every ten seconds.
      assert Enum.count(Boards.list(), &(&1.address == 4712)) == 1
    end

    test "the port is let go of when the last board of the loop is removed", %{boards: boards} do
      {:ok, bus} = DgtBus.ensure("FAKEBUS")
      ref = Process.monitor(bus)
      for board <- boards, do: Boards.delete(Boards.get!(board.id))
      assert_receive {:DOWN, ^ref, :process, ^bus, _reason}, 2_000

      # Told to leave bus mode on the way out, for whoever reads them next.
      assert String.ends_with?(Fake.written("FAKEBUS"), Bus.command(:end_busmode, 0))
    end
  end

  describe "the driver alone" do
    # One board's driver with this test as its owner: its events arrive here.
    defp attach(port, address, opts \\ []) do
      start_supervised!(
        %{
          id: {:driver, address},
          start:
            {DgtBus, :start_link,
             [
               [
                 owner: self(),
                 id: address,
                 port: port,
                 address: address,
                 stranger: fn _, _ -> :ok end
               ] ++
                 opts
             ]}
        },
        id: {:driver, address}
      )
    end

    test "a move arrives as a change, long before the whole board is asked for again" do
      start_supervised!({Fake, port: "FAKECH", device: {Emulator, Emulator.loop([5])}})
      attach("FAKECH", 5, dump_ms: 600_000)
      assert_receive {:driver, 5, {:position, start}}, 2_000
      assert start == Position.start()

      [e4] = boards_after(~w(e4))
      Fake.update("FAKECH", &Emulator.set_board(&1, 5, e4))

      # A picture per square the board wrote down; the last is the move.
      assert_receive {:driver, 5, {:position, between}}, 1_000
      assert between != start and between != e4
      assert_receive {:driver, 5, {:position, ^e4}}, 1_000
    end

    test "a clock on a loop: read, and asked at once when its lever goes over" do
      start_supervised!({Fake, port: "FAKECL", device: {Emulator, Emulator.loop([5])}})
      attach("FAKECL", 5, clock_ms: 600_000)
      assert_receive {:driver, 5, :connected}, 2_000
      # No clock yet: nothing is said about clocks.
      refute_receive {:driver, 5, {:clock, _}}, 200
      refute_received {:driver, 5, {:info, %{clock: false}}}

      running = %{white_ms: 5_400_000, black_ms: 5_400_000, running: :white}
      Fake.update("FAKECL", &Emulator.set_clock(&1, 5, %{running | running: :none}))
      Fake.update("FAKECL", &Emulator.set_clock(&1, 5, running))

      # The clock is asked every ten minutes here - and still heard now,
      # because the board wrote the lever down.
      assert_receive {:driver, 5, {:clock, %{running: :white, white_ms: 5_400_000}}}, 1_000
    end

    test "an old board plugged in in single-board mode swallows the first question, and is asked again" do
      start_supervised!({Fake, port: "FAKEOLD", device: {Emulator, Emulator.loop([5])}})
      attach("FAKEOLD", 5)
      attach("FAKEOLD", 6310)
      assert_receive {:driver, 5, :connected}, 2_000
      assert_receive {:driver, 6310, {:poll, :missed}}, 1_000

      old = %{Emulator.new(address: 6310, version: "1.9") | deaf?: true}
      Fake.update("FAKEOLD", fn loop -> {<<>>, loop ++ [old]} end)

      assert_receive {:driver, 6310, :connected}, 8_000
      assert_receive {:driver, 6310, {:info, %{serial: "06310", firmware: "1.9"}}}, 1_000
      assert_receive {:driver, 6310, {:position, _}}, 1_000
    end

    test "sixty 'nothing changed' a second are not written into the capture" do
      start_supervised!({Fake, port: "FAKEQ", device: {Emulator, Emulator.loop([5])}})
      attach("FAKEQ", 5, dump_ms: 600_000, clock_ms: 600_000)
      assert_receive {:driver, 5, {:position, _}}, 2_000

      {:ok, bus} = DgtBus.ensure("FAKEQ")
      thirty_more = hd(DgtBus.stats(bus)).answered + 30
      asked_until(bus, thirty_more)

      sent = for {:driver, 5, {:raw, :tx, frame}} <- flush(), do: frame
      # The version, the board, one clock question: not thirty of anything.
      assert length(sent) <= 6
      assert Bus.command(:board, 5) in sent
      assert %{polls: polls, trip_ms: trip} = DgtBus.timing(bus)
      assert polls > 30 and is_integer(trip)
      assert is_integer(DgtBus.timing(bus).cycle_ms)
    end

    # Without `eventually/1`: it empties the mailbox this test counts.
    defp asked_until(bus, count) do
      if hd(DgtBus.stats(bus)).answered < count, do: asked_until(bus, count)
    end

    defp flush(acc \\ []) do
      receive do
        message -> flush([message | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end
end

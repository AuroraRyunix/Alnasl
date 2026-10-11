defmodule Alnasl.DgtBusTest do
  @moduledoc """
  The bus driver: the polling scheduler and the per-address board model,
  against a loop of emulated boards.

  What this proves: that several boards on one port are asked in turn, each
  board's answers go to that board and no other, a board that stops answering
  is counted, reported and taken back when it returns, and the others never
  notice. What it does NOT prove: that a real DGT loop speaks the bytes of
  `Alnasl.Dgt.Bus`. Those are ASSUMED; the emulator assumes the same.
  """

  use Alnasl.HallCase

  alias Alnasl.Dgt.{Bus, Emulator}
  alias Alnasl.Driver.DgtBus
  alias Alnasl.Transport.Fake

  describe "the frames (ASSUMED format, pinned so a correction is one visible change)" do
    test "nothing in the bus module claims to be verified" do
      refute Bus.verified?()
    end

    test "a command is id, address in two 7-bit bytes, checksum" do
      assert <<0x82, 0x00, 0x05, sum>> = Bus.command(:board, 5)
      assert sum == Bus.checksum(<<0x82, 0x00, 0x05>>)
      assert <<0x81, 0x02, 0x2C, _>> = Bus.command(:clock, 300)
      assert Bus.decode_command(Bus.command(:board, 300)) == {:board, 300}
      assert Bus.decode_command(<<0x82, 0x00, 0x05, 0x00>>) == :error
    end

    test "an answer carries its address and is refused on a bad checksum" do
      dump = for _ <- 1..64, into: <<>>, do: <<0>>
      frame = Bus.answer(:board, 7, dump)
      assert {[{7, {:board, board}}], <<>>} = Bus.parse(frame)
      assert board == Position.empty()

      body = binary_part(frame, 0, byte_size(frame) - 1)
      assert {[{:bad_checksum, 7}], <<>>} = Bus.parse(body <> <<0x7F>>)

      # In pieces, like any serial data.
      <<a::binary-size(20), b::binary>> = frame
      assert {[], rest} = Bus.parse(a)
      assert {[{7, {:board, _}}], <<>>} = Bus.parse(rest <> b)
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

    test "a board that leaves the loop is counted, reported and taken back", %{
      boards: [one, two, three]
    } do
      # Board 2 is unplugged from the loop: the others stay.
      Fake.update("FAKEBUS", fn loop -> {<<>>, Enum.reject(loop, &(&1.address == 2))} end)
      eventually(fn -> Boards.snapshot(two.id).status == :no_signal end, 10_000)
      assert Boards.snapshot(two.id).stats.polls_missed >= 8

      set_loop_board(1, hd(boards_after(~w(e4))))
      eventually(fn -> sans(one.id) == ~w(e4) end)
      assert Boards.snapshot(three.id).connected?

      {:ok, bus} = DgtBus.ensure("FAKEBUS")
      stats = DgtBus.stats(bus)
      assert Enum.map(stats, & &1.address) == [1, 2, 3]
      assert Enum.find(stats, &(&1.address == 2)).connected? == false
      assert Enum.find(stats, &(&1.address == 1)).answered > 5

      # Plugged back in, a move later.
      Fake.update("FAKEBUS", fn loop ->
        {<<>>,
         loop ++ [%{Emulator.new(address: 2, bus?: true) | board: hd(boards_after(~w(d4)))}]}
      end)

      eventually(fn -> Boards.snapshot(two.id).connected? end, 10_000)
      eventually(fn -> sans(two.id) == ~w(d4) end)
    end
  end
end

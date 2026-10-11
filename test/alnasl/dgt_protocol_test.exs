defmodule Alnasl.Dgt.ProtocolTest do
  @moduledoc """
  The single-board DGT protocol, pinned with bytes written out by hand.

  These bytes are what the published description says a board sends. They
  were not recorded from a board: the first real capture is the test of this
  test. A test whose name says ASSUMED pins a detail the description left the
  author unsure of; expect those to be the ones a real board corrects.
  """

  use ExUnit.Case, async: true

  alias Alnasl.Dgt.Protocol
  alias Alnasl.Position

  # The start position as a board dump: header 0x86, size 67 = 0x00 0x43.
  @start_dump <<0x86, 0x00, 0x43,
                # rank 8: r n b q k b n r
                0x08, 0x09, 0x0A, 0x0C, 0x0B, 0x0A, 0x09, 0x08,
                # rank 7: black pawns
                0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                # rank 2: white pawns
                0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
                # rank 1: R N B Q K B N R
                0x02, 0x03, 0x04, 0x06, 0x05, 0x04, 0x03, 0x02>>

  describe "commands" do
    test "are the single bytes of the published list" do
      assert Protocol.command(:reset) == <<0x40>>
      assert Protocol.command(:clock) == <<0x41>>
      assert Protocol.command(:board) == <<0x42>>
      assert Protocol.command(:update) == <<0x43>>
      assert Protocol.command(:update_board) == <<0x44>>
      assert Protocol.command(:serial) == <<0x45>>
      assert Protocol.command(:bus_address) == <<0x46>>
      assert Protocol.command(:trademark) == <<0x47>>
      assert Protocol.command(:update_nice) == <<0x4B>>
      assert Protocol.command(:version) == <<0x4D>>
    end

    test "never have bit 7 set, so a command is never mistaken for a message" do
      for {_name, byte} <- Protocol.commands(), do: assert(byte < 0x80)
    end

    test "the line is 9600 baud" do
      assert Protocol.baud() == 9600
    end
  end

  describe "framing" do
    test "a board dump is 67 bytes and reads as the start position" do
      assert byte_size(@start_dump) == 67
      assert Protocol.sizes().board_dump == 67
      assert {[{:board, board}], <<>>} = Protocol.parse(@start_dump)
      assert board == Position.start()
    end

    test "square 0 is a8 and square 63 is h1" do
      {[{:board, board}], <<>>} = Protocol.parse(@start_dump)
      assert elem(board, 0) == {:b, :r}
      assert elem(board, 4) == {:b, :k}
      assert elem(board, 59) == {:w, :q}
      assert elem(board, 63) == {:w, :r}
    end

    test "a field update is five bytes: square and piece" do
      # e2 (square 52) empties, e4 (square 36) gets a white pawn.
      bytes = <<0x8E, 0x00, 0x05, 52, 0x00, 0x8E, 0x00, 0x05, 36, 0x01>>
      assert {[{:field, 52, nil}, {:field, 36, {:w, :p}}], <<>>} = Protocol.parse(bytes)
    end

    test "every piece code" do
      codes = [
        {0x01, {:w, :p}}, {0x02, {:w, :r}}, {0x03, {:w, :n}}, {0x04, {:w, :b}}, {0x05, {:w, :k}}, {0x06, {:w, :q}},
        {0x07, {:b, :p}}, {0x08, {:b, :r}}, {0x09, {:b, :n}}, {0x0A, {:b, :b}}, {0x0B, {:b, :k}}, {0x0C, {:b, :q}},
        {0x00, nil}
      ]

      for {code, piece} <- codes do
        assert {[{:field, 0, ^piece}], <<>>} = Protocol.parse(<<0x8E, 0x00, 0x05, 0, code>>)
      end
    end

    test "the special pieces (0x0D-0x0F) read as an empty square" do
      for code <- [0x0D, 0x0E, 0x0F] do
        assert {[{:field, 10, nil}], <<>>} = Protocol.parse(<<0x8E, 0x00, 0x05, 10, code>>)
      end
    end

    test "a message arriving in pieces is held until it is whole" do
      <<first::binary-size(10), second::binary-size(30), third::binary>> = @start_dump
      assert {[], rest} = Protocol.parse(first)
      assert {[], rest} = Protocol.parse(rest <> second)
      assert {[{:board, _}], <<>>} = Protocol.parse(rest <> third)

      # Even a single header byte.
      assert {[], <<0x8E>>} = Protocol.parse(<<0x8E>>)
      assert {[], <<0x8E, 0x00>>} = Protocol.parse(<<0x8E, 0x00>>)
    end

    test "several messages in one read, and a partial one after them" do
      bytes = <<0x8E, 0x00, 0x05, 52, 0x00>> <> @start_dump <> <<0x8E, 0x00>>
      assert {[{:field, 52, nil}, {:board, _}], <<0x8E, 0x00>>} = Protocol.parse(bytes)
    end

    test "bytes that cannot begin a message are skipped" do
      noise = <<0x00, 0x13, 0x7F>>
      assert {[{:field, 52, nil}], <<>>} = Protocol.parse(noise <> <<0x8E, 0x00, 0x05, 52, 0x00>>)
      # A size smaller than a header is not a message.
      assert {[{:field, 1, nil}], <<>>} = Protocol.parse(<<0x8E, 0x00, 0x02, 0x8E, 0x00, 0x05, 1, 0>>)
    end

    test "the size is two 7-bit bytes, high first" do
      # 200 bytes of trademark text: size 203 = 1 * 128 + 75.
      text = String.duplicate("x", 200)
      assert {[{:trademark, ^text}], <<>>} = Protocol.parse(<<0x92, 0x01, 0x4B>> <> text)
    end

    test "serial number, version, bus address" do
      assert {[{:serial, "24681"}], <<>>} = Protocol.parse(<<0x91, 0x00, 0x08, "24681">>)
      assert {[{:version, "1.8"}], <<>>} = Protocol.parse(<<0x93, 0x00, 0x05, 1, 8>>)
      assert {[{:bus_address, 300}], <<>>} = Protocol.parse(<<0x90, 0x00, 0x05, 2, 44>>)
    end

    test "a message with an unknown id is passed on, not dropped" do
      assert {[{:unknown, 0x7A, <<1, 2>>}], <<>>} = Protocol.parse(<<0xFA, 0x00, 0x05, 1, 2>>)
    end
  end

  describe "the clock message" do
    # right 1:29:58, left 1:30:00, status byte last.
    defp bwtime(status), do: <<0x8D, 0x00, 0x0A, 0x01, 0x29, 0x58, 0x01, 0x30, 0x00, status>>

    test "is ten bytes with BCD minutes and seconds, right player first" do
      assert {[{:clock, clock}], <<>>} = Protocol.parse(bwtime(0x01))
      assert clock.right_ms == (1 * 3600 + 29 * 60 + 58) * 1000
      assert clock.left_ms == (1 * 3600 + 30 * 60) * 1000
    end

    test "the flag bits in the high nibble of the hours do not change the time" do
      bytes = <<0x8D, 0x00, 0x0A, 0x11, 0x29, 0x58, 0x41, 0x30, 0x00, 0x01>>
      assert {[{:clock, %{right_ms: 5_398_000, left_ms: 5_400_000}}], <<>>} = Protocol.parse(bytes)
    end

    test "an acknowledgement (low nibble 0x0A in an hours byte) is never read as a time" do
      ack = <<0x8D, 0x00, 0x0A, 0x0A, 0x10, 0x01, 0x00, 0x08, 0x00, 0x00>>
      assert {[{:clock_ack, _}], <<>>} = Protocol.parse(ack)
      ack = <<0x8D, 0x00, 0x0A, 0x00, 0x10, 0x01, 0x0A, 0x08, 0x00, 0x00>>
      assert {[{:clock_ack, _}], <<>>} = Protocol.parse(ack)
    end

    test "ASSUMED: status bit 0 = running, bits 3/4 = Black's/White's turn, bit 5 = no clock" do
      {[{:clock, clock}], _} = Protocol.parse(bwtime(0x01 ||| 0x10))
      assert clock.running? and clock.turn == :white and clock.connected?

      {[{:clock, clock}], _} = Protocol.parse(bwtime(0x01 ||| 0x08))
      assert clock.turn == :black

      {[{:clock, clock}], _} = Protocol.parse(bwtime(0x00))
      refute clock.running?

      {[{:clock, clock}], _} = Protocol.parse(bwtime(0x20))
      refute clock.connected?
      assert Protocol.reading(clock, :left) == nil
    end

    test "ASSUMED: left is White unless the board says the clock stands the other way" do
      {[{:clock, clock}], _} = Protocol.parse(bwtime(0x01 ||| 0x10))
      assert Protocol.reading(clock, :left) == %{white_ms: 5_400_000, black_ms: 5_398_000, running: :white}
      assert Protocol.reading(clock, :right) == %{white_ms: 5_398_000, black_ms: 5_400_000, running: :white}
    end

    test "a stopped clock runs for nobody" do
      {[{:clock, clock}], _} = Protocol.parse(bwtime(0x10))
      assert Protocol.reading(clock, :left).running == :none
    end
  end

  describe "the board model" do
    test "a dump replaces the board, a field update changes one square, and nothing is known before a dump" do
      assert Protocol.apply_message({:field, 52, nil}, nil) == :ignore
      assert {:position, board} = Protocol.apply_message({:board, Position.start()}, nil)
      assert {:position, board} = Protocol.apply_message({:field, 52, nil}, board)
      assert {:position, board} = Protocol.apply_message({:field, 36, {:w, :p}}, board)
      assert Position.placement(board) == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    end

    test "what the board says about itself is info" do
      assert Protocol.apply_message({:serial, "24681"}, nil) == {:info, %{serial: "24681"}}
      assert Protocol.apply_message({:version, "1.8"}, nil) == {:info, %{firmware: "1.8"}}
    end
  end

  describe "writing messages (what the emulator sends)" do
    test "is the inverse of reading them" do
      assert Protocol.encode({:board, Position.start()}) == @start_dump

      for message <- [{:field, 36, {:w, :p}}, {:field, 52, nil}, {:serial, "24681"}, {:version, "1.8"}, {:bus_address, 300}] do
        assert {[^message], <<>>} = message |> Protocol.encode() |> Protocol.parse()
      end

      clock = %{left_ms: 5_400_000, right_ms: 5_398_000, running?: true, turn: :black, lever: :left}
      assert {[{:clock, read}], <<>>} = {:clock, clock} |> Protocol.encode() |> Protocol.parse()
      assert Map.take(read, [:left_ms, :right_ms, :running?, :turn]) == Map.take(clock, [:left_ms, :right_ms, :running?, :turn])
    end
  end

  defp a ||| b, do: Bitwise.bor(a, b)
end

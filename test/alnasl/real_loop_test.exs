defmodule Alnasl.RealLoopTest do
  @moduledoc """
  What a real DGT loop sent, fed back in as it came.

  The fixtures (`test/fixtures/captures/real-loop-*.jsonl`) are the
  recordings of 2026-10-12: two boards on one serial line, 06310 (firmware
  1.9) and a newer one that answers as 12799 (firmware 4.0), no clocks,
  nobody at the boards. `docs/real-loop-2026-10-12.md` says what each
  recording asked.

  First the bytes are read by `Alnasl.Dgt.Bus` and compared with what was
  seen that day. Then the recorded answers are made a device
  (`Alnasl.RecordedLoop`) and the discovery and the bus driver are run
  against it: they ask in their own order, and get what the real boards
  answered to those questions.
  """

  use ExUnit.Case, async: true

  alias Alnasl.Dgt.{Bus, Loop}
  alias Alnasl.Driver.DgtBus
  alias Alnasl.{Position, RecordedLoop}
  alias Alnasl.Transport.Fake

  @old 6310
  @new 12_799
  @old_reads "r1bqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/R1BQKBNR"
  @new_reads "8/8/2N5/8/8/8/n7/8"

  defp answers(name) do
    for {_tx, rx} <- RecordedLoop.exchanges(name),
        {answers, <<>>} = Bus.parse(rx),
        answer <- answers,
        do: answer
  end

  defp answer_to(name, command) do
    {_tx, rx} = Enum.find(RecordedLoop.exchanges(name), fn {tx, _rx} -> tx == command end)
    {[{_address, message}], <<>>} = Bus.parse(rx)
    message
  end

  describe "the frames, as the loop sent them" do
    test "a ping to everybody is answered by both boards, each with its address" do
      found =
        for {address, {:ping, <<>>}} <- answers("real-loop-01-busmode-ping.jsonl"), do: address

      assert Enum.sort(found) == [@old, @old, @old, @new, @new, @new]
    end

    test "what was sent that day is what Bus.command writes" do
      sent =
        for {tx, _rx} <- RecordedLoop.exchanges("real-loop-02-version-board-clock.jsonl"), do: tx

      for {name, address} <- [
            version: @old,
            version: @new,
            board: @old,
            clock: @new,
            changes: @old
          ] do
        assert Bus.command(name, address) in sent
      end

      assert Bus.command(:ping, 0) == <<0x87, 0x00, 0x00, 0x07>>
      assert Bus.command(:version, @old) == <<0x8B, 0x31, 0x26, 0x62>>
      assert Bus.decode_command(<<0x8B, 0x31, 0x26, 0x62>>) == {:version, @old}
      assert Bus.decode_command(<<0x8B, 0x31, 0x26, 0x63>>) == :error
    end

    test "the size counts every byte and the checksum is the sum of the others, low 7 bits" do
      frame = <<0x89, 0x00, 0x08, 0x31, 0x26, 0x01, 0x09, 0x72>>
      assert byte_size(frame) == 8
      assert Bus.checksum(binary_part(frame, 0, 7)) == 0x72
      assert Bus.parse(frame) == {[{@old, {:version, "1.9"}}], <<>>}
      assert Bus.answer(:version, @old, <<1, 9>>) == frame

      # One bit wrong anywhere and it is refused.
      assert {[{:bad_checksum, @old}], _rest} =
               Bus.parse(<<0x89, 0x00, 0x08, 0x31, 0x26, 0x01, 0x08, 0x72>>)
    end

    test "every answer in every recording that was not talked over passes its checksum" do
      for name <- File.ls!("test/fixtures/captures"),
          String.starts_with?(name, "real-loop-0"),
          name not in ["real-loop-04-leave-single-reenter.jsonl", "real-loop-05-modes.jsonl"] do
        for {<<id, _::binary>> = tx, rx} <- RecordedLoop.exchanges(name),
            id >= 0x80,
            rx != <<>> do
          {answers, _rest} = Bus.parse(rx)
          bad = for {:bad_checksum, _} = answer <- answers, do: answer

          # 02 asked the next question while a board was still answering,
          # and 09 has the one ping in twenty where both answered at once.
          unless name in [
                   "real-loop-02-version-board-clock.jsonl",
                   "real-loop-09-ping-delays.jsonl"
                 ] do
            assert bad == [], "#{name}: #{Base.encode16(tx)}"
          end
        end
      end
    end

    test "the firmware versions, and what the address says about the serial number" do
      file = "real-loop-02-version-board-clock.jsonl"
      assert answer_to(file, Bus.command(:version, @old)) == {:version, "1.9"}
      assert answer_to(file, Bus.command(:version, @new)) == {:version, "4.0"}

      # Board 06310 answers as 6310. The newer one's address is not its serial.
      assert Bus.serial(@old, "1.9") == "06310"
      assert Bus.serial(@new, "4.0") == nil
      assert Bus.number(@new) == "12799"
    end

    test "the board dumps: 70 bytes, and the positions that stood there" do
      file = "real-loop-02-version-board-clock.jsonl"
      {:board, old} = answer_to(file, Bus.command(:board, @old))
      {:board, new} = answer_to(file, Bus.command(:board, @new))
      assert Position.placement(old) == @old_reads
      assert Position.placement(new) == @new_reads
    end

    test "the clock answers: 13 bytes, and both boards say no clock is there" do
      file = "real-loop-02-version-board-clock.jsonl"

      for address <- [@old, @new] do
        assert {:clock, %{connected?: false} = clock} =
                 answer_to(file, Bus.command(:clock, address))

        assert Alnasl.Dgt.Protocol.reading(clock) == nil
      end
    end

    test "nothing changed is six bytes" do
      assert <<0x85, 0x00, 0x06, 0x31, 0x26, 0x62>> ==
               RecordedLoop.exchanges("real-loop-03-changes-repeat.jsonl")
               |> Enum.find_value(fn {tx, rx} -> tx == Bus.command(:changes, @old) && rx end)

      assert Bus.parse(<<0x85, 0x00, 0x06, 0x31, 0x26, 0x62>>) ==
               {[{@old, {:changes, <<>>}}], <<>>}
    end

    test "two boards answering a ping at the same moment: the one that began first is lost" do
      # 87 00 06 31 A6 - 06310 was at its fifth byte when 12799 began, and
      # that byte and its checksum went under. 12799's answer came through.
      garbled = RecordedLoop.collision()
      assert garbled == <<0x87, 0x00, 0x06, 0x31, 0xA6, 0x87, 0x00, 0x06, 0x63, 0x7F, 0x6F>>

      # A byte with bit 7 set inside an answer is another answer beginning:
      # the reader takes it from there.
      assert Bus.parse(garbled) == {[{:bad_checksum, nil}, {@new, {:ping, <<>>}}], <<>>}
    end
  end

  describe "a board's memory" do
    # The squares a board wrote down since it was last switched on, applied
    # to an empty board, must be the position its dump shows.
    defp replayed(events) do
      events
      |> Enum.chunk_by(&(&1 == :power_up))
      |> List.last()
      |> Enum.reduce(Position.empty(), fn
        {:field, square, piece}, board -> put_elem(board, square, piece)
        _other, board -> board
      end)
    end

    test "06310 (firmware 1.9): its first answer to 'what changed?' is everything since it was switched on" do
      {:changes, data} =
        answer_to("real-loop-02-version-board-clock.jsonl", Bus.command(:changes, @old))

      assert byte_size(data) == 290 - 6
      events = Bus.changes(data)

      assert :power_up in events
      assert Position.placement(replayed(events)) == @old_reads

      # The clock that stood there earlier: White's last time is 1:32:12,
      # which is what bytes 3-5 of its clock answer still say.
      white = for {:clock, :white, ms} <- events, do: ms
      assert List.last(white) == ((1 * 60 + 32) * 60 + 12) * 1000
    end

    test "12799 (firmware 4.0): the time stamps between the events are skipped" do
      {:from_start, data} =
        answer_to("real-loop-12-journal-tail.jsonl", Bus.command(:from_start, @new))

      events = Bus.changes(data)

      assert hd(events) == :start_mark
      assert Position.placement(replayed(events)) == @new_reads
      # What a single-board command in the middle of a bus answer did to it
      # (docs/real-loop-2026-10-12.md): it restarted itself, and wrote that down.
      assert List.last(events) == :restarted
    end

    test "an event cut off by the end of the data is dropped" do
      assert Bus.changes(<<0x41, 0x24, 0x47>>) == [{:field, 36, {:w, :p}}]

      assert Bus.changes(<<0x40, 0x34, 0x02, 0x41, 0x24, 0x0D, 0x71, 0x30, 0x58>>) ==
               [{:field, 52, nil}, {:field, 36, {:w, :p}}, {:clock, :white, 5_458_000}]
    end
  end

  describe "the recorded loop, asked again" do
    setup do
      port = "FAKE-loop-#{System.unique_integer([:positive])}"
      start_supervised!({Fake, port: port, device: {RecordedLoop, RecordedLoop.new()}}, id: port)
      {:ok, port: port}
    end

    test "who is there? Both, found with no prior knowledge", %{port: port} do
      {:ok, handle} = Fake.open(port, [])
      assert Loop.discover(Fake, handle) == [@old, @new]

      # The bus-mode byte first; then each board found is told to sit out
      # the next ping, so that a third could be heard.
      written = Fake.written(port)
      assert <<0x4A, 0x87, 0x00, 0x00, 0x07, rest::binary>> = written
      assert :binary.match(rest, Bus.command(:ignore_next_ping, @old)) != :nomatch
      assert :binary.match(rest, Bus.command(:ignore_next_ping, @new)) != :nomatch
    end

    test "the driver reads both boards: who they are, and what stands on them", %{port: port} do
      me = self()

      for address <- [@old, @new] do
        start_supervised!(
          %{
            id: {:driver, address},
            start:
              {DgtBus, :start_link,
               [
                 [
                   owner: me,
                   id: address,
                   port: port,
                   address: address,
                   stranger: fn _, _ -> :ok end
                 ]
               ]}
          },
          id: {:driver, address}
        )
      end

      assert_receive {:driver, @old, :connected}, 2_000
      assert_receive {:driver, @new, :connected}, 2_000
      assert_receive {:driver, @old, {:info, %{firmware: "1.9", serial: "06310"}}}, 2_000
      assert_receive {:driver, @new, {:info, %{firmware: "4.0"} = info}}, 2_000
      refute is_map_key(info, :serial)

      assert_receive {:driver, @old, {:position, old}}, 2_000
      assert_receive {:driver, @new, {:position, new}}, 2_000
      assert Position.placement(old) == @old_reads
      assert Position.placement(new) == @new_reads

      # 06310's first answer to "what changed?" was its whole memory - four
      # games' worth of squares. None of it is a position: the dump is.
      refute_receive {:driver, _address, {:position, _}}, 300
      # No clock was there, and a board that never had one says nothing of it.
      refute_received {:driver, _, {:clock, _}}
      refute_received {:driver, _, {:info, %{clock: false}}}

      {:ok, bus} = DgtBus.ensure(port)

      assert [
               %{address: @old, connected?: true, missed: 0},
               %{address: @new, connected?: true, missed: 0}
             ] =
               DgtBus.stats(bus)

      assert DgtBus.present(bus) == [@old, @new]
    end
  end

  describe "the site, on the real loop (real-loop-15 to 17)" do
    defp recorded(name) do
      Path.join("test/fixtures/captures", name)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end

    test "the port added as one board: both boards are found, and not one single-board command is sent" do
      lines = recorded("real-loop-15-site-added-as-one-board.jsonl")
      sent = for %{"k" => "tx", "h" => hex} <- lines, do: Base.decode16!(hex, case: :lower)

      # The bus-mode byte, pings, "sit out the next ping" - and nothing a
      # single board is asked: on a loop both would answer that at once.
      assert Enum.all?(
               sent,
               &(&1 == <<0x4A>> or match?({_name, _address}, Bus.decode_command(&1)))
             )

      heard =
        for %{"k" => "rx", "h" => hex} <- lines, into: <<>>, do: Base.decode16!(hex, case: :lower)

      {answers, <<>>} = Bus.parse(heard)
      assert answers |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() == [@old, @new]
      assert [] == for(%{"k" => "pos"} = line <- lines, do: line)
    end

    test "four minutes of both boards read as a loop: one position each, never gone" do
      for {name, reads} <- [
            {"real-loop-16-site-06310.jsonl", @old_reads},
            {"real-loop-17-site-12799.jsonl", @new_reads}
          ] do
        lines = recorded(name)
        assert [%{"b" => text}] = for(%{"k" => "pos"} = line <- lines, do: line)
        assert {:ok, board} = Position.from_text(text)
        assert Position.placement(board) == reads
        assert ["connected"] == for(%{"k" => "st", "v" => v} <- lines, do: v)
        assert List.last(lines)["t"] - hd(lines)["t"] > 200_000
      end
    end
  end

  describe "how fast (real-loop-08)" do
    test "340 questions with no pause between them, 340 answers" do
      exchanges =
        for {<<id, _::binary>>, rx} <- RecordedLoop.exchanges("real-loop-08-timing-again.jsonl"),
            id >= 0x80,
            do: Bus.parse(rx)

      assert length(exchanges) == 340
      assert Enum.all?(exchanges, &match?({[{address, _}], <<>>} when is_integer(address), &1))
    end
  end
end

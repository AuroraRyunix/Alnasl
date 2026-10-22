defmodule Alnasl.RealBoardTest do
  @moduledoc """
  What a real DGT board sent, fed back in as it came.

  The fixtures (`test/fixtures/captures/real-06310-*.jsonl`) are cut from the
  recordings of 2026-10-12: board 06310, firmware 1.9, a DGT clock on its
  clock socket, one black knight on the board. They hold the bytes as the
  serial port delivered them - messages in pieces and all - and
  `docs/real-board-2026-10-12.md` says what was done to the board and the
  clock while they were written.

  Each is pushed through the real serial driver over a stand-in line that
  never answers (`Arkab.Transport.Fake`), and the driver's events are what
  is asserted. Nothing here was written by hand from a protocol description;
  where the driver once decoded these bytes differently, the capture won.
  """

  use ExUnit.Case, async: true

  alias Alnasl.{Clock, Position, Recorder, Session}
  alias Arkab.Driver.DgtSerial
  alias Arkab.Transport.Fake

  @dir "test/fixtures/captures"

  # The rx lines of a fixture, as binaries, in order.
  defp rx(name) do
    Path.join(@dir, name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["k"] == "rx"))
    |> Enum.map(&Base.decode16!(&1["h"], case: :lower))
  end

  defp tx(name) do
    Path.join(@dir, name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["k"] == "tx"))
    |> Enum.map_join(&Base.decode16!(&1["h"], case: :lower))
  end

  # Plays a fixture into the driver, read by read, and returns what the
  # driver told its owner (the raw bytes and the poll counts left out).
  defp drive(name) do
    port = "FAKE-real-#{System.unique_integer([:positive])}"
    start_supervised!({Fake, port: port}, id: port)

    driver =
      start_supervised!(
        %{
          id: {:driver, port},
          start:
            {DgtSerial, :start_link, [[owner: self(), id: 0, port: port, resync_ms: 600_000]]}
        },
        id: {:driver, port}
      )

    # The driver has opened the line, asked who is on it (nobody answers a
    # ping here: the recordings are of a single board) and said its piece
    # before the board speaks.
    written = handshake(port)

    for bytes <- rx(name), do: Fake.push(port, bytes)
    _ = :sys.get_state(driver)

    {collect([]), written}
  end

  # What the driver writes before it listens, as Arkab's contract pins it
  # (`dgt-serial-opening` in the vendored bridge-protocol-v1): the probe -
  # bus mode, a ping to everybody twice, "end bus mode" - then the
  # handshake, which is what is returned, then the questions it asks
  # straight after (the clock's, since Arkab 0.3.6). Split by the contract's
  # three parts and not by a length written here, so the next Arkab that
  # says something else first is contract drift, not a mystery.
  @opening Alnasl.Contract.example(:bridge, "dgt-serial-opening")

  defp handshake(port) do
    [probe, said, asks] =
      for part <- ~w(probe_hex handshake_hex asks_hex),
          do: Base.decode16!(@opening[part], case: :lower)

    assert Base.decode16!(@opening["bytes_hex"], case: :lower) == probe <> said <> asks
    # The driver is started with its clock option as it comes, as the example's is.
    assert @opening["clock"] == true

    written = opening(port, byte_size(probe <> said <> asks))
    assert binary_part(written, 0, byte_size(probe)) == probe
    assert binary_part(written, byte_size(probe) + byte_size(said), byte_size(asks)) == asks
    assert binary_part(written, byte_size(probe), byte_size(said)) == said
    said
  end

  defp opening(port, size) do
    case Fake.written(port) do
      written when byte_size(written) >= size -> written
      _not_yet -> opening(port, size)
    end
  end

  defp collect(acc) do
    receive do
      {:driver, 0, {:raw, _direction, _bytes}} -> collect(acc)
      {:driver, 0, {:poll, _}} -> collect(acc)
      {:driver, 0, event} -> collect([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp clocks(events), do: for({:clock, reading} <- events, do: reading)
  defp placements(events), do: for({:position, board} <- events, do: Position.placement(board))
  defp ms(h, m, s), do: ((h * 60 + m) * 60 + s) * 1000

  # Runs of the same value become one.
  defp runs(list), do: Enum.dedup(list)

  describe "the handshake (single-1)" do
    test "serial number, firmware, and a dump with one black knight on d6" do
      {events, written} = drive("real-06310-handshake.jsonl")

      # What the driver says first is, byte for byte, what was sent that day.
      assert written == tx("real-06310-handshake.jsonl")
      assert written == <<0x40, 0x45, 0x4D, 0x42, 0x4B>>

      assert [
               # Nobody answered the ping: one board at most, and not a loop.
               {:info, %{loop: nil, bus_address: nil}},
               :connected,
               {:info, %{serial: "06310"}},
               {:info, %{firmware: "1.9"}},
               {:position, board}
             ] = events

      # The user looked: one black knight, on d6. Byte 19 of the dump is 0x09.
      assert Position.placement(board) == "8/8/3n4/8/8/8/8/8"
      assert elem(board, 19) == {:b, :n}
      assert Position.square_name(19) == "d6"
    end

    test "the serial number arrives in two reads and the dump in five" do
      reads = rx("real-06310-handshake.jsonl")
      assert length(reads) == 6
      assert hd(reads) == <<0x91, 0x00, 0x08, "0">>
    end
  end

  describe "the clock (clock-1)" do
    test "attached: it announces itself, stands still at 1:30:30 set for White, then White's time runs" do
      {events, _written} = drive("real-06310-clock-attached.jsonl")

      assert {:info, %{serial: "06310"}} in events
      assert placements(events) == ["8/8/3n4/8/8/8/8/8"]

      # The first clock message (0A 10 01 2A 00 00 00) is the clock about
      # itself, not a time: the first reading is the second message.
      [first | rest] = clocks(events)

      assert first == %{
               white_ms: ms(1, 30, 30),
               black_ms: ms(1, 30, 30),
               running: :none,
               armed: :white
             }

      assert rest != []
      assert Enum.all?(rest, &(&1.running == :white and &1.armed == :white))
      assert Enum.all?(rest, &(&1.black_ms == ms(1, 30, 30)))

      # About one message a second, each a second less on White's side.
      assert Enum.map(rest, & &1.white_ms) ==
               Enum.map(0..(length(rest) - 1), &(ms(1, 30, 30) - &1 * 1000))

      refute Enum.any?(events, &match?({:info, %{clock: false}}, &1))
    end

    test "a press of the lever: the other side runs, and the side that pressed gets its 30 seconds" do
      {events, _written} = drive("real-06310-clock-press.jsonl")
      readings = clocks(events)

      assert runs(Enum.map(readings, & &1.running)) == [:white, :black, :white]

      # White pressed at 1:29:25 and stands at 1:29:54 while Black's time runs.
      before = readings |> Enum.take_while(&(&1.running == :white)) |> List.last()
      assert before.white_ms == ms(1, 29, 25)
      black_runs = readings |> Enum.drop_while(&(&1.running == :white))

      assert hd(black_runs) == %{
               white_ms: ms(1, 29, 54),
               black_ms: ms(1, 30, 30),
               running: :black,
               armed: :black
             }

      # Black pressed at 1:30:25 and stands at 1:30:55.
      back = Enum.drop_while(black_runs, &(&1.running == :black))

      assert List.last(Enum.take_while(black_runs, &(&1.running == :black))).black_ms ==
               ms(1, 30, 25)

      assert hd(back) == %{
               white_ms: ms(1, 29, 54),
               black_ms: ms(1, 30, 55),
               running: :white,
               armed: :white
             }

      # The clock module counts two presses.
      {clock, presses} =
        Enum.reduce(readings, {Clock.new(), 0}, fn reading, {clock, n} ->
          {clock, pressed?} = Clock.update(clock, 0, reading)
          {clock, n + if(pressed?, do: 1, else: 0)}
        end)

      assert presses == 2 and clock.presses == 2
    end

    test "paused and resumed: nobody runs, and a lever tipped by hand changes what the clock is set for" do
      {events, _written} = drive("real-06310-clock-pause.jsonl")
      readings = clocks(events)

      assert runs(Enum.map(readings, &{&1.running, &1.armed})) == [
               {:white, :white},
               {:none, :white},
               {:white, :white},
               {:none, :white},
               # 0x12: paused on White's move, the lever now up on Black's side
               {:none, :black},
               {:none, :white},
               {:none, :black}
             ]

      # A pause is not a press, and the times stand still through it.
      {_clock, presses} =
        Enum.reduce(readings, {Clock.new(), 0}, fn reading, {clock, n} ->
          {clock, pressed?} = Clock.update(clock, 0, reading)
          {clock, n + if(pressed?, do: 1, else: 0)}
        end)

      assert presses == 0

      assert readings
             |> Enum.filter(&(&1.running == :none))
             |> Enum.map(& &1.black_ms)
             |> Enum.uniq() == [ms(1, 31, 19)]
    end

    test "switched off and on again, turned round: \"no clock\" once, then Black's side first" do
      {events, _written} = drive("real-06310-clock-off-on.jsonl")

      clock_events =
        Enum.filter(events, &(match?({:clock, _}, &1) or match?({:info, %{clock: _}}, &1)))

      # 01 31 19 71 3F 7F 30: status bit 5, and nonsense where White's time was.
      assert [{:info, %{clock: false}} | back] = clock_events

      refute Enum.any?(back, &match?({:info, _}, &1))

      # Back on, reset to 1:30:30, the lever on Black's side; then it is
      # started and it is Black's time that runs. The driver says "black",
      # and is right: it is the clock that stands wrong.
      readings = clocks(back)

      assert hd(readings) == %{
               white_ms: ms(1, 30, 30),
               black_ms: ms(1, 30, 30),
               running: :none,
               armed: :black
             }

      assert runs(Enum.map(readings, & &1.running)) == [:none, :black]
      assert Enum.all?(readings, &(&1.white_ms == ms(1, 30, 30)))
      assert List.last(readings).black_ms < ms(1, 30, 30)
    end

    test "the clock's part of the starting-position check, from those bytes" do
      check = fn name ->
        {events, _written} = drive(name)

        Enum.reduce(events, Clock.new(), fn
          {:clock, reading}, clock -> elem(Clock.update(clock, 0, reading), 0)
          {:info, %{clock: false}}, clock -> Clock.off(clock, 0)
          _other, clock -> clock
        end)
        |> Clock.start_check()
      end

      # No clock message at all: nothing to check.
      assert check.("real-06310-handshake.jsonl") == nil
      # Running on White's side: right.
      assert check.("real-06310-clock-attached.jsonl") == :ok
      # Paused with the lever tipped to Black's side.
      assert check.("real-06310-clock-pause.jsonl") == {:wrong, :black}
      # Turned round and started.
      assert check.("real-06310-clock-off-on.jsonl") == {:wrong, :black}
    end
  end

  describe "the pieces (clock-1)" do
    test "a knight lifted and put down: every field update is a whole new picture" do
      {events, _written} = drive("real-06310-knight-moves.jsonl")

      assert placements(events) == [
               "8/8/3n4/8/8/8/8/8",
               # lifted from d6
               "8/8/8/8/8/8/8/8",
               "8/8/8/8/4n3/8/8/8",
               # e4 to d4 within 32 ms: off one square, on the next
               "8/8/8/8/8/8/8/8",
               "8/8/8/8/3n4/8/8/8",
               "8/8/8/8/8/8/8/8",
               "8/8/8/8/8/8/2n5/8",
               "8/8/8/8/8/8/8/8",
               "8/8/8/8/8/8/3n4/8"
             ]

      # The clock went on being pressed meanwhile, and its messages arrive
      # between the field updates without disturbing them.
      assert runs(Enum.map(clocks(events), & &1.running)) == [:white, :black, :white, :none]
    end
  end

  describe "the whole recording, as a dry run" do
    @session Path.join(@dir, "real-06310-clock-session.jsonl")

    test "is decoded from its bytes: no moves, no alarm about the pieces, four presses, one switch-off" do
      assert {:ok, report} = Recorder.dry_run(@session, [])

      assert report.raw?
      assert_in_delta report.duration_ms, 246_700, 1_000

      # One knight is not a game: the tracker waits for a starting position
      # and makes no move of the knight's wanderings.
      assert report.moves == []
      assert report.status == :waiting_start and report.detail == :not_start
      assert report.alarms == [] and report.corrections == [] and report.suggestions == []

      assert report.presses == 4
      assert [off] = report.clock_off
      assert_in_delta off, 99_950, 500

      # The clock was turned round and started on Black's side, and ran
      # there to the end. Not an alarm - there was no starting position to
      # start a game from - but the check says it.
      assert report.clock_alarms == []
      assert report.clock_check == {:wrong, :black}
    end

    test "the same clock, with the pieces set up: the alarm, the moment Black's time starts running" do
      {:ok, capture} = Recorder.read(@session)

      # The recording's clock, over a board in the starting position.
      events =
        [{0, {:position, Position.start()}}] ++
          Enum.reject(capture.events, &match?({_t, {:position, _}}, &1))

      {session, out} = Session.run(Session.new([]), events, tail_ms: 1_000)

      # White's side ran first, as it should: no alarm for the first part.
      # The lever pressed back and forth over untouched pieces is not a
      # clock alarm either - it is moves the board did not see, and the
      # second press says so.
      assert [
               {press, {:warning, :move_missing, 2, 0}},
               {_back_on, {:warning, :move_missing, 4, 0}}
             ] =
               Enum.filter(out, &match?({_t, {:warning, :move_missing, _, _}}, &1))

      assert_in_delta press, 80_700, 500

      # After the switch-off the clock comes back the wrong way; while it
      # stands still that is the check's business, and the alarm is raised
      # the moment it is started.
      assert [{at, {:warning, :clock_side, :black}}] =
               Enum.filter(out, &match?({_t, {:warning, :clock_side, _}}, &1))

      assert_in_delta at, 103_250, 500
      refute Enum.any?(out, &match?({_t, {:warning_cleared, :clock_side}}, &1))
      assert session.clock_alarm == :black
      assert Session.clock_check(session) == {:wrong, :black}

      assert session.tracker.plies == []
    end
  end
end

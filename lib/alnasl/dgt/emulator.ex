defmodule Alnasl.Dgt.Emulator do
  @moduledoc """
  A DGT board in software - or several on one line. It answers the commands
  of `Alnasl.Dgt.Protocol` and the bus commands of `Alnasl.Dgt.Bus` the way
  the real boards of 2026-10-12 did (`docs/real-board-2026-10-12.md`,
  `docs/real-loop-2026-10-12.md`):

  - a board answers bus commands whether or not it was told to go to bus
    mode, and single-board commands whether or not it is in it;
  - so on a loop every board answers a single-board command at once, and
    what arrives is neither answer (`collide/1`);
  - a board with firmware 1.x swallows the first bus command after a
    single-board command or after "end bus mode"; a newer one does not;
  - a ping to address 0 is answered by everybody who was not told to sit it
    out (here: one after the other - a real loop has them collide now and
    then);
  - "what changed?" gives what the board wrote down since the last time it
    was asked: the first time, everything since it was switched on;
  - a board without a clock answers the clock question with "no clock".

  What no real loop has shown yet it does the way `Alnasl.Dgt.Bus` assumes:
  a move is in the next answer to "what changed?", a clock's lever going
  over writes the time down, and a board in bus mode sends nothing unasked.

  Used as the device of an `Alnasl.Transport.Fake` port:
  `{Alnasl.Dgt.Emulator, Alnasl.Dgt.Emulator.new()}`. A loop of several
  boards is a list of emulators (`loop/1`).
  """

  import Bitwise

  alias Alnasl.Dgt.{Bus, Protocol}
  alias Alnasl.Position

  defstruct board: nil,
            clock: nil,
            mode: :idle,
            serial: "12345",
            version: "1.8",
            address: nil,
            bus?: false,
            # Firmware 1.x after a single-board command: the next bus
            # command only switches it over.
            deaf?: false,
            sit_out?: false,
            # What "what changed?" will answer, and what it answered last.
            journal: <<>>,
            sent: <<>>

  @doc """
  A board. Its address is its serial number as a number unless `:address`
  says otherwise, and its memory begins with being switched on and finding
  the pieces that stand on it.
  """
  def new(opts \\ []) do
    emu = struct!(%__MODULE__{board: Position.start()}, opts)

    address =
      emu.address ||
        case Integer.parse(emu.serial) do
          {n, ""} when n > 0 and n < 16_384 -> n
          _other -> 1
        end

    %{emu | address: address, journal: <<0x6A>> <> scan(Position.empty(), emu.board)}
  end

  @doc "Several boards on one loop, at the given addresses."
  def loop(addresses),
    do: Enum.map(addresses, &new(address: &1, bus?: true, serial: Bus.number(&1)))

  # --- the device callback -----------------------------------------------------

  @doc "What the board (or the loop) answers to `bytes`."
  def handle(%__MODULE__{} = emu, bytes) do
    {reply, [emu]} = handle([emu], bytes)
    {reply, emu}
  end

  def handle(emulators, bytes) when is_list(emulators) do
    Enum.reduce(tokens(bytes), {<<>>, emulators}, fn token, {reply, emulators} ->
      {answers, emulators} =
        emulators |> Enum.map(&one(&1, token)) |> Enum.unzip()

      said = Enum.reject(answers, &(&1 == <<>>))

      more =
        case {token, said} do
          {{:single, _byte}, [_, _ | _]} -> collide(said)
          _other -> IO.iodata_to_binary(said)
        end

      {reply <> more, emulators}
    end)
  end

  # A byte with bit 7 set begins a four-byte bus command; any other byte is
  # a single-board command.
  defp tokens(<<id, hi, lo, sum, rest::binary>>) when id >= 0x80,
    do: [{:bus, <<id, hi, lo, sum>>} | tokens(rest)]

  defp tokens(<<id, _::binary>>) when id >= 0x80, do: []
  defp tokens(<<byte, rest::binary>>), do: [{:single, byte} | tokens(rest)]
  defp tokens(<<>>), do: []

  @doc """
  Two or more boards speaking at once: the bytes of the first, each mixed
  with whatever the others had on the line at that moment. Not an answer of
  either, and now and then it looks like one - which is how a loop read as
  one board came to look like a board with a bad cable.
  """
  def collide([first | others]) do
    for {byte, i} <- Enum.with_index(:binary.bin_to_list(first)), into: <<>> do
      other = Enum.reduce(others, 0, &(&2 ||| :binary.at(&1, rem(i + 1, byte_size(&1))) <<< 1))
      <<bxor(byte, other) &&& 0xFF>>
    end
  end

  defp one(emu, {:single, byte}), do: command(emu, byte)

  defp one(emu, {:bus, frame}) do
    case Bus.decode_command(frame) do
      {name, address}
      when address == emu.address or (address == 0 and name in [:ping, :end_busmode]) ->
        if emu.deaf?,
          do: {<<>>, %{emu | deaf?: false, bus?: true}},
          else: bus_answer(%{emu | bus?: true}, name, address == 0)

      _other ->
        {<<>>, emu}
    end
  end

  defp command(emu, byte) do
    commands = Protocol.commands()
    to_bus = :binary.first(Bus.to_busmode())

    {reply, emu} =
      cond do
        byte == commands.reset -> {<<>>, %{emu | mode: :idle}}
        byte == commands.board -> {Protocol.encode({:board, emu.board}), emu}
        byte == commands.clock -> {clock_bytes(emu), emu}
        byte == commands.update -> {<<>>, %{emu | mode: :update}}
        byte == commands.update_board -> {<<>>, %{emu | mode: :update_board}}
        byte == commands.update_nice -> {<<>>, %{emu | mode: :update}}
        byte == commands.serial -> {Protocol.encode({:serial, emu.serial}), emu}
        byte == commands.version -> {Protocol.encode({:version, emu.version}), emu}
        byte == commands.bus_address -> {Protocol.encode({:bus_address, emu.address}), emu}
        byte == commands.trademark -> {Protocol.encode({:trademark, "Alnasl emulator"}), emu}
        true -> {<<>>, emu}
      end

    cond do
      byte == to_bus -> {<<>>, %{emu | bus?: true, deaf?: false}}
      byte in Map.values(commands) -> {reply, %{emu | bus?: false, deaf?: old?(emu)}}
      true -> {reply, emu}
    end
  end

  defp old?(%{version: "1." <> _}), do: true
  defp old?(_emu), do: false

  defp bus_answer(emu, :board, _all?) do
    data = for i <- 0..63, into: <<>>, do: <<Protocol.code(elem(emu.board, i))>>
    {Bus.answer(:board, emu.address, data), emu}
  end

  defp bus_answer(emu, :clock, _all?) do
    data =
      case clock_bytes(emu) do
        <<_header::binary-size(3), data::binary>> -> data
        # No clock on the socket: the "no clock" bit, as both real boards said.
        <<>> -> <<0, 0, 0, 0, 0, 0, 0x20>>
      end

    {Bus.answer(:clock, emu.address, data), emu}
  end

  defp bus_answer(emu, :version, _all?) do
    [major, minor] = emu.version |> String.split(".") |> Enum.map(&String.to_integer/1)
    {Bus.answer(:version, emu.address, <<major, minor>>), emu}
  end

  defp bus_answer(%{sit_out?: true} = emu, :ping, true), do: {<<>>, %{emu | sit_out?: false}}
  defp bus_answer(emu, :ping, _all?), do: {Bus.answer(:ping, emu.address, <<>>), emu}

  defp bus_answer(emu, :ignore_next_ping, _all?),
    do: {Bus.answer(:ping, emu.address, <<>>), %{emu | sit_out?: true}}

  defp bus_answer(emu, :changes, _all?),
    do:
      {Bus.answer(:changes, emu.address, emu.journal), %{emu | journal: <<>>, sent: emu.journal}}

  # ASSUMED: after an empty answer the real boards repeated an empty one;
  # a non-empty one was never there to repeat.
  defp bus_answer(emu, :repeat_changes, _all?),
    do: {Bus.answer(:changes, emu.address, emu.sent), emu}

  defp bus_answer(emu, :from_start, _all?),
    do: {Bus.answer(:from_start, emu.address, <<0x7B>> <> scan(Position.empty(), emu.board)), emu}

  defp bus_answer(emu, :end_busmode, _all?), do: {<<>>, %{emu | bus?: false, deaf?: old?(emu)}}

  defp clock_bytes(%{clock: nil}), do: <<>>

  defp clock_bytes(%{clock: clock}) do
    # As the real clock does it (capture 2026-10-12): a side is always
    # named, running or not, and the lever is up on that side.
    side = if clock.running == :none, do: clock[:armed] || :white, else: clock.running

    Protocol.encode(
      {:clock,
       %{
         white_ms: clock.white_ms,
         black_ms: clock.black_ms,
         running?: clock.running != :none,
         turn: side,
         lever: side,
         connected?: Map.get(clock, :connected?, true)
       }}
    )
  end

  # The squares on which `to` differs from `from`, as the board writes them down.
  defp scan(from, to) do
    for square <- Position.diff(from, to), into: <<>> do
      Bus.field_event(square, elem(to, square))
    end
  end

  # --- moving pieces -----------------------------------------------------------

  @doc """
  The pieces now stand as `board`. Returns what the board says unasked - a
  field update per changed square when it is in update mode and not on a
  bus, nothing otherwise - and the emulator, which has written the change
  down for whoever asks what changed.
  """
  def set_board(%__MODULE__{} = emu, board) do
    bytes =
      if emu.mode in [:update, :update_board] and not emu.bus? do
        for square <- Position.diff(emu.board, board), into: <<>> do
          Protocol.encode({:field, square, elem(board, square)})
        end
      else
        <<>>
      end

    {bytes, %{emu | board: board, journal: emu.journal <> scan(emu.board, board)}}
  end

  @doc """
  The clock now reads `reading`. A clock message is sent in full update mode;
  a lever that went over is written down with the time of the side it
  stopped.
  """
  def set_clock(%__MODULE__{} = emu, reading) do
    pressed? = emu.clock != nil and emu.clock.running != reading.running

    journal =
      if pressed? do
        emu.journal <>
          Bus.clock_event(:white, reading.white_ms) <> Bus.clock_event(:black, reading.black_ms)
      else
        emu.journal
      end

    emu = %{emu | clock: reading, journal: journal}
    {if(emu.mode == :update and not emu.bus?, do: clock_bytes(emu), else: <<>>), emu}
  end

  @doc "The same for one board of a loop."
  def set_board(emulators, address, board) when is_list(emulators),
    do: on(emulators, address, &set_board(&1, board))

  def set_clock(emulators, address, reading) when is_list(emulators),
    do: on(emulators, address, &set_clock(&1, reading))

  defp on(emulators, address, fun) do
    {<<>>,
     Enum.map(emulators, fn emu ->
       if emu.address == address, do: fun.(emu) |> elem(1), else: emu
     end)}
  end
end

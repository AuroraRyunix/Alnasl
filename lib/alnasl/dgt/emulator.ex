defmodule Alnasl.Dgt.Emulator do
  @moduledoc """
  A DGT board in software: it answers the commands of `Alnasl.Dgt.Protocol`
  the way the published description says a board does, and - once switched
  to bus mode - the bus commands of `Alnasl.Dgt.Bus` the way that module
  ASSUMES one does.

  It exists to exercise the real drivers byte for byte without a board. It
  proves that driver and protocol module agree with each other; it proves
  nothing about real hardware, since both were written from the same reading
  of the same description.

  Used as the device of an `Alnasl.Transport.Fake` port:
  `{Alnasl.Dgt.Emulator, Alnasl.Dgt.Emulator.new()}`. A loop of several
  boards is a list of emulators (`loop/1`).
  """

  alias Alnasl.Dgt.{Bus, Protocol}
  alias Alnasl.Position

  defstruct board: nil,
            clock: nil,
            mode: :idle,
            serial: "12345",
            version: "1.8",
            address: 1,
            bus?: false

  def new(opts \\ []), do: struct!(%__MODULE__{board: Position.start()}, opts)

  @doc "Several boards on one loop, already in bus mode, at the given addresses."
  def loop(addresses), do: Enum.map(addresses, &new(address: &1, bus?: true, serial: "B#{&1}"))

  # --- the device callback -----------------------------------------------------

  @doc "What the board (or the loop) answers to `bytes`."
  def handle(emulators, bytes) when is_list(emulators) do
    # A loop: each 4-byte frame is for one address; the others stay silent.
    for <<frame::binary-size(4) <- bytes>>, reduce: {<<>>, emulators} do
      {reply, emulators} ->
        case Bus.decode_command(frame) do
          {name, address} ->
            {answers, emulators} =
              Enum.map_reduce(emulators, emulators, fn emu, all ->
                if emu.address == address or address == 0 do
                  {bus_answer(emu, name), all}
                else
                  {<<>>, all}
                end
              end)

            {reply <> IO.iodata_to_binary(answers), emulators}

          :error ->
            {reply, emulators}
        end
    end
  end

  def handle(%__MODULE__{bus?: true} = emu, bytes) do
    {reply, [emu]} = handle([emu], bytes)
    {reply, emu}
  end

  def handle(%__MODULE__{} = emu, bytes) do
    for <<byte <- bytes>>, reduce: {<<>>, emu} do
      {reply, emu} ->
        {more, emu} = command(emu, byte)
        {reply <> more, emu}
    end
  end

  defp command(emu, byte) do
    commands = Protocol.commands()
    to_bus = :binary.first(Bus.to_busmode())

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
      byte == to_bus -> {<<>>, %{emu | bus?: true}}
      true -> {<<>>, emu}
    end
  end

  defp bus_answer(emu, :board) do
    data = for i <- 0..63, into: <<>>, do: piece_byte(elem(emu.board, i))
    Bus.answer(:board, emu.address, data)
  end

  defp bus_answer(emu, :clock) do
    case clock_bytes(emu) do
      <<_header::binary-size(3), data::binary>> -> Bus.answer(:clock, emu.address, data)
      <<>> -> <<>>
    end
  end

  defp bus_answer(emu, :version), do: Bus.answer(:version, emu.address, <<1, 8>>)
  defp bus_answer(emu, :ping), do: Bus.answer(:ping, emu.address, <<>>)
  defp bus_answer(_emu, _other), do: <<>>

  defp piece_byte(piece) do
    <<_header::binary-size(3), _square, code>> = Protocol.encode({:field, 0, piece})
    <<code>>
  end

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

  # --- moving pieces -----------------------------------------------------------

  @doc """
  The pieces now stand as `board`. Returns what the board says unasked - a
  field update per changed square when it is in update mode, nothing
  otherwise - and the emulator.
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

    {bytes, %{emu | board: board}}
  end

  @doc "The clock now reads `reading`. A clock message is sent in full update mode."
  def set_clock(%__MODULE__{} = emu, reading) do
    emu = %{emu | clock: reading}
    {if(emu.mode == :update and not emu.bus?, do: clock_bytes(emu), else: <<>>), emu}
  end

  @doc "The same for one board of a loop."
  def set_board(emulators, address, board) when is_list(emulators) do
    {<<>>, Enum.map(emulators, &if(&1.address == address, do: %{&1 | board: board}, else: &1))}
  end
end

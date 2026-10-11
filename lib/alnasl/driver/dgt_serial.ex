defmodule Alnasl.Driver.DgtSerial do
  @moduledoc """
  One DGT board on its own serial port, speaking the published protocol
  (`Alnasl.Dgt.Protocol`).

  ## What it does

  1. opens the port (9600 8N1) and sends: reset, "your serial number",
     "your version", "the whole board", and then "tell me every change"
     (update mode, with the clock when one is attached);
  2. keeps a picture of the board: the dump, then each field update applied
     to it - and reports the WHOLE picture to its owner on every change;
  3. every `resync_ms` (3 s) asks for the whole board again. That heals a
     field update lost on the line, and it is the heartbeat: a board that
     has said nothing for `timeout_ms` (10 s) is reported disconnected, the
     port is closed, and opening is retried every `retry_ms` (3 s) until the
     board is back.

  It never sleeps and never blocks: everything is a message.

  ## Options

  `:port` (required), `:owner`, `:id`; in `:options` (string keys, the
  board's JSON): `"clock"` - `false` to not ask for clock updates.
  `:transport` picks the line (default: by port name - a name starting with
  `FAKE` is a stand-in). `:debug` logs every byte in hex.

  There is no option for which side of the clock is White's, on purpose: the
  clock stands to the right of the board, and a clock that is turned round
  is reported as set up wrongly (`Alnasl.Dgt.Protocol.reading/1`,
  `Alnasl.Clock.start_check/2`).

  ## The clock

  A reading goes out as `{:clock, reading}`. A clock that is switched off or
  unplugged (the board says "no clock") goes out as `{:info, %{clock:
  false}}`, once, and its last reading must not be believed after that. A
  board that never had a clock says nothing about clocks at all.

  It met a real board on 2026-10-12 (serial 06310, firmware 1.9): the
  handshake, the dump, field updates and the clock are as written here. See
  `docs/real-board-2026-10-12.md`.
  """

  use GenServer

  @behaviour Alnasl.Driver

  require Logger

  alias Alnasl.{Driver, Transport}
  alias Alnasl.Dgt.Protocol

  @impl Alnasl.Driver
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    options = Keyword.get(opts, :options, %{})
    port = Keyword.fetch!(opts, :port)

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      id: Keyword.fetch!(opts, :id),
      port: port,
      transport: Keyword.get(opts, :transport) || Transport.for_port(port),
      handle: nil,
      buffer: <<>>,
      board: nil,
      connected?: false,
      last_rx: nil,
      clock?: options["clock"] != false,
      clock_seen?: nil,
      debug?: Keyword.get(opts, :debug, false) or options["debug"] == true,
      resync_ms: Keyword.get(opts, :resync_ms, 3_000),
      timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
      retry_ms: Keyword.get(opts, :retry_ms, 3_000)
    }

    send(self(), :open)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:open, %{handle: nil} = state) do
    case state.transport.open(state.port, baud: Protocol.baud()) do
      {:ok, handle} ->
        state = %{state | handle: handle, buffer: <<>>, board: nil, last_rx: now()}

        state =
          state
          |> write(:reset)
          |> write(:serial)
          |> write(:version)
          |> write(:board)
          |> write(if(state.clock?, do: :update_nice, else: :update_board))

        Process.send_after(self(), :resync, state.resync_ms)
        {:noreply, state}

      {:error, reason} ->
        if state.debug?, do: Logger.info("dgt #{state.port}: cannot open: #{inspect(reason)}")
        Driver.emit(state.owner, state.id, {:info, %{error: inspect(reason)}})
        Process.send_after(self(), :open, state.retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:open, state), do: {:noreply, state}

  def handle_info(:resync, %{handle: nil} = state), do: {:noreply, state}

  def handle_info(:resync, state) do
    if now() - state.last_rx > state.timeout_ms do
      {:noreply, drop(state, :timeout)}
    else
      Process.send_after(self(), :resync, state.resync_ms)
      {:noreply, write(state, :board)}
    end
  end

  def handle_info(message, state) do
    case state.transport.message(message) do
      {:data, bytes} -> {:noreply, received(state, bytes)}
      {:error, reason} -> {:noreply, drop(state, reason)}
      nil -> {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{handle: handle, transport: transport}) when handle != nil do
    transport.close(handle)
  end

  def terminate(_reason, _state), do: :ok

  # --- bytes in ----------------------------------------------------------------

  defp received(state, bytes) do
    if state.debug?, do: Logger.info("dgt #{state.port} rx #{Base.encode16(bytes, case: :lower)}")
    Driver.emit(state.owner, state.id, {:raw, :rx, bytes})

    {messages, rest} = Protocol.parse(state.buffer <> bytes)
    state = %{state | buffer: rest, last_rx: now()}

    state =
      if messages != [] and not state.connected? do
        Driver.emit(state.owner, state.id, :connected)
        %{state | connected?: true}
      else
        state
      end

    Enum.reduce(messages, state, &message/2)
  end

  defp message({:board, squares}, state) do
    Driver.emit(state.owner, state.id, {:poll, :ok})
    position(state, squares)
  end

  # A change to a board we have not seen whole: ask for the whole of it.
  defp message({:field, _square, _piece}, %{board: nil} = state), do: write(state, :board)

  defp message({:field, square, piece}, state),
    do: position(state, put_elem(state.board, square, piece))

  defp message({:clock, clock}, state) do
    case Protocol.reading(clock) do
      nil ->
        if state.clock_seen? != false,
          do: Driver.emit(state.owner, state.id, {:info, %{clock: false}})

        %{state | clock_seen?: false}

      reading ->
        Driver.emit(state.owner, state.id, {:clock, reading})

        if clock.battery_low?,
          do: Driver.emit(state.owner, state.id, {:info, %{clock_battery_low: true}})

        %{state | clock_seen?: true}
    end
  end

  defp message(other, state) do
    case Protocol.apply_message(other, state.board) do
      {:info, info} -> Driver.emit(state.owner, state.id, {:info, info})
      _ignored -> :ok
    end

    state
  end

  defp position(%{board: board} = state, board), do: state

  defp position(state, board) do
    Driver.emit(state.owner, state.id, {:position, board})
    %{state | board: board}
  end

  # --- bytes out ---------------------------------------------------------------

  defp write(%{handle: nil} = state, _command), do: state

  defp write(state, command) do
    bytes = Protocol.command(command)

    if state.debug?,
      do: Logger.info("dgt #{state.port} tx #{Base.encode16(bytes, case: :lower)} (#{command})")

    Driver.emit(state.owner, state.id, {:raw, :tx, bytes})

    case state.transport.write(state.handle, bytes) do
      :ok -> state
      {:error, reason} -> drop(state, reason)
    end
  end

  # The line is gone: say so, close, and try again later.
  defp drop(%{handle: nil} = state, _reason), do: state

  defp drop(state, reason) do
    if state.debug?, do: Logger.info("dgt #{state.port}: lost (#{inspect(reason)})")
    state.transport.close(state.handle)
    if state.connected?, do: Driver.emit(state.owner, state.id, :disconnected)
    Driver.emit(state.owner, state.id, {:poll, :missed})
    Process.send_after(self(), :open, state.retry_ms)
    %{state | handle: nil, connected?: false, board: nil, buffer: <<>>}
  end

  defp now, do: System.monotonic_time(:millisecond)
end

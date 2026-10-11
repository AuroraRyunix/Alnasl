defmodule Alnasl.Driver.DgtBus do
  @moduledoc """
  A loop of DGT boards on one serial port: each board has an address, and
  each speaks only when asked.

  # The wire format is NOT verified.

  What is solid here is the part that does not depend on it: **the polling
  scheduler** and **the per-address board model**. The bytes themselves come
  from `Alnasl.Dgt.Bus`, where every one of them is marked `ASSUMED`. Against
  the emulator this driver works end to end; against a real loop it has
  never run. `docs/tomorrow.md` is how that changes.

  ## How it is built

  One process per serial port (the bus), started on demand and found by the
  port's name. A board is `attach/4`ed to it with its address and its owner;
  the bus then sends that owner the same `{:driver, id, event}` messages any
  driver sends, so nothing above knows a board is on a loop.

  ## The scheduler

  The addresses are asked in turn, one question at a time:

  - the question is "send your whole board". (Asking for changes only would
    be quicker and is what DGT's own software is believed to do; a full dump
    cannot be misread, so that is where this starts.) Every `clock_every`-th
    round the clock is asked for as well;
  - the answer has `reply_ms` (250 ms) to arrive. An answer from another
    address, or one with a bad checksum, counts as none;
  - no answer is a **missed poll**, reported as such. After `lost_after` (8)
    in a row the board is reported disconnected - and it stays in the
    rotation, so it is back the moment it answers;
  - an answered poll is followed by the next address after `gap_ms` (20 ms),
    so 12 boards are each read about three times a second at 9600 baud
    (a dump is 73 bytes, some 76 ms on the wire).

  ## As a driver

  `start_link/1` (the `Alnasl.Driver` callback) is what a board's process
  calls: it makes sure the bus for `:port` runs and attaches `:address` to
  it. The process it returns is a small one that stands for that attachment
  and detaches when it stops.
  """

  use GenServer

  @behaviour Alnasl.Driver

  require Logger

  alias Alnasl.{Driver, Transport}
  alias Alnasl.Dgt.{Bus, Protocol}

  # --- a board on the bus ------------------------------------------------------

  @impl Alnasl.Driver
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    address = Keyword.fetch!(opts, :address)
    owner = Keyword.fetch!(opts, :owner)
    id = Keyword.fetch!(opts, :id)

    Agent.start_link(fn ->
      {:ok, bus} =
        ensure(port, Keyword.take(opts, [:transport, :debug, :reply_ms, :gap_ms, :lost_after]))

      attach(bus, address, owner, id)
      {bus, address}
    end)
  end

  @doc "The bus process for `port`, started if need be."
  def ensure(port, opts \\ []) do
    case Registry.lookup(Alnasl.BusRegistry, port) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Alnasl.BusSupervisor,
               {__MODULE__, [{:port, port} | opts]}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  def child_spec(opts) do
    %{id: {__MODULE__, opts[:port]}, start: {__MODULE__, :start_bus, [opts]}, restart: :transient}
  end

  def start_bus(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Alnasl.BusRegistry, Keyword.fetch!(opts, :port)}}
    )
  end

  @doc "Puts `address` in the rotation; its events go to `owner` as `{:driver, id, event}`."
  def attach(bus, address, owner, id), do: GenServer.call(bus, {:attach, address, owner, id})

  def detach(bus, address), do: GenServer.call(bus, {:detach, address})

  @doc "The rotation as it stands: `[%{address, answered, missed, connected?}]`."
  def stats(bus), do: GenServer.call(bus, :stats)

  # --- the bus -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    state = %{
      port: port,
      transport: Keyword.get(opts, :transport) || Transport.for_port(port),
      handle: nil,
      buffer: <<>>,
      # address => %{owner, id, ref, board, misses, answered, missed, connected?}
      boards: %{},
      order: [],
      waiting: nil,
      round: 0,
      debug?: Keyword.get(opts, :debug, false),
      reply_ms: Keyword.get(opts, :reply_ms, 250),
      gap_ms: Keyword.get(opts, :gap_ms, 20),
      lost_after: Keyword.get(opts, :lost_after, 8),
      clock_every: Keyword.get(opts, :clock_every, 5),
      retry_ms: Keyword.get(opts, :retry_ms, 3_000)
    }

    send(self(), :open)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:attach, address, owner, id}, _from, state) do
    ref = Process.monitor(owner)

    board = %{
      owner: owner,
      id: id,
      ref: ref,
      board: nil,
      misses: 0,
      answered: 0,
      missed: 0,
      connected?: false
    }

    state = %{
      state
      | boards: Map.put(state.boards, address, board),
        order: Enum.uniq(state.order ++ [address])
    }

    if state.waiting == nil and state.handle != nil, do: send(self(), :poll)
    {:reply, :ok, state}
  end

  def handle_call({:detach, address}, _from, state), do: {:reply, :ok, remove(state, address)}

  def handle_call(:stats, _from, state) do
    stats =
      for address <- Enum.sort(Map.keys(state.boards)) do
        state.boards[address]
        |> Map.take([:answered, :missed, :connected?])
        |> Map.put(:address, address)
      end

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:open, %{handle: nil} = state) do
    case state.transport.open(state.port, baud: Protocol.baud()) do
      {:ok, handle} ->
        # ASSUMED: boards fresh from power-up need to be told to go to bus mode.
        state.transport.write(handle, Bus.to_busmode())
        send(self(), :poll)
        {:noreply, %{state | handle: handle, buffer: <<>>, waiting: nil}}

      {:error, reason} ->
        if state.debug?, do: Logger.info("dgt bus #{state.port}: cannot open: #{inspect(reason)}")
        Process.send_after(self(), :open, state.retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:open, state), do: {:noreply, state}

  # Ask the next address in the rotation.
  def handle_info(:poll, %{waiting: nil, handle: handle, order: [address | rest]} = state)
      when handle != nil do
    ask_clock? = rem(state.round, state.clock_every) == 0

    frames =
      Bus.command(:board, address) <> if(ask_clock?, do: Bus.command(:clock, address), else: <<>>)

    emit(state, address, {:raw, :tx, frames})

    if state.debug?,
      do: Logger.info("dgt bus #{state.port} tx #{Base.encode16(frames, case: :lower)}")

    case state.transport.write(handle, frames) do
      :ok ->
        timer = Process.send_after(self(), {:no_answer, address}, state.reply_ms)
        round = if rest == [], do: state.round + 1, else: state.round
        {:noreply, %{state | waiting: {address, timer}, order: rest ++ [address], round: round}}

      {:error, reason} ->
        {:noreply, drop(state, reason)}
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:no_answer, address}, %{waiting: {address, _timer}} = state) do
    state =
      if is_map_key(state.boards, address),
        do: update_in(state.boards[address], &missed(&1, address, state)),
        else: state

    Process.send_after(self(), :poll, state.gap_ms)
    {:noreply, %{state | waiting: nil}}
  end

  def handle_info({:no_answer, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.boards, fn {_address, board} -> board.ref == ref end) do
      {address, _board} -> {:noreply, remove(state, address)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(message, state) do
    case state.transport.message(message) do
      {:data, bytes} -> {:noreply, received(state, bytes)}
      {:error, reason} -> {:noreply, drop(state, reason)}
      nil -> {:noreply, state}
    end
  end

  # --- answers -----------------------------------------------------------------

  defp received(state, bytes) do
    if state.debug?,
      do: Logger.info("dgt bus #{state.port} rx #{Base.encode16(bytes, case: :lower)}")

    {answers, rest} = Bus.parse(state.buffer <> bytes)

    case state.waiting do
      {address, _timer} -> emit(state, address, {:raw, :rx, bytes})
      nil -> :ok
    end

    Enum.reduce(answers, %{state | buffer: rest}, &answer/2)
  end

  defp answer({:bad_checksum, _address}, state), do: state

  defp answer({address, message}, state) do
    case state.boards[address] do
      nil ->
        state

      board ->
        board = answered(board, address, state)

        board =
          case message do
            {:board, squares} ->
              if squares != board.board,
                do: Driver.emit(board.owner, board.id, {:position, squares})

              %{board | board: squares}

            {:clock, clock} ->
              if reading = Protocol.reading(clock, :left),
                do: Driver.emit(board.owner, board.id, {:clock, reading})

              board

            {:version, version} ->
              Driver.emit(board.owner, board.id, {:info, %{firmware: version}})
              board

            _other ->
              board
          end

        state = put_in(state.boards[address], board)

        # The board dump is the answer the scheduler was waiting for.
        case {state.waiting, message} do
          {{^address, timer}, {:board, _}} ->
            Process.cancel_timer(timer)
            Process.send_after(self(), :poll, state.gap_ms)
            %{state | waiting: nil}

          _other ->
            state
        end
    end
  end

  defp answered(board, _address, _state) do
    Driver.emit(board.owner, board.id, {:poll, :ok})
    unless board.connected?, do: Driver.emit(board.owner, board.id, :connected)
    %{board | misses: 0, answered: board.answered + 1, connected?: true}
  end

  defp missed(board, _address, state) do
    Driver.emit(board.owner, board.id, {:poll, :missed})
    misses = board.misses + 1

    if misses == state.lost_after and board.connected? do
      Driver.emit(board.owner, board.id, :disconnected)
      %{board | misses: misses, missed: board.missed + 1, connected?: false, board: nil}
    else
      %{board | misses: misses, missed: board.missed + 1}
    end
  end

  defp emit(state, address, event) do
    case state.boards[address] do
      nil -> :ok
      board -> Driver.emit(board.owner, board.id, event)
    end
  end

  defp remove(state, address) do
    case state.boards[address] do
      nil ->
        state

      board ->
        Process.demonitor(board.ref, [:flush])

        %{
          state
          | boards: Map.delete(state.boards, address),
            order: List.delete(state.order, address)
        }
    end
  end

  # The port itself is gone: every board on it is.
  defp drop(%{handle: nil} = state, _reason), do: state

  defp drop(state, reason) do
    if state.debug?, do: Logger.info("dgt bus #{state.port}: lost (#{inspect(reason)})")
    state.transport.close(state.handle)

    boards =
      Map.new(state.boards, fn {address, board} ->
        if board.connected?, do: Driver.emit(board.owner, board.id, :disconnected)
        {address, %{board | connected?: false, board: nil, misses: 0}}
      end)

    case state.waiting do
      {_address, timer} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    Process.send_after(self(), :open, state.retry_ms)
    %{state | handle: nil, boards: boards, waiting: nil, buffer: <<>>}
  end
end

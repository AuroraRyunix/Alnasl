defmodule Alnasl.Driver.DgtBus do
  @moduledoc """
  A loop of DGT boards on one serial port: each board has an address, and
  each speaks only when asked.

  The bytes are `Alnasl.Dgt.Bus`, corrected against a real loop of two boards
  on 2026-10-12 (`docs/real-loop-2026-10-12.md`). What that loop could not
  show - nobody moved a piece, no clock was attached - is said there and in
  `Alnasl.Dgt.Bus.unverified/0`, and this driver is built so that it does
  not depend on it: see "Why a dump as well" below.

  ## How it is built

  One process per serial port (the bus), started on demand and found by the
  port's name. A board is `attach/4`ed to it with its address and its owner;
  the bus then sends that owner the same `{:driver, id, event}` messages any
  driver sends, so nothing above knows a board is on a loop. When the last
  board lets go, the bus tells the boards to leave bus mode, closes the port
  and stops.

  ## The questions

  One at a time: a question is written, its answer awaited, then the next
  (a real board drops questions that arrive back to back). A board gets, in
  turn with the others:

  - **"what changed?"** - the usual question. Six bytes back when nothing
    did, some 16 ms there and back; otherwise the squares that changed, each
    applied to the picture of that board, and the clock time when a lever
    went over (which is the moment the clock itself is asked);
  - **"your whole board"** every `dump_ms` (3 s, longer on a full loop) - 70
    bytes, 80 ms;
  - **"your clock"** every `clock_ms` (1 s, longer on a full loop) - 13
    bytes, 31 ms.

  A board met for the first time (or back after being away) is first asked
  what changed - the answer is its whole memory since it was switched on,
  up to a second and a half of it, and is thrown away - then its version,
  then its whole board.

  ## Why a dump as well

  That "what changed?" reports a move as it is made is what DGT's text says
  and what the boards' memories look like; it was not SEEN, because nobody
  was at the boards. The whole-board question is what the single-board
  driver has been verified with, cannot be misread, and wins whenever the
  two disagree. If the changes should fail on some board, moves arrive up
  to `dump_ms` late instead of at once; they do not arrive wrong.

  ## A board that does not answer

  `reply_ms` (200) of silence is a **missed poll**, reported as such, and
  the next thing that board is asked is its whole board (a lost answer to
  "what changed?" took its changes with it). After `lost_after` (5) in a row
  the board is reported disconnected; it is then asked only every
  `absent_ms` (2 s), so that the others are not kept waiting for it, and is
  back the moment it answers.

  ## A board nobody told us about

  Every `discover_ms` (10 s) each board that is answering is told to sit out
  the next ping, and a ping goes to everybody. Nobody is waited for: the
  questions go on. A board that was plugged into the loop since answers
  within a second with its address; it is pinged once more by name (two
  answers on top of each other can look like an address nobody has), and
  then handed to `:stranger` (by default `Alnasl.Loops.stranger/2`, which
  gives it a row), once. Its answer may fall on top of another board's and
  spoil one poll - of which there are sixty a second.

  ## As a driver

  `start_link/1` (the `Alnasl.Driver` callback) is what a board's process
  calls: it makes sure the bus for `:port` runs and attaches `:address` to
  it. The process it returns stands for that attachment.
  """

  use GenServer

  @behaviour Alnasl.Driver

  require Logger

  alias Alnasl.{Driver, Transport}
  alias Alnasl.Dgt.{Bus, Loop, Protocol}

  @bus_opts [
    :transport,
    :debug,
    :reply_ms,
    :gap_ms,
    :lost_after,
    :absent_ms,
    :dump_ms,
    :clock_ms,
    :discover_ms,
    :stranger
  ]

  # --- a board on the bus ------------------------------------------------------

  @impl Alnasl.Driver
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    address = Keyword.fetch!(opts, :address)
    owner = Keyword.fetch!(opts, :owner)
    id = Keyword.fetch!(opts, :id)

    Agent.start_link(fn ->
      {:ok, bus} = ensure(port, Keyword.take(opts, @bus_opts))
      # A bus that dies takes its boards' drivers with it, so that each
      # board's process starts a new one.
      Process.link(bus)
      attach(bus, address, owner, id)
      {bus, address}
    end)
  end

  @doc "The bus process for `port`, started if need be."
  def ensure(port, opts \\ []) do
    case whereis(port) do
      nil ->
        case DynamicSupervisor.start_child(
               Alnasl.BusSupervisor,
               {__MODULE__, [{:port, port} | opts]}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc "The bus process for `port`, or `nil`."
  def whereis(port) do
    case Registry.lookup(Alnasl.BusRegistry, port) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def child_spec(opts) do
    %{id: {__MODULE__, opts[:port]}, start: {__MODULE__, :start_bus, [opts]}, restart: :temporary}
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

  @doc """
  How the line is doing: `%{polls, trip_ms, worst_trip_ms, cycle_ms,
  worst_cycle_ms}` - the median and the worst time from a question to its
  whole answer, and from one "what changed?" to a board to the next to the
  same board (how late a move can be), over the last few hundred of each.
  """
  def timing(bus), do: GenServer.call(bus, :timing)

  @doc "Every address heard on the loop since the port was opened, attached or not."
  def present(bus), do: GenServer.call(bus, :present)

  # --- the bus -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    Process.flag(:trap_exit, true)

    state = %{
      port: port,
      transport: Keyword.get(opts, :transport) || Transport.for_port(port),
      handle: nil,
      buffer: <<>>,
      # address => a board (see `new_board/2`)
      boards: %{},
      order: [],
      # Addresses that answered a ping and have no row: told about once.
      strangers: MapSet.new(),
      stranger:
        Keyword.get(opts, :stranger) ||
          Application.get_env(:alnasl, :loop_stranger, &Alnasl.Loops.stranger/2),
      # The question out now: %{address, kind, timer, ref, at, tx, rx}
      waiting: nil,
      # Questions that go before the rotation: the discovery's.
      plan: [],
      # "Due now" is the time now, not 0: the monotonic clock may be negative.
      discover_at: now(),
      trips: [],
      cycles: [],
      polls: 0,
      debug?: Keyword.get(opts, :debug, false),
      reply_ms: Keyword.get(opts, :reply_ms) || Loop.reply_ms(),
      # No pause between an answer and the next question: 340 of them in a
      # row were all answered. (A stand-in line answers in no time at all,
      # and is given a moment so that it does not spin.)
      gap_ms:
        Keyword.get(opts, :gap_ms) ||
          Application.get_env(:alnasl, :loop_gap_ms, if(fake?(port), do: 5, else: 0)),
      lost_after: Keyword.get(opts, :lost_after, 5),
      absent_ms: Keyword.get(opts, :absent_ms, 2_000),
      dump_ms: Keyword.get(opts, :dump_ms, 3_000),
      clock_ms: Keyword.get(opts, :clock_ms, 1_000),
      discover_ms:
        Keyword.get(opts, :discover_ms) || Application.get_env(:alnasl, :loop_discover_ms, 10_000),
      retry_ms: Keyword.get(opts, :retry_ms, 3_000)
    }

    send(self(), :open)
    {:ok, state}
  end

  defp new_board(owner, id) do
    %{
      owner: owner,
      id: id,
      ref: Process.monitor(owner),
      board: nil,
      clock: nil,
      connected?: false,
      misses: 0,
      answered: 0,
      missed: 0,
      # What a board is asked before the rotation's usual questions.
      todo: [:flush, :version, :board],
      dump_at: now(),
      clock_at: now(),
      retry_at: now(),
      asked_at: nil
    }
  end

  @impl GenServer
  def handle_call({:attach, address, owner, id}, _from, state) do
    state = remove(state, address)

    state = %{
      state
      | boards: Map.put(state.boards, address, new_board(owner, id)),
        order: state.order ++ [address],
        strangers: MapSet.delete(state.strangers, address)
    }

    {:reply, :ok, state}
  end

  def handle_call({:detach, address}, _from, state),
    do: state |> remove(address) |> stop_when_empty(:reply)

  def handle_call(:stats, _from, state) do
    stats =
      for address <- Enum.sort(Map.keys(state.boards)) do
        state.boards[address]
        |> Map.take([:answered, :missed, :connected?])
        |> Map.put(:address, address)
      end

    {:reply, stats, state}
  end

  def handle_call(:timing, _from, state) do
    {:reply,
     %{
       polls: state.polls,
       trip_ms: median(state.trips),
       worst_trip_ms: Enum.max(state.trips, fn -> nil end),
       cycle_ms: median(state.cycles),
       worst_cycle_ms: Enum.max(state.cycles, fn -> nil end)
     }, state}
  end

  def handle_call(:present, _from, state) do
    answering = for {address, %{connected?: true}} <- state.boards, do: address
    {:reply, Enum.sort(answering ++ MapSet.to_list(state.strangers)), state}
  end

  defp median([]), do: nil
  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))

  @impl GenServer
  def handle_info(:open, %{handle: nil} = state) do
    case state.transport.open(state.port, baud: Protocol.baud()) do
      {:ok, handle} ->
        state.transport.write(handle, Bus.to_busmode())
        # A question in the same breath as that byte gets lost.
        Process.send_after(self(), :poll, Loop.settle_ms())

        {:noreply,
         %{
           state
           | handle: handle,
             buffer: <<>>,
             waiting: nil,
             plan: [],
             discover_at: now() + first_look(state)
         }}

      {:error, reason} ->
        if state.debug?, do: Logger.info("dgt bus #{state.port}: cannot open: #{inspect(reason)}")

        for {_address, board} <- state.boards,
            do: Driver.emit(board.owner, board.id, {:info, %{error: inspect(reason)}})

        Process.send_after(self(), :open, state.retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:open, state), do: {:noreply, state}

  # The next question.
  def handle_info(:poll, %{waiting: nil, handle: handle} = state) when handle != nil do
    case next(state, now()) do
      {nil, state} ->
        Process.send_after(self(), :poll, 50)
        {:noreply, state}

      {:ping_everybody, state} ->
        # Nobody is waited for: whoever answers is heard between the
        # answers of the others.
        case write(state, Bus.command(:ping, 0)) do
          {:ok, state} ->
            again(state)
            {:noreply, state}

          {:error, state} ->
            {:noreply, state}
        end

      {{kind, address}, state} ->
        frame = Bus.command(command(kind), address)

        case write(state, frame) do
          {:ok, state} ->
            ref = make_ref()

            waiting = %{
              address: address,
              kind: kind,
              ref: ref,
              timer: Process.send_after(self(), {:no_answer, ref}, state.reply_ms),
              at: now(),
              tx: frame,
              rx: <<>>
            }

            {:noreply, %{state | waiting: waiting}}

          {:error, state} ->
            {:noreply, state}
        end
    end
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:no_answer, ref}, %{waiting: %{ref: ref} = waiting} = state) do
    state = %{state | waiting: nil, buffer: <<>>}

    state =
      if is_map_key(state.boards, waiting.address),
        do: update_in(state.boards[waiting.address], &missed(&1, state)),
        else: state

    again(state)
    {:noreply, state}
  end

  def handle_info({:no_answer, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.boards, fn {_address, board} -> board.ref == ref end) do
      {address, _board} -> state |> remove(address) |> stop_when_empty(:noreply)
      nil -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    case state.transport.message(message) do
      {:data, bytes} -> {:noreply, received(state, bytes)}
      {:error, reason} -> {:noreply, drop(state, reason)}
      nil -> {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{handle: handle, transport: transport}) when handle != nil do
    # Left as a program that expects single boards would like them.
    transport.write(handle, Bus.command(:end_busmode, 0))
    transport.close(handle)
  end

  def terminate(_reason, _state), do: :ok

  # --- which question ----------------------------------------------------------

  defp next(%{plan: [step | plan]} = state, _now), do: {step, %{state | plan: plan}}

  defp next(%{boards: boards} = state, _now) when boards == %{}, do: {nil, state}

  defp next(state, now) do
    if now >= state.discover_at do
      answering = for address <- state.order, state.boards[address].connected?, do: address
      plan = Enum.map(answering, &{:ignore, &1}) ++ [:ping_everybody]
      next(%{state | plan: plan, discover_at: now + state.discover_ms}, now)
    else
      turn(state, state.order, now)
    end
  end

  # The first board in the rotation that is due; it goes to the back.
  defp turn(state, [], _now), do: {nil, state}

  defp turn(state, [address | rest], now) do
    board = state.boards[address]

    if board.connected? or now >= board.retry_at do
      kind = question(board, now)
      order = List.delete(state.order, address) ++ [address]
      state = %{state | order: order}

      state =
        if kind == :changes do
          cycles =
            if board.asked_at, do: keep([now - board.asked_at | state.cycles]), else: state.cycles

          put_in(%{state | cycles: cycles}.boards[address].asked_at, now)
        else
          state
        end

      {{kind, address}, state}
    else
      turn(state, rest, now)
    end
  end

  defp question(%{todo: [first | _]}, _now), do: first

  defp question(board, now) do
    cond do
      now >= board.dump_at -> :board
      now >= board.clock_at -> :clock
      true -> :changes
    end
  end

  defp command(:flush), do: :changes
  defp command(:ignore), do: :ignore_next_ping
  defp command(:verify), do: :ping
  defp command(kind), do: kind

  defp keep(list), do: Enum.take(list, 400)

  # --- answers -----------------------------------------------------------------

  defp received(state, bytes) do
    if state.debug?,
      do: Logger.info("dgt bus #{state.port} rx #{Base.encode16(bytes, case: :lower)}")

    {answers, rest} = Bus.parse(state.buffer <> bytes)
    state = %{state | buffer: rest} |> still_talking(bytes)
    Enum.reduce(answers, state, &answer/2)
  end

  # A long answer is allowed its length: the silence is what is timed.
  defp still_talking(%{waiting: %{} = waiting} = state, bytes) do
    Process.cancel_timer(waiting.timer)
    timer = Process.send_after(self(), {:no_answer, waiting.ref}, state.reply_ms)
    %{state | waiting: %{waiting | timer: timer, rx: waiting.rx <> bytes}}
  end

  defp still_talking(state, _bytes), do: state

  defp answer({:bad_checksum, _address}, state), do: state

  defp answer({address, message}, %{waiting: %{address: address, kind: kind} = waiting} = state)
       when is_map_key(state.boards, address) do
    if fits?(kind, message) do
      Process.cancel_timer(waiting.timer)
      again(state)
      t = now()

      state = %{
        state
        | waiting: nil,
          polls: state.polls + 1,
          trips: keep([t - waiting.at | state.trips])
      }

      board =
        state.boards[address]
        |> answered()
        |> raw(waiting, message)
        |> take(kind, message, address, t, state)

      put_in(state.boards[address], board)
    else
      stray(state, address, message)
    end
  end

  # The address that answered a ping to everybody answers to its name too:
  # it is a board, not two answers that fell on top of each other.
  defp answer(
         {address, {:ping, _}},
         %{waiting: %{address: address, kind: :verify} = waiting} = state
       ) do
    Process.cancel_timer(waiting.timer)
    again(state)
    if state.debug?, do: Logger.info("dgt bus #{state.port}: a new board answers as #{address}")
    state.stranger.(state.port, address)
    %{state | waiting: nil, strangers: MapSet.put(state.strangers, address)}
  end

  defp answer({address, message}, state), do: stray(state, address, message)

  # An answer nobody is waiting for. A ping from an address without a row
  # is a board that was plugged into the loop.
  defp stray(state, address, {:ping, _}) when not is_map_key(state.boards, address) do
    if MapSet.member?(state.strangers, address) or {:verify, address} in state.plan,
      do: state,
      else: %{state | plan: state.plan ++ [{:verify, address}]}
  end

  defp stray(state, _address, _message), do: state

  defp fits?(:flush, {:changes, _}), do: true
  defp fits?(:changes, {:changes, _}), do: true
  defp fits?(:board, {:board, _}), do: true
  defp fits?(:clock, {:clock, _}), do: true
  defp fits?(:clock, {:clock_ack, _}), do: true
  defp fits?(:version, {:version, _}), do: true
  defp fits?(:ignore, {:ping, _}), do: true
  defp fits?(_kind, _message), do: false

  defp answered(board) do
    Driver.emit(board.owner, board.id, {:poll, :ok})
    unless board.connected?, do: Driver.emit(board.owner, board.id, :connected)
    %{board | misses: 0, answered: board.answered + 1, connected?: true}
  end

  # The bytes go into the capture when they said something: sixty "nothing
  # changed" a second would bury the rest.
  defp raw(board, %{kind: kind}, message)
       when kind == :ignore or (kind == :changes and message == {:changes, <<>>}),
       do: board

  defp raw(board, waiting, _message) do
    Driver.emit(board.owner, board.id, {:raw, :tx, waiting.tx})
    Driver.emit(board.owner, board.id, {:raw, :rx, waiting.rx})
    board
  end

  # The board's whole memory since it was switched on: not news.
  defp take(board, :flush, _message, _address, _t, _state), do: done(board, :flush)
  defp take(board, :ignore, _message, _address, _t, _state), do: board

  defp take(board, :version, {:version, version}, address, _t, _state) do
    info = %{firmware: version, loop_number: address}

    info =
      case Bus.serial(address, version) do
        nil -> info
        serial -> Map.put(info, :serial, serial)
      end

    Driver.emit(board.owner, board.id, {:info, info})
    done(board, :version)
  end

  defp take(board, :board, {:board, squares}, _address, t, state) do
    board
    |> position(squares)
    |> Map.put(:dump_at, t + every(state, :dump_ms, 500))
    |> done(:board)
  end

  defp take(board, :changes, {:changes, data}, _address, t, _state) do
    Enum.reduce(Bus.changes(data), board, fn
      {:field, square, piece}, %{board: squares} = board when squares != nil ->
        position(board, put_elem(squares, square, piece))

      # The lever went over: the clock has something to say now.
      {:clock, _side, _ms}, board ->
        %{board | clock_at: t}

      # It was off, or restarted itself: its picture is not ours any more.
      event, board when event in [:power_up, :restarted] ->
        %{board | dump_at: t}

      _other, board ->
        board
    end)
  end

  defp take(board, :clock, {:clock, clock}, _address, t, state) do
    board = %{board | clock_at: t + every(state, :clock_ms, 250)}

    case Protocol.reading(clock) do
      nil ->
        # A board that never had a clock says nothing about clocks.
        if is_map(board.clock),
          do: Driver.emit(board.owner, board.id, {:info, %{clock: false}})

        %{board | clock: if(board.clock, do: :off)}

      reading ->
        if reading != board.clock do
          Driver.emit(board.owner, board.id, {:clock, reading})

          if clock.battery_low?,
            do: Driver.emit(board.owner, board.id, {:info, %{clock_battery_low: true}})
        end

        %{board | clock: reading}
    end
  end

  defp take(board, :clock, {:clock_ack, _}, _address, t, state),
    do: %{board | clock_at: t + every(state, :clock_ms, 250)}

  defp done(%{todo: [kind | rest]} = board, kind), do: %{board | todo: rest}
  defp done(board, _kind), do: board

  defp position(%{board: squares} = board, squares), do: board

  defp position(board, squares) do
    Driver.emit(board.owner, board.id, {:position, squares})
    %{board | board: squares}
  end

  # The whole-board and clock questions take 80 and 31 ms of a line that
  # carries 960 bytes a second: on a full loop they are asked less often, so
  # that most of the line stays with "what changed?".
  defp every(state, key, per_board) do
    answering = Enum.count(state.boards, fn {_address, board} -> board.connected? end)
    max(Map.fetch!(state, key), answering * per_board)
  end

  defp missed(board, state) do
    Driver.emit(board.owner, board.id, {:poll, :missed})
    misses = board.misses + 1
    t = now()

    board = %{
      board
      | misses: misses,
        missed: board.missed + 1,
        dump_at: t,
        # The first question after a single-board command is swallowed by
        # an old board: asked again at once. After that, at leisure.
        retry_at: if(board.connected? or misses < 2, do: t, else: t + state.absent_ms)
    }

    cond do
      misses == state.lost_after and board.connected? ->
        Driver.emit(board.owner, board.id, :disconnected)
        %{board | connected?: false, board: nil, todo: [:flush, :version, :board]}

      true ->
        board
    end
  end

  defp write(state, frame) do
    if state.debug?,
      do: Logger.info("dgt bus #{state.port} tx #{Base.encode16(frame, case: :lower)}")

    case state.transport.write(state.handle, frame) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, drop(state, reason)}
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

  # Nobody left to read: the port is let go of.
  defp stop_when_empty(%{boards: boards} = state, :reply) when boards == %{},
    do: {:stop, :normal, :ok, state}

  defp stop_when_empty(%{boards: boards} = state, :noreply) when boards == %{},
    do: {:stop, :normal, state}

  defp stop_when_empty(state, :reply), do: {:reply, :ok, state}
  defp stop_when_empty(state, :noreply), do: {:noreply, state}

  # The port itself is gone: every board on it is.
  defp drop(%{handle: nil} = state, _reason), do: state

  defp drop(state, reason) do
    if state.debug?, do: Logger.info("dgt bus #{state.port}: lost (#{inspect(reason)})")
    state.transport.close(state.handle)

    boards =
      Map.new(state.boards, fn {address, board} ->
        if board.connected?, do: Driver.emit(board.owner, board.id, :disconnected)

        {address,
         %{board | connected?: false, board: nil, misses: 0, todo: [:flush, :version, :board]}}
      end)

    if state.waiting, do: Process.cancel_timer(state.waiting.timer)
    Process.send_after(self(), :open, state.retry_ms)
    %{state | handle: nil, boards: boards, waiting: nil, buffer: <<>>, plan: []}
  end

  # On to the next question. Without a timer when there is no pause: a
  # timer of 1 ms is 16 ms on Windows, which is a whole answer.
  defp again(%{gap_ms: 0}), do: send(self(), :poll)
  defp again(state), do: Process.send_after(self(), :poll, state.gap_ms)

  defp fake?(port), do: Transport.for_port(port) == Alnasl.Transport.Fake

  # The first look for boards nobody told us about waits until the boards we
  # were told about have answered and can be told to sit it out: their
  # answers to a ping would fall on top of their first answers to us.
  defp first_look(state), do: min(2_000, state.discover_ms)

  defp now, do: System.monotonic_time(:millisecond)
end

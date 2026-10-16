defmodule AlnaslWeb.BridgeSocket do
  @moduledoc """
  The server end of an Arkab bridge's link, at `/bridge/link`: one
  WebSocket a bridge, dialled by the bridge. The frames are
  `Arkab.Protocol`'s; the rules are Arkab's `docs/protocol.md`.

  The first frame is `hello`, with the bridge's key in it - not in the URL,
  which proxies write down. Until then nothing else is listened to, and a
  link that says nothing for ten seconds is closed.

  ## Events in

  A batch of events is taken in order, board by board as they come: each
  goes to its board's driver (`Alnasl.Driver.Remote`), and the board's
  process is waited for (`Alnasl.BoardServer.sync/1`) before the number is
  written down and acknowledged. So an `ack` means saved, queued, logged -
  and a number the box has seen before is acknowledged again without being
  applied twice. A board whose row is switched off here is not read: its
  events are acknowledged and dropped, as a board with its cable pulled
  would be. A board whose process is not up yet (it is starting, or its
  driver restarting) is waited for; if it does not come, the link is closed
  with what was taken acknowledged, and the bridge sends the rest again
  when it is back.

  A burst after an outage is not replayed into the site position by
  position: the board's process tells the pages four times a second at
  most, whatever arrives.

  ## Commands out

  `Alnasl.Bridges.command/3` sends one; the answer is broadcast. On every
  connect the bridge is asked to send every board again in full: whatever
  happened on a board while the line was down and the bridge's queue does
  not hold, the board as it stands now does.
  """

  @behaviour Phoenix.Socket.Transport

  require Logger

  alias Alnasl.{BoardServer, Bridges}
  alias Alnasl.Driver.Remote
  alias Arkab.Protocol

  @hello_ms 10_000
  @board_wait_ms 10_000

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(_info), do: {:ok, %{bridge: nil}}

  @impl true
  def init(state) do
    Process.send_after(self(), :hello_timeout, @hello_ms)
    {:ok, state}
  end

  # --- frames in ---------------------------------------------------------------

  @impl true
  def handle_in({text, _opts}, state) do
    case Protocol.decode(text) do
      {:ok, frame} -> frame(frame, state)
      {:error, :bad_frame} -> {:ok, state}
    end
  end

  defp frame(%{"type" => "hello"} = hello, %{bridge: nil} = state) do
    with true <- Protocol.accepts?(hello["v"]) || {:error, :version},
         {:ok, bridge} <- Bridges.authenticate(hello["bridge"], hello["key"]),
         {:ok, _owner} <- register(bridge) do
      bridge = Bridges.connected(bridge)
      Bridges.notify()
      send(self(), {:command, Protocol.command("hello-resend", "resend")})

      reply(Protocol.welcome(bridge.seen_seq, Bridges.server_name()), %{
        state
        | bridge: bridge
      })
    else
      {:error, reason} when reason in [:version, :key, :revoked] ->
        refuse(to_string(reason), state)

      # The same bridge, connected twice: the older link is the stale one.
      {:error, {:already_registered, pid}} ->
        Process.exit(pid, :kill)
        Process.sleep(50)
        frame(hello, state)
    end
  end

  # Nothing but hello before hello.
  defp frame(_frame, %{bridge: nil} = state), do: {:ok, state}

  defp frame(%{"type" => "events", "events" => events}, state) when is_list(events),
    do: take(events, state)

  defp frame(%{"type" => "boards"} = frame, state) do
    live = %{
      boards: List.wrap(frame["boards"]),
      ports: List.wrap(frame["ports"]),
      recording?: frame["recording"] == true,
      connected_at: DateTime.utc_now(:second)
    }

    Registry.update_value(Alnasl.BridgeRegistry, state.bridge.id, fn _old -> live end)

    for %{"id" => name} when is_binary(name) <- live.boards,
        do: Bridges.board_row(state.bridge, name)

    Bridges.notify()
    {:ok, state}
  end

  defp frame(%{"type" => "reply", "id" => id} = reply, state) do
    Bridges.notify({:reply, state.bridge.id, id, reply["ok"] == true, reply["error"]})
    {:ok, state}
  end

  # Removed on the bridge: removed here.
  defp frame(%{"type" => "leave"}, state) do
    Bridges.forget(state.bridge)
    {:stop, :normal, %{state | bridge: nil}}
  end

  defp frame(_other, state), do: {:ok, state}

  defp register(bridge) do
    Registry.register(Alnasl.BridgeRegistry, bridge.id, %{
      boards: [],
      ports: [],
      recording?: false,
      connected_at: DateTime.utc_now(:second)
    })
  end

  # --- events ------------------------------------------------------------------

  defp take(raw, state) do
    seen = state.bridge.seen_seq

    decoded =
      for map <- raw, {:ok, event} <- [Protocol.decode_event(map)], do: event

    highest = Enum.reduce(raw, seen, &max(&2, seq(&1)))
    fresh = Enum.filter(decoded, &(&1.seq > seen))

    case apply_events(state.bridge, Enum.chunk_by(fresh, & &1.id), seen) do
      {:ok, _done} ->
        state = mark(state, highest)
        reply(Protocol.ack(highest), state)

      {:stopped, done, reason} ->
        Logger.warning("bridge #{state.bridge.name}: stopped at #{done}: #{inspect(reason)}")
        state = mark(state, done)
        send(self(), {:stop, reason})
        reply(Protocol.ack(done), state)
    end
  end

  defp seq(%{"s" => s}) when is_integer(s), do: s
  defp seq(_other), do: 0

  defp mark(state, seq) when seq > state.bridge.seen_seq do
    Bridges.seen(state.bridge, seq)
    %{state | bridge: %{state.bridge | seen_seq: seq}}
  end

  defp mark(state, _seq), do: state

  defp apply_events(_bridge, [], done), do: {:ok, done}

  defp apply_events(bridge, [[%{id: name} | _] = events | rest], done) do
    case board(bridge, name) do
      :off ->
        apply_events(bridge, rest, List.last(events).seq)

      {:ok, pid} ->
        try do
          owner = Remote.deliver(pid, events)
          :ok = BoardServer.sync(owner)
          apply_events(bridge, rest, List.last(events).seq)
        catch
          :exit, reason -> {:stopped, done, {:board_went, reason}}
        end

      {:error, reason} ->
        {:stopped, done, reason}
    end
  end

  # The driver of the board the bridge calls `name`, or :off for a row
  # switched off here.
  defp board(bridge, name) do
    case Bridges.board_row(bridge, name) do
      {:ok, %{enabled: false}} -> :off
      {:ok, row} -> wait_for(row.port, System.monotonic_time(:millisecond) + @board_wait_ms)
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for(port, deadline) do
    case Remote.whereis(port) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :board_not_up}
        else
          Process.sleep(20)
          wait_for(port, deadline)
        end

      pid ->
        {:ok, pid}
    end
  end

  # --- from the box ------------------------------------------------------------

  @impl true
  def handle_info({:command, frame}, %{bridge: %{}} = state),
    do: {:push, {:text, Protocol.encode(frame)}, state}

  def handle_info(:leave, state) do
    send(self(), {:stop, :normal})
    {:push, {:text, Protocol.encode(Protocol.leave())}, %{state | bridge: nil}}
  end

  def handle_info(:hello_timeout, %{bridge: nil} = state), do: {:stop, :normal, state}

  def handle_info({:stop, reason}, state), do: {:stop, reason, state}

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{bridge: %{}}) do
    Bridges.notify()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- frames out --------------------------------------------------------------

  defp reply(frame, state), do: {:reply, :ok, {:text, Protocol.encode(frame)}, state}

  defp refuse(reason, state) do
    send(self(), {:stop, :normal})
    reply(Protocol.refused(reason), state)
  end
end

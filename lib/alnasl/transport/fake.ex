defmodule Alnasl.Transport.Fake do
  @moduledoc """
  A serial port that is not there: a process that answers what is written to
  it the way a device would.

  The device is `{module, state}` with `module.handle(state, bytes)` returning
  `{reply_bytes, state}` - in practice `Alnasl.Dgt.Emulator`, a DGT board in
  software. `update/2` changes the device from outside (a piece is moved) and
  sends whatever the device then says unasked; `unplug/1` and `replug/1` pull
  the cable. Port names start with `FAKE`.

  Started by the tests, to drive the real serial driver end to end without a
  board.
  """

  use GenServer

  @behaviour Alnasl.Transport

  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    GenServer.start_link(__MODULE__, opts, name: {:global, {__MODULE__, port}})
  end

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :port)}, start: {__MODULE__, :start_link, [opts]}}
  end

  defp whereis(port), do: :global.whereis_name({__MODULE__, port})

  @doc "Runs `fun` on the device state (`fn state -> {bytes, state} end`) and sends the bytes it returns."
  def update(port, fun), do: GenServer.call(whereis(port), {:update, fun})

  @doc "Sends bytes to whoever has the port open, as if the device had spoken."
  def push(port, bytes), do: GenServer.call(whereis(port), {:push, bytes})

  @doc "Everything written to the port so far."
  def written(port), do: GenServer.call(whereis(port), :written)

  def unplug(port), do: GenServer.call(whereis(port), :unplug)
  def replug(port), do: GenServer.call(whereis(port), :replug)

  # --- the transport -----------------------------------------------------------

  @impl Alnasl.Transport
  def available?, do: true

  @impl Alnasl.Transport
  def enumerate do
    for {__MODULE__, port} <- :global.registered_names(),
        do: %{port: port, description: "stand-in, no hardware"}
  end

  @impl Alnasl.Transport
  def open(port, _opts) do
    case whereis(port) do
      :undefined -> {:error, :enoent}
      pid -> GenServer.call(pid, {:open, self()})
    end
  end

  @impl Alnasl.Transport
  def write(pid, data) do
    GenServer.call(pid, {:write, IO.iodata_to_binary(data)})
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl Alnasl.Transport
  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _reason -> :ok
  end

  @impl Alnasl.Transport
  def message({:alnasl_fake, {:error, reason}}), do: {:error, reason}
  def message({:alnasl_fake, data}) when is_binary(data), do: {:data, data}
  def message(_other), do: nil

  # --- the process -------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {module, state} = Keyword.get(opts, :device, {Alnasl.Transport.Fake.Silent, nil})
    {:ok, %{module: module, device: state, owner: nil, written: <<>>, plugged?: true}}
  end

  @impl GenServer
  def handle_call({:open, _owner}, _from, %{plugged?: false} = s),
    do: {:reply, {:error, :enoent}, s}

  def handle_call({:open, owner}, _from, s), do: {:reply, {:ok, self()}, %{s | owner: owner}}
  def handle_call(:close, _from, s), do: {:reply, :ok, %{s | owner: nil}}
  def handle_call(:written, _from, s), do: {:reply, s.written, s}

  def handle_call({:write, _data}, _from, %{plugged?: false} = s), do: {:reply, {:error, :eio}, s}

  def handle_call({:write, data}, _from, s) do
    {reply, device} = s.module.handle(s.device, data)
    deliver(s, reply)
    {:reply, :ok, %{s | device: device, written: s.written <> data}}
  end

  def handle_call({:update, fun}, _from, s) do
    {bytes, device} = fun.(s.device)
    if s.plugged?, do: deliver(s, bytes)
    {:reply, :ok, %{s | device: device}}
  end

  def handle_call({:push, bytes}, _from, s) do
    deliver(s, bytes)
    {:reply, :ok, s}
  end

  def handle_call(:unplug, _from, s) do
    if s.owner, do: send(s.owner, {:alnasl_fake, {:error, :eio}})
    {:reply, :ok, %{s | plugged?: false, owner: nil}}
  end

  def handle_call(:replug, _from, s), do: {:reply, :ok, %{s | plugged?: true}}

  defp deliver(%{owner: owner}, bytes) when is_pid(owner) and byte_size(bytes) > 0,
    do: send(owner, {:alnasl_fake, bytes})

  defp deliver(_s, _bytes), do: :ok
end

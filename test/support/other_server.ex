defmodule Alnasl.OtherServer do
  @moduledoc """
  A second server for a bridge to belong to - another Alnasl, as far as the
  bridge can tell: it takes a join code, then events, and acknowledges
  them. It keeps the numbers it took, so a test can see that it got
  everything, once, after it was away. `down/1` and `up/1` take its
  listener away and bring it back on the same port.
  """

  use Agent

  def start do
    {:ok, agent} = Agent.start_link(fn -> %{seqs: [], seen: 0, key: "other-key"} end)
    {:ok, port} = listen(agent, 0)
    %{agent: agent, port: port}
  end

  defp listen(agent, port) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Alnasl.OtherServer.Plug, agent},
        port: port,
        ip: :loopback,
        startup_log: false
      )

    # Not linked: a server going away is not the test going away.
    Process.unlink(pid)
    ExUnit.Callbacks.on_exit(fn -> stop(pid) end)
    Agent.update(agent, &Map.put(&1, :listener, pid))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, port}
  end

  def link(server), do: "http://127.0.0.1:#{server.port}/join/OTHER"

  def down(server) do
    Supervisor.stop(Agent.get(server.agent, & &1.listener))
    server
  end

  # The agent is the test's and goes with it; a listener is not, and does not.
  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  def up(server) do
    {:ok, _port} = listen(server.agent, server.port)
    server
  end

  def seqs(server), do: Agent.get(server.agent, &Enum.reverse(&1.seqs))

  @doc false
  def take(agent, seqs) do
    Agent.get_and_update(agent, fn state ->
      fresh = Enum.filter(seqs, &(&1 > state.seen))
      seen = Enum.max([state.seen | seqs])
      {seen, %{state | seqs: Enum.reverse(fresh) ++ state.seqs, seen: seen}}
    end)
  end

  @doc false
  def seen(agent), do: Agent.get(agent, & &1.seen)
end

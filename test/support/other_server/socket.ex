defmodule Alnasl.OtherServer.Socket do
  @moduledoc false
  @behaviour WebSock

  alias Alnasl.OtherServer
  alias Arkab.Protocol

  @impl true
  def init(agent), do: {:ok, agent}

  @impl true
  def handle_in({text, _opts}, agent) do
    case Protocol.decode(text) do
      {:ok, %{"type" => "hello"}} ->
        frame(Protocol.welcome(OtherServer.seen(agent), "other"), agent)

      {:ok, %{"type" => "events", "events" => events}} ->
        seen = OtherServer.take(agent, for(%{"s" => s} <- events, do: s))
        frame(Protocol.ack(seen), agent)

      _other ->
        {:ok, agent}
    end
  end

  @impl true
  def handle_info(_message, agent), do: {:ok, agent}

  defp frame(frame, agent), do: {:push, {:text, Protocol.encode(frame)}, agent}
end

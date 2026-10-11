defmodule Alnasl.Destination.OpenResults do
  @moduledoc """
  The results server, as a destination. Everything it does is
  `Alnasl.Outbox`, which was there first and has not changed its mind about
  anything: one row a change, oldest first, a row done with when the server
  has answered for it.
  """

  @behaviour Alnasl.Destination

  alias Alnasl.{Outbox, Settings}

  @impl true
  def id, do: "openresults"

  @impl true
  def configured?, do: Settings.connection_configured?()

  @impl true
  def pending_count, do: Outbox.pending_count()

  @impl true
  def deliver, do: Outbox.deliver_batch(25)

  @impl true
  def setting_keys, do: ~w(server_url slug relay_key)

  @impl true
  def coalesce_ms, do: 0

  @impl true
  def default_enabled?, do: true
end

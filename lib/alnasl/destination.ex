defmodule Alnasl.Destination do
  @moduledoc """
  Somewhere the games go. The results server is one; a Lichess broadcast is
  another; there may be more, and they do not wait for each other.

  ## What a destination is

  A module with this behaviour, and a sender of its own
  (`Alnasl.Destination.Sender`): one process per destination, each with its
  own pause, its own last success, its own last error. A destination that is
  offline for three hours holds up nobody but itself.

  Each destination also keeps **its own place in the queue**, in whatever
  form suits what it sends:

  - `Alnasl.Destination.OpenResults` sends every change as a message of its
    own, so its place is the row of the `outbox` table it has got to
    (`Alnasl.Outbox`, unchanged);
  - `Alnasl.Destination.LichessBroadcast` sends the game as it is now, so
    its place is, per game, the game's counter at the last push Lichess
    answered for (`destination_cursors`);
  - `Alnasl.Destination.OpenPairings` reports the game as it is now to the
    pairing program it came from, and keeps its place the same way.

  Both are in the database before anything is sent, and both are per game in
  the order things happened: `games.seq` only ever goes up, and it goes up
  in the same transaction that queues the change.

  ## On and off

  A destination is switched on or off by the arbiter (`set_enabled/2`). Off
  means its sender stays quiet; what it would have sent stays counted, and
  goes out when it is switched on again.

  ## What `deliver/0` answers

  `{result, sent}` - `sent` is how many things the destination took in this
  call, and `result` is where it stopped:

  | result | the sender |
  |---|---|
  | `:empty` | has nothing to do until it is woken |
  | `:unconfigured` | the same, and says so |
  | `{:retry, reason, wait_ms \\| nil}` | tries again after `wait_ms`, or after a pause that doubles up to a minute |
  | `{:blocked, reason}` | the credential or the address is refused: waits, says why, tries every 30 s and when the settings change |
  | anything else | there is more: goes on at once |
  """

  alias Alnasl.Destination.Sender
  alias Alnasl.Settings

  @type result ::
          :empty
          | :unconfigured
          | {:retry, term(), non_neg_integer() | nil}
          | {:blocked, term()}
          | term()

  @doc "A short, stable name: the key of its settings and of its rows."
  @callback id() :: String.t()

  @doc "Has the arbiter given it what it needs to send at all?"
  @callback configured?() :: boolean()

  @doc "How much is waiting for this destination, counted from the database."
  @callback pending_count() :: non_neg_integer()

  @doc "Sends what it can now. See the moduledoc for the answer."
  @callback deliver() :: {result(), non_neg_integer()}

  @doc "The settings whose change should make the sender try again at once."
  @callback setting_keys() :: [String.t()]

  @doc """
  How long the sender waits after being woken before it sends, so that a
  burst of changes goes out as one. 0 sends at once.
  """
  @callback coalesce_ms() :: non_neg_integer()

  @doc "Is it on before the arbiter has said anything?"
  @callback default_enabled?() :: boolean()

  @all [
    Alnasl.Destination.OpenResults,
    Alnasl.Destination.LichessBroadcast,
    Alnasl.Destination.OpenPairings
  ]

  @doc "Every destination Alnasl knows, the results server first."
  def all, do: @all

  def get(id), do: Enum.find(@all, &(&1.id() == id))

  @doc "The registered name of a destination's sender."
  def sender(Alnasl.Destination.OpenResults), do: Alnasl.Outbox
  def sender(module), do: Module.concat(module, Sender)

  @doc "The setting that switches a destination on or off."
  def enabled_key(module), do: "dest_" <> module.id() <> "_enabled"

  def enabled?(module) do
    case Settings.get(enabled_key(module)) do
      nil -> module.default_enabled?()
      value -> value == true
    end
  end

  def set_enabled(module, enabled?) when is_boolean(enabled?) do
    Settings.put(enabled_key(module), enabled?)
    Phoenix.PubSub.broadcast(Alnasl.PubSub, "outbox", :outbox_changed)

    Alnasl.Log.add(
      :info,
      if(enabled?, do: "destination.enabled", else: "destination.disabled"),
      %{destination: module.id()}
    )

    :ok
  end

  @doc """
  A destination as the arbiter should see it: `%{id, module, enabled?, state,
  pending, last_ok, last_error, next_try_at}` with `state` one of `:disabled |
  :unconfigured | :idle | :connected | :offline | :blocked`.
  """
  def status(module) do
    base = Sender.status(sender(module))
    enabled? = enabled?(module)

    state =
      cond do
        not enabled? -> :disabled
        not module.configured?() -> :unconfigured
        true -> base.state
      end

    base
    |> Map.merge(%{id: module.id(), module: module, enabled?: enabled?, state: state})
    |> Map.put(:pending, module.pending_count())
    |> Map.put(:stuck, stuck(module))
  end

  # Rows that can go nowhere (their tournament is gone, or has no results
  # page): only the results server's queue has them.
  defp stuck(Alnasl.Destination.OpenResults), do: Alnasl.Outbox.stuck_count()
  defp stuck(_module), do: 0

  def statuses, do: Enum.map(@all, &status/1)

  @doc """
  What "Send now" can do for a destination, before anything is pressed:

    * `{:go, n}` - `n` things wait (or are being retried); pressing it
      nudges the sender, which tries at once;
    * `{:quiet, reason}` - pressing it could do nothing, and `reason` says
      why: `:switched_off`, `{:not_set_up, id}`, `{:no_key, titles}` (a
      tournament is on a results site but OpenPairings has no relay key for
      it), `:no_code`, `:board_outside` (OpenPairings: games exist on
      boards that play in no linked tournament, so nothing is paired to
      report) or `:nothing_waiting`.

  Sending is automatic; this only decides what the manual nudge is worth.
  """
  def send_plan(module) do
    status = status(module)

    cond do
      not module.configured?() ->
        {:quiet, unconfigured_reason(module)}

      not status.enabled? ->
        {:quiet, :switched_off}

      status.pending > 0 ->
        {:go, status.pending}

      module == Alnasl.Destination.OpenPairings and Alnasl.Seating.outside() != [] ->
        {:quiet, :board_outside}

      true ->
        {:quiet, :nothing_waiting}
    end
  end

  defp unconfigured_reason(Alnasl.Destination.OpenResults) do
    keyless =
      for t <- Alnasl.Tournaments.list(),
          t.kind == "linked",
          not t.gone,
          t.server_url != "",
          t.relay_key == "",
          do: Alnasl.Tournaments.title(t) || ""

    if keyless == [], do: {:not_set_up, "openresults"}, else: {:no_key, keyless}
  end

  defp unconfigured_reason(Alnasl.Destination.OpenPairings), do: :no_code
  defp unconfigured_reason(module), do: {:not_set_up, module.id()}

  @doc "\"Send now\" for one destination: forget the pause and try at once."
  def send_now(module) do
    if pid = Process.whereis(sender(module)), do: send(pid, :send_now)
    :ok
  end

  @doc """
  Where a tournament's games go has changed - a results page, a key, a
  Lichess round, a connect code: every sender forgets its pause and tries
  at once, as it does when one of its own settings changes.
  """
  def settings_changed do
    for module <- @all, pid = Process.whereis(sender(module)), do: send(pid, :send_now)
    Phoenix.PubSub.broadcast(Alnasl.PubSub, "outbox", :outbox_changed)
    :ok
  end

  @doc "Wakes every sender that is running: something was queued."
  def kick do
    for module <- @all, pid = Process.whereis(sender(module)), do: send(pid, :deliver)
    :ok
  end

  @doc "The senders, as children for the application's supervisor."
  def child_specs do
    for module <- @all do
      Supervisor.child_spec({Sender, destination: module, name: sender(module)},
        id: sender(module)
      )
    end
  end
end

defmodule AlnaslWeb.Status do
  @moduledoc """
  What the frame says about the connections, and about whom they are for.

  The badge in the bar used to be one thing: the state of the results
  server, computed over all tournaments, and "Not set up" for a box whose
  own tournament has no results page. For a box whose tournament comes from
  OpenPairings that read as "the connection I just made failed". So the bar
  now says it per destination, for the tournaments that are in use:

    * **OpenPairings** - the codes: connected, no answer, refused;
    * **Results site** - only when some tournament in use is on one: sending,
      waiting, offline, refused - or, when a tournament is published but
      OpenPairings has no relay key for it, that (`:no_key`), with what to do.

  The box's own tournament is mentioned only when it is in use
  (`Alnasl.Tournaments.active/0`).
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.{Destination, Halls, Outbox, Seating, Tournaments}
  alias Alnasl.Accounts.Scope
  alias Alnasl.Destination.OpenResults
  alias AlnaslWeb.LinkWords

  @doc """
  Everything the frame needs beyond the connection to the results server:
  `%{heads: [head] | :results_only, seating: map, waiting: n, live: %{hall_id => n}}`.
  A `head` is `%{id, tone, icon, text, to}`; `waiting` is what the outbox
  holds for the tournaments of the hall on show (the rail's count), `live`
  the connected boards of each hall (the hall picker; empty with one hall).
  """
  def build(link, scope \\ nil) do
    %{
      heads: heads(link, scope),
      waiting: waiting(scope),
      live: live_by_hall(scope),
      seating:
        if own_hall?(scope) do
          %{outside: Seating.outside(), ask: Seating.ask(), auto: Seating.auto()}
        else
          %{outside: [], ask: [], auto: nil}
        end
    }
  end

  @doc """
  What the outbox holds for the tournaments placed in the scope's hall: the
  count beside Results in the rail. Everything on a box without a hall to
  scope by.
  """
  def waiting(scope) do
    by_tournament = Outbox.pending_by_tournament()

    case scope do
      %Scope{hall: %{id: hall_id}} ->
        Enum.reduce(by_tournament, 0, fn {tid, count}, sum ->
          tournament = tid && Tournaments.get(tid)

          if tournament && Alnasl.Placements.in_hall?(tournament, hall_id),
            do: sum + count,
            else: sum
        end)

      _none ->
        by_tournament |> Map.values() |> Enum.sum()
    end
  end

  # The boards that are connected, per hall: only asked when there is a hall
  # to switch to, because it asks every board.
  defp live_by_hall(%Scope{halls: [_, _ | _]}) do
    for snapshot <- Alnasl.Boards.snapshots(), snapshot.connected?, reduce: %{} do
      acc -> Map.update(acc, snapshot[:hall_id] || Halls.own_id(), 1, &(&1 + 1))
    end
  end

  defp live_by_hall(_one), do: %{}

  # The seating notices are about the box's own ports (`Alnasl.Seating`):
  # shown on the box's own hall, and on a box without accounts.
  defp own_hall?(%Scope{open?: false} = scope), do: Scope.hall_id(scope) == Halls.own_id()
  defp own_hall?(_open), do: true

  @doc "The badges of the bar, or `:results_only` for a box with no linked tournament."
  def heads(link, scope \\ nil) do
    case linked(scope) do
      [] ->
        :results_only

      linked ->
        [pairing_head(Halls.here(scope || %Scope{open?: true}, Tournaments.links()))] ++
          results_head(linked, link, scope)
    end
  end

  # The linked tournaments of the hall on show.
  defp linked(%Scope{open?: false} = scope) do
    Halls.here(scope, Enum.filter(Tournaments.list(), &(&1.kind == "linked" and not &1.gone)))
  end

  defp linked(_open), do: Seating.linked()

  defp pairing_head(links) do
    states = Enum.map(links, & &1.state)

    {tone, icon, text} =
      cond do
        "unauthorized" in states ->
          {"bad", "out_of_sync", gettext("OpenPairings: code refused")}

        "unsupported" in states ->
          {"bad", "out_of_sync", gettext("OpenPairings: other version")}

        "unreachable" in states ->
          {"warn", "offline", gettext("OpenPairings: no answer")}

        Enum.all?(states, &(&1 == "ok")) ->
          {"ok", "live", gettext("OpenPairings: connected")}

        true ->
          {nil, "waiting", gettext("OpenPairings: not asked yet")}
      end

    %{id: "head-pairing", tone: tone, icon: icon, text: text, to: "/setup/connections"}
  end

  defp results_head(linked, link, scope) do
    case results(linked, link, scope) do
      nil ->
        []

      {tone, icon, text} ->
        [
          %{id: "head-results", tone: tone, icon: icon, text: text, to: "/outbox"}
          |> Map.put(:open, open_address(scope))
        ]
    end
  end

  # With exactly one tournament in use, the badge has a link to its page on
  # the results site; with several there is no telling which one is meant.
  defp open_address(scope) do
    case active(scope) do
      [one] -> Alnasl.ResultsSite.tournament_url(one)
      _several -> nil
    end
  end

  # The tournaments in use in the hall on show; all of them without a hall.
  defp active(nil), do: Tournaments.active()
  defp active(scope), do: Halls.active(scope)

  @doc """
  The results site, for the tournaments in use (of the scope's hall, when
  there is one): `{tone, icon, text}`, or
  `nil` when none of them is on a results site (their games go to
  OpenPairings only, and that is not a fault).
  """
  def results(linked \\ nil, link \\ nil, scope \\ nil) do
    linked = linked || Seating.linked()
    link = link || Outbox.status()
    active = active(scope)
    published = Enum.filter(linked, &(&1.server_url != ""))
    keyless = Enum.filter(published, &(&1.relay_key == ""))

    own_sends? =
      Enum.any?(active, &(&1.kind == "local" and Tournaments.openresults_configured?(&1)))

    cond do
      keyless != [] ->
        {"warn", "warning", gettext("Results site: no relay key yet")}

      published == [] and not own_sends? ->
        nil

      not Destination.enabled?(OpenResults) ->
        {nil, "waiting", gettext("Results site: switched off")}

      true ->
        case link.state do
          :connected ->
            {"ok", "live", gettext("Results site: sending")}

          :offline ->
            {"warn", "offline",
             gettext("Results site: offline, %{count} waiting", count: link.pending)}

          :blocked ->
            {"bad", "out_of_sync", gettext("Results site: refused")}

          _idle when link.pending > 0 ->
            {nil, "waiting", gettext("Results site: %{count} waiting", count: link.pending)}

          _idle ->
            {"ok", "live", gettext("Results site: ready")}
        end
    end
  end

  @doc """
  Where one linked tournament's games stand on the results site, in a
  sentence: `{tone, text}`, with the action spelled out when there is one.
  """
  def results_line(%{server_url: ""}),
    do:
      {nil,
       gettext(
         "Not published on a results site: its moves go to OpenPairings only. Publish it there and the address arrives here by itself."
       )}

  def results_line(%{relay_key: ""}),
    do:
      {"warn",
       gettext(
         "No relay key yet: OpenPairings has none saved for this tournament, so nothing is sent to its results site. In OpenPairings: Settings > Live boards > The results site. The box starts sending by itself a few seconds after the key is there."
       )}

  def results_line(tournament) do
    {"ok",
     gettext("Sending to %{url}, %{slug}, key %{hint}. It came with the code.",
       url: tournament.server_url,
       slug: tournament.slug,
       hint: Tournaments.relay_key_hint(tournament)
     )}
  end

  @doc "How a code stands, with the last contact: `{tone, icon, text}`."
  def pairing_line(link) do
    {tone, icon, word} = LinkWords.state(link)
    {tone, icon, word}
  end
end

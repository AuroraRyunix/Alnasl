defmodule Alnasl.OpenPairings do
  @moduledoc """
  The box's half of the board link with OpenPairings
  (`docs/board-link-api.md` there is the contract).

  The box always calls; the pairing program never does. That is what lets
  it work through a hall's network to a hosted OpenPairings and, with no
  network at all, to a desktop copy on the same computer
  (`http://127.0.0.1:<port>`). Nothing here assumes https or a public name.

  ## What comes in

  A connect code (`add_code/1`) reaches one tournament or a group. Every few
  seconds the box asks what the code reaches (`poll/1`, with the `ETag` of
  the last answer, so "nothing new" costs almost nothing); a tournament
  whose version changed is fetched (`Alnasl.OpenPairings.Sync`): players,
  rounds, boards, colours, the rate of play, which round is on, and where
  its games go on the results site - address, short name and relay key, so
  nothing is typed on the box for that.

  A tournament added to a group later appears by itself. One that is no
  longer listed is marked `gone`: nothing is reported for it any more, and
  its games and boards stay until the arbiter removes it.

  ## What goes out

  Each game, to the tournament it came from: `Alnasl.Destination.OpenPairings`.

  ## When the code is refused

  A `401` is not retried: the code is wrong or was withdrawn, and asking
  again and again from the hall's address gets that address throttled. The
  link says so and waits for the arbiter (`retry/1`, or a new code).
  """

  import Ecto.Query

  alias Alnasl.{Boards, Log, Repo, Tournaments}
  alias Alnasl.OpenPairings.{Client, Code, Duplicates, Sync}
  alias Alnasl.Tournaments.{Link, Tournament}

  # --- codes -------------------------------------------------------------------

  @doc """
  Takes a connect code, asks the pairing program once, and keeps the code
  if it was not refused.

  - `{:ok, link, tournaments}` - it answered; the tournaments it reaches;
  - `{:pending, link, reason}` - nobody answered (or not sensibly): the
    code is kept and tried again by itself;
  - `{:error, reason}` - not kept: the text is not a code (`:empty`,
    `:no_secret`, `:not_an_address`), the box has it already (`:already`),
    the pairing program refused it (`:unauthorized`) or speaks another
    version of the link (`{:unsupported, api}`).

  The code, and every tournament it reaches, is in `hall_id` (the hall of
  the arbiter who added it; the box's own hall when nobody says).
  """
  def add_code(text, hall_id \\ nil) do
    with {:ok, code} <- Code.parse(text),
         nil <- Repo.get_by(Link, root: code.root, secret: code.secret) do
      link =
        Repo.insert!(%Link{
          root: code.root,
          secret: code.secret,
          kind: code.kind,
          hall_id: hall_id || Alnasl.Halls.own_id()
        })

      case poll(link, force: true) do
        {:ok, link} ->
          Log.add(:info, "link.added", %{server: Code.host(link.root)})
          {:ok, Repo.get!(Link, link.id), Tournaments.of_link(link)}

        {:error, :unauthorized} ->
          Repo.delete(link)
          {:error, :unauthorized}

        {:error, {:unsupported, _api} = reason} ->
          Repo.delete(link)
          {:error, reason}

        {:error, reason} ->
          Log.add(:warn, "link.added", %{server: Code.host(link.root), reason: inspect(reason)})
          {:pending, Repo.get!(Link, link.id), reason}
      end
    else
      %Link{} -> {:error, :already}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forgets a code, and with it the tournaments it reached
  (`Alnasl.Tournaments.remove/1`: their boards go back to the box's own
  tournament, their games are forgotten here, the PGN files stay).
  """
  def remove_link(%Link{} = link) do
    for tournament <- Tournaments.of_link(link), do: Tournaments.remove(tournament)
    Repo.delete(link)
    Log.add(:info, "link.removed", %{server: Code.host(link.root)})
    Tournaments.notify(nil)
    :ok
  end

  @doc """
  The arbiter says: the tournament with id `remote_id` there, which `link`
  reaches and the box has through another code, is asked through `link`
  from now on (`Alnasl.OpenPairings.Duplicates.use_code/2`). Then `link` is
  asked at once.
  """
  def use_code(%Link{} = link, remote_id) do
    with {:ok, tournament} <- Duplicates.use_code(link, remote_id) do
      poll(Repo.get!(Link, link.id), force: true)
      {:ok, Tournaments.get!(tournament.id)}
    end
  end

  @doc "The arbiter says: try this code again (after it was refused)."
  def retry(%Link{} = link) do
    link |> Ecto.Changeset.change(%{state: "new", etag: nil, error: nil}) |> Repo.update!()
    poll(Repo.get!(Link, link.id), force: true)
  end

  # --- asking ------------------------------------------------------------------

  @doc "Is this link asked by itself? Not one whose code was refused."
  def polled?(%Link{state: state}), do: state not in ["unauthorized", "unsupported"]

  @doc "Asks every link that is asked by itself. For tests, and for \"now\"."
  def poll_all do
    for link <- Tournaments.links(), polled?(link), do: poll(link)
    :ok
  end

  @doc """
  One round of the conversation with one link: what does the code reach,
  and for every tournament whose version the box does not hold, the
  tournament. `{:ok, link}` or `{:error, reason}` (the reasons of
  `Alnasl.OpenPairings.Client`, and `{:unsupported, api}`).

  `force: true` asks without the `ETag`, as if for the first time.
  """
  def poll(%Link{} = link, opts \\ []) do
    etag = if opts[:force], do: nil, else: link.etag
    now = DateTime.utc_now(:second)

    case Client.listing(link, etag) do
      {:ok, %{"api" => api}, _etag} when api != 1 ->
        fail(link, "unsupported", {:unsupported, api}, now)

      {:ok, listing, new_etag} ->
        link =
          link
          |> Ecto.Changeset.change(%{
            etag: new_etag,
            kind: listing["kind"] || link.kind,
            group_name: get_in(listing, ["group", "name"]),
            poll_seconds: poll_seconds(listing["poll_seconds"]),
            server_name: text(get_in(listing, ["server", "name"])),
            server_version: text(get_in(listing, ["server", "version"]))
          })
          |> Repo.update!()

        listed(link, listing["tournaments"])
        fetch_stale(link, now)

      :not_modified ->
        # A tournament that could not be fetched last time is still owed.
        fetch_stale(link, now)

      {:error, reason} ->
        fail(link, state_of(reason), reason, now)
    end
  end

  defp poll_seconds(n) when is_integer(n) and n >= 1 and n <= 3600, do: n
  defp poll_seconds(_other), do: 5

  defp text(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp text(_other), do: nil

  defp state_of(:unauthorized), do: "unauthorized"
  defp state_of(_other), do: "unreachable"

  defp fail(link, state, reason, now) do
    if link.state != state do
      data = %{server: Code.host(link.root), reason: inspect(reason)}

      case state do
        "unreachable" -> Log.add(:warn, "link.unreachable", data)
        "unsupported" -> Log.add(:error, "link.unsupported", data)
        _refused -> Log.add(:error, "link.unauthorized", data)
      end
    end

    link
    |> Ecto.Changeset.change(%{state: state, error: inspect(reason), last_try_at: now})
    |> Repo.update!()

    Tournaments.notify(nil)
    {:error, reason}
  end

  # The listing as it is now: new tournaments are added, the ones no longer
  # named are marked gone, and each remembers the version the listing gave.
  defp listed(%Link{} = link, entries) do
    held = Map.new(Tournaments.of_link(link), &{&1.remote_id, &1})
    entries = Enum.filter(entries, &(is_map(&1) and is_integer(&1["id"])))
    named = MapSet.new(entries, & &1["id"])

    elsewhere =
      Enum.reduce(entries, %{}, fn entry, elsewhere ->
        changes = %{
          name: entry["name"],
          label: entry["label"],
          state: entry["state"],
          listed_version: entry["version"],
          gone: false
        }

        case held[entry["id"]] || Duplicates.holder(link, entry) do
          nil ->
            tournament =
              %Tournament{
                kind: "linked",
                link_id: link.id,
                remote_id: entry["id"],
                hall_id: link.hall_id || Alnasl.Halls.own_id()
              }
              |> Tournament.changeset(changes)
              |> Repo.insert!()

            Log.add(:info, "tournament.added", %{tournament: Tournaments.title(tournament) || ""})
            Tournaments.notify(tournament.id)
            elsewhere

          # The box has it through another code: one row, not two.
          %Tournament{link_id: other, gone: false} = tournament when other != link.id ->
            Map.put(elsewhere, entry["id"], {tournament, entry["name"]})

          # ... which no longer lists it: it is asked through this one now.
          %Tournament{link_id: other} = tournament when other != link.id ->
            tournament |> Duplicates.adopt(link) |> Tournaments.update!(changes)
            elsewhere

          tournament ->
            if Map.take(tournament, Map.keys(changes)) != changes do
              if tournament.gone,
                do:
                  Log.add(:info, "tournament.back", %{
                    tournament: Tournaments.title(tournament) || ""
                  })

              Tournaments.update!(tournament, changes)
            end

            elsewhere
        end
      end)

    Duplicates.note(link, elsewhere)

    for {remote_id, tournament} <- held,
        not MapSet.member?(named, remote_id),
        not tournament.gone do
      gone(tournament)
    end

    :ok
  end

  # A code no longer reaches a tournament. When another code the box has
  # does, the row is asked through that one; else it is gone.
  defp gone(%Tournament{} = tournament) do
    case Duplicates.reclaim(tournament) do
      {:moved, _row} ->
        :ok

      nil ->
        Log.add(:warn, "tournament.gone", %{tournament: Tournaments.title(tournament) || ""})
        Tournaments.update!(tournament, %{gone: true})
    end
  end

  defp fetch_stale(%Link{} = link, now) do
    results =
      for tournament <- Tournaments.of_link(link),
          not tournament.gone,
          tournament.document == nil or tournament.version != tournament.listed_version do
        fetch(link, tournament)
      end

    was = link.state

    link =
      link
      |> Ecto.Changeset.change(%{state: "ok", error: nil, last_ok_at: now, last_try_at: now})
      |> Repo.update!()

    if was in ["unreachable", "unauthorized"],
      do: Log.add(:info, "link.ok", %{server: Code.host(link.root)})

    if was != "ok", do: Tournaments.notify(nil)

    case Enum.find(results, &match?({:error, _}, &1)) do
      # The listing was answered; a tournament that was not is owed, and
      # asked for again with the next poll.
      {:error, {:rate_limited, _wait} = reason} -> {:error, reason}
      _other -> {:ok, link}
    end
  end

  defp fetch(%Link{} = link, %Tournament{} = tournament) do
    case Client.tournament(link, tournament.remote_id) do
      {:ok, document} ->
        # Reached through two codes after all: one row, not two.
        case Duplicates.check_document(tournament, document) do
          {:apply, tournament} -> Sync.apply(tournament, document)
          :merged -> :ok
        end

        :ok

      :not_modified ->
        :ok

      {:error, :tournament_not_found} ->
        gone(tournament)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The box holds something about this tournament the pairing program has
  since changed (a report was answered `pairing_changed`): its document is
  owed again, at once.
  """
  def refetch(%Tournament{kind: "linked"} = tournament) do
    Tournaments.update!(tournament, %{version: nil})

    with %Link{} = link <- Tournaments.link_of(tournament) do
      link |> Ecto.Changeset.change(%{etag: nil}) |> Repo.update!()
    end

    Alnasl.OpenPairings.Poller.poll_now()
    :ok
  end

  def refetch(_other), do: :ok

  # --- what the box says about itself ------------------------------------------

  @doc "How many boards the box has given to each tournament of a link: `%{id there => count}`."
  def board_counts(%Link{} = link) do
    counts = Enum.frequencies_by(Boards.list(), & &1.tournament_id)

    for tournament <- Tournaments.of_link(link), not tournament.gone, into: %{} do
      {tournament.remote_id, Map.get(counts, tournament.id, 0)}
    end
  end

  @doc "Tells a link's pairing program the box's name, version and board counts."
  def tell(%Link{} = link), do: Client.box(link, board_counts(link))

  # --- testing a connection ----------------------------------------------------

  @doc """
  "Test connection" for one link: asks afresh, changes nothing, and says in
  steps what was found. `[{step, :ok | {:ok, found} | {:error, reason} |
  :skipped}]` for the steps `:server` (somebody answered at that address),
  `:code` (the code is taken) and `:tournaments` (`{:ok, [summary]}`, each
  `%{name, rounds, current_round, boards, openresults}` with `openresults`
  one of `:ok`, `:no_key` (published, but the arbiter has saved no relay
  key) or `:not_published`).
  """
  def test(%Link{} = link) do
    case Client.listing(link, nil) do
      {:ok, %{"api" => api}, _etag} when api != 1 ->
        [server: :ok, code: {:error, {:unsupported, api}}, tournaments: :skipped]

      {:ok, listing, _etag} ->
        summaries =
          for %{"id" => id} = entry <- listing["tournaments"] do
            case Client.tournament(link, id) do
              {:ok, document} -> summary(entry, document)
              {:error, reason} -> %{name: entry["name"], error: reason}
              :not_modified -> %{name: entry["name"], error: :not_the_api}
            end
          end

        [server: :ok, code: :ok, tournaments: {:ok, summaries}]

      {:error, :unauthorized} ->
        [server: :ok, code: {:error, :unauthorized}, tournaments: :skipped]

      {:error, {:rate_limited, _wait} = reason} ->
        [server: :ok, code: {:error, reason}, tournaments: :skipped]

      {:error, reason} ->
        [server: {:error, reason}, code: :skipped, tournaments: :skipped]

      :not_modified ->
        [server: {:error, :not_the_api}, code: :skipped, tournaments: :skipped]
    end
  end

  defp summary(entry, document) do
    current = document["current_round"]
    rounds = List.wrap(document["rounds"])
    round = Enum.find(rounds, &(&1["number"] == current)) || %{}

    %{
      name: entry["label"] || entry["name"],
      rounds: length(rounds),
      current_round: current,
      boards: Enum.count(List.wrap(round["boards"]), &(&1["kind"] == "game")),
      openresults:
        case document["openresults"] do
          %{"relay_key" => key} when is_binary(key) and key != "" -> :ok
          %{} -> :no_key
          _none -> :not_published
        end
    }
  end

  @doc "Games of linked tournaments carry a pairing flag: how many, for the badge."
  def flagged_count do
    Repo.aggregate(
      from(g in Alnasl.Games.Game, where: not is_nil(g.pairing_flag) and not g.local),
      :count
    )
  end
end

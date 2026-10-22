defmodule AlnaslWeb.FairPlayLive do
  @moduledoc """
  Fair play, the owner's pages (`docs/plan-fair-play.md`, section 7):

    * `:index` (`/fair-play`, its own place in the menu) - the halls the
      person owns, each with its switch, its engine and its reports; and
      the reports shared with them;
    * `:settings` (`/halls/:id/fair-play`) - the switch, the engine (download
      or choose a file), the credit, the hall's tournaments with a link to
      each report, PGN uploads, and sharing;
    * `:report` - one line per player, through a round or for that round
      only: a tournament's (`/fair-play/:tid`, `/fair-play/:tid/round/:round`)
      or an uploaded PGN's (`/fair-play/pgn/:uid`, `.../round/:round`). For
      the owner, also: who opened it, how long it is kept, who it is shared
      with, and - for a tournament - a round analysed on demand;
    * `:player` (`/fair-play/:tid/player?p=KEY`, `/fair-play/pgn/:uid/player?p=KEY`)
      - one player's numbers and the positions worth a look.

  **Only the hall's owner gets in** (`Alnasl.FairPlay.Access`), and to the
  reports and players' pages also whoever the owner shared them with
  (`Alnasl.FairPlay.Grants`), to look and nothing else. A page anyone else
  asks for answers as a page that is not there, and says nothing about
  whether the tournament, the upload or the hall exists. The check is made
  when the page is reached and again by every function that reads or
  changes fair-play data (`Alnasl.FairPlay`), and every event repeats it.
  Nothing of a report is rendered before the page is connected: the first,
  static render holds no data, so a request that never opens a socket sees
  nothing - and every opening that does see data is written in the audit
  (`Alnasl.FairPlay.record_view/4`).

  The page never says "cheating": it says what the numbers are and that
  they are not the method FIDE has approved.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{FairPlay, Halls, Tournaments}
  alias Alnasl.FairPlay.{Access, FalsePositives, Grants, Installer, Report, Selection}
  alias Alnasl.FairPlay.{Upload, Uploads}
  alias AlnaslWeb.Components.ManualLink

  @max_archive 400_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Fair play"))
     |> assign(
       fp_hall: nil,
       fp_subject: nil,
       fp_tournament: nil,
       fp_owner?: false,
       fp_data: nil,
       fp_error: nil,
       fp_installing: nil,
       fp_reload: false
     )
     |> assign(extend_form: to_form(%{"days" => "90", "reason" => ""}, as: :keep))
     |> assign(grant_form: to_form(%{"user_id" => "", "days" => "30"}, as: :grant))
     |> assign(pgn_form: to_form(%{"tournament_id" => "", "name" => ""}, as: :pgn))
     |> allow_upload(:archive,
       accept: ~w(.zip .gz),
       max_entries: 1,
       max_file_size: @max_archive
     )
     |> allow_upload(:pgn,
       accept: ~w(.pgn),
       max_entries: 1,
       max_file_size: Uploads.max_bytes()
     )}
  end

  # --- reaching a page ---------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index -> index(socket)
      :settings -> settings(params, socket)
      :report -> report(params, socket)
      :player -> player(params, socket)
    end
  end

  defp nothing_here(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("There is nothing at that address."))
     |> push_navigate(to: ~p"/")}
  end

  # The halls the scope owns, and what was shared with it. Somebody with
  # neither is told what anybody else is told: there is nothing here.
  defp index(socket) do
    scope = socket.assigns.current_scope
    shared = Grants.shared_with(scope)

    case {Access.halls(scope), shared} do
      {[], []} ->
        nothing_here(socket)

      {halls, shared} ->
        rows =
          for hall <- halls do
            {:ok, tournaments} = FairPlay.tournaments(scope, hall.id)
            {:ok, uploads} = Uploads.list(scope, hall.id)

            %{
              hall: hall,
              setting: FairPlay.settings(hall.id),
              tournaments: tournaments,
              uploads: uploads
            }
          end

        {:noreply,
         assign(socket,
           fp_rows: rows,
           fp_shared: shared,
           fp_problem: FairPlay.platform_problem(),
           page_title: gettext("Fair play")
         )}
    end
  end

  defp settings(params, socket) do
    scope = socket.assigns.current_scope

    with {id, ""} <- Integer.parse(params["id"] || ""),
         %{} = hall <- Halls.get(id),
         {:ok, tournaments} <- FairPlay.tournaments(scope, hall.id) do
      {:noreply,
       socket
       |> assign(
         fp_hall: hall,
         fp_setting: FairPlay.settings(hall.id),
         fp_tournaments: tournaments,
         fp_error: nil,
         fp_pgn_error: nil,
         fp_problem: FairPlay.platform_problem(),
         page_title: gettext("Fair play")
       )
       |> load_hall_sharing()}
    else
      _no -> nothing_here(socket)
    end
  end

  defp load_hall_sharing(socket) do
    %{current_scope: scope, fp_hall: hall} = socket.assigns

    with {:ok, uploads} <- Uploads.list(scope, hall.id),
         {:ok, grants} <- Grants.list(scope, hall.id),
         {:ok, people} <- Grants.candidates(scope, hall.id),
         {:ok, audit} <- FairPlay.hall_audit(scope, hall.id) do
      assign(socket,
        fp_uploads: uploads,
        fp_grants: grants,
        fp_people: people,
        fp_hall_audit: audit,
        fp_titles: titles(grants)
      )
    else
      _no -> assign(socket, fp_uploads: [], fp_grants: [], fp_people: [], fp_hall_audit: [])
    end
  end

  # The report's subject from the address: a tournament (`tid`) or an
  # uploaded PGN (`uid`).
  defp subject(scope, params) do
    cond do
      params["uid"] ->
        with {uid, ""} <- Integer.parse(params["uid"]), do: Uploads.get(scope, uid)

      params["tid"] ->
        with {tid, ""} <- Integer.parse(params["tid"]), do: FairPlay.tournament(scope, tid)

      true ->
        {:error, :forbidden}
    end
  end

  defp report(params, socket) do
    scope = socket.assigns.current_scope

    case subject(scope, params) do
      {:ok, subject} ->
        socket =
          socket
          |> assign_subject(subject)
          |> assign(
            fp_round: int(params["round"]),
            fp_only?: params["only"] == "1",
            fp_data: nil,
            page_title: gettext("Fair play")
          )

        {:noreply, if(connected?(socket), do: load_report(socket, true), else: socket)}

      _no ->
        nothing_here(socket)
    end
  end

  defp player(params, socket) do
    scope = socket.assigns.current_scope

    with {:ok, subject} <- subject(scope, params),
         key when is_binary(key) and key != "" <- params["p"] do
      socket =
        socket
        |> assign_subject(subject)
        |> assign(
          fp_round: int(params["round"]),
          fp_only?: params["only"] == "1",
          fp_player_key: key,
          fp_data: nil,
          page_title: gettext("Fair play")
        )

      {:noreply, if(connected?(socket), do: load_player(socket), else: socket)}
    else
      _no -> nothing_here(socket)
    end
  end

  defp assign_subject(socket, subject) do
    scope = socket.assigns.current_scope

    if connected?(socket) and match?(%Upload{}, subject) and
         socket.assigns.fp_subject != subject do
      Phoenix.PubSub.subscribe(Alnasl.PubSub, Uploads.topic(subject.id))
    end

    assign(socket,
      fp_subject: subject,
      fp_tournament: match?(%Tournaments.Tournament{}, subject) && subject,
      fp_owner?: FairPlay.owner_of?(scope, subject)
    )
  end

  defp int(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> n
      _other -> nil
    end
  end

  defp int(_none), do: nil

  # --- loading what is shown ---------------------------------------------------

  # `record?`: write the opening in the audit. A reload because an upload
  # moved on is not somebody opening the page again.
  defp load_report(socket, record?) do
    %{current_scope: scope, fp_subject: subject} = socket.assigns

    with {:ok, rounds} <- FairPlay.rounds(scope, subject),
         round = socket.assigns.fp_round || List.last(rounds),
         {:ok, rows} <- FairPlay.moves(scope, subject, filter(socket, round)),
         {:ok, _view} <-
           if(record?, do: FairPlay.record_view(scope, subject, round, nil), else: {:ok, nil}) do
      setting = FairPlay.settings(FairPlay.hall_of(subject))
      model = Report.model(setting)

      data = %{
        rounds: rounds,
        round: round,
        players: Report.build(rows, model),
        model: model,
        calibrated?: model != nil,
        setting: setting,
        upload: upload_info(scope, subject)
      }

      assign(socket, fp_data: Map.merge(data, owner_data(socket, subject)))
    else
      {:error, :forbidden} -> assign(socket, fp_data: nil)
    end
  end

  defp upload_info(scope, %Upload{} = upload) do
    {:ok, progress} = Uploads.progress(scope, upload)

    %{
      progress: progress,
      problems: Upload.problems(upload),
      tournament: upload.tournament_id && Tournaments.get(upload.tournament_id)
    }
  end

  defp upload_info(_scope, _tournament), do: nil

  # What only the owner sees: who looked, how long it is kept, who it is
  # shared with, the rounds that can be analysed again.
  defp owner_data(%{assigns: %{fp_owner?: true}} = socket, subject) do
    scope = socket.assigns.current_scope
    hall_id = FairPlay.hall_of(subject)
    {:ok, views} = FairPlay.views(scope, subject)
    {:ok, keep} = FairPlay.keep(scope, subject)
    {:ok, grants} = Grants.list(scope, hall_id, subject)

    snapshots =
      case subject do
        %Tournaments.Tournament{} -> elem(FairPlay.snapshots(scope, subject), 1)
        _upload -> []
      end

    {:ok, people} = Grants.candidates(scope, hall_id)

    played =
      case subject do
        %Tournaments.Tournament{} -> elem(FairPlay.played_rounds(scope, subject), 1)
        _upload -> []
      end

    %{
      views: views,
      snapshots: snapshots,
      keep: keep,
      grants: grants,
      people: people,
      titles: titles(grants),
      played_rounds: played,
      last_round_end: last_round_end(subject)
    }
  end

  defp owner_data(_socket, _subject), do: %{}

  defp last_round_end(%Tournaments.Tournament{id: id}),
    do: Alnasl.FairPlay.Retention.last_round_end(id)

  defp last_round_end(%Upload{inserted_at: at}), do: at

  defp load_player(socket) do
    %{current_scope: scope, fp_subject: subject, fp_player_key: key} = socket.assigns

    with {:ok, rounds} <- FairPlay.rounds(scope, subject),
         round = socket.assigns.fp_round || List.last(rounds),
         {:ok, rows} <- FairPlay.moves(scope, subject, filter(socket, round)),
         {:ok, _view} <- FairPlay.record_view(scope, subject, round, key) do
      setting = FairPlay.settings(FairPlay.hall_of(subject))
      model = Report.model(setting)
      opponents = Report.opponent_ratings(rows)
      rows = Enum.filter(rows, &(&1.player_key == key))

      line =
        if rows == [],
          do: nil,
          else: Report.player(key, rows, model, opponents)

      assign(socket,
        fp_data: %{
          round: round,
          line: line,
          model: model,
          calibrated?: model != nil,
          positions: Report.key_positions(rows)
        }
      )
    else
      {:error, :forbidden} -> assign(socket, fp_data: nil)
    end
  end

  defp filter(socket, round) do
    cond do
      round == nil -> []
      socket.assigns.fp_only? -> [only: round]
      true -> [through: round]
    end
  end

  # The names of the reports grants are about.
  defp titles(grants) do
    Map.new(grants, fn g ->
      title =
        case Alnasl.FairPlay.Grant.subject(g) do
          :hall -> gettext("all reports of the hall")
          {:tournament, id} -> id |> Tournaments.get() |> then(&(&1 && tournament_title(&1)))
          {:upload, id} -> upload_name(id)
        end

      {g.id, title || gettext("a report that is gone")}
    end)
  end

  defp upload_name(id) do
    case Alnasl.Repo.get(Upload, id) do
      %Upload{name: name} -> name
      nil -> nil
    end
  end

  # --- messages ----------------------------------------------------------------

  # An upload's game was analysed: draw the report again, at most every
  # two seconds, however fast the games come.
  @impl true
  def handle_info({:fair_play_upload, _id}, socket) do
    if socket.assigns.fp_reload or socket.assigns.live_action != :report do
      {:noreply, socket}
    else
      Process.send_after(self(), :fp_reload, 2_000)
      {:noreply, assign(socket, fp_reload: true)}
    end
  end

  def handle_info(:fp_reload, socket) do
    {:noreply, socket |> assign(fp_reload: false) |> load_report(false)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- events ------------------------------------------------------------------

  # Every event of the settings page asks the hall's owner again.
  defp owner?(socket) do
    case socket.assigns do
      %{fp_hall: %{id: id}, current_scope: scope} -> Access.owner?(scope, id)
      _no -> false
    end
  end

  @impl true
  def handle_event("toggle", %{"enabled" => enabled}, socket) do
    with true <- owner?(socket),
         {:ok, setting} <-
           FairPlay.set_enabled(
             socket.assigns.current_scope,
             socket.assigns.fp_hall.id,
             enabled == "true"
           ) do
      {:noreply, assign(socket, fp_setting: setting)}
    else
      _no -> {:noreply, refuse(socket)}
    end
  end

  def handle_event("download", _params, socket) do
    install(socket, :download)
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}
  def handle_event("validate_pgn", _params, socket), do: {:noreply, socket}

  def handle_event("install_file", _params, socket) do
    if owner?(socket) do
      dir = Path.join(System.tmp_dir!(), "alnasl-fair-play")
      File.mkdir_p!(dir)

      results =
        consume_uploaded_entries(socket, :archive, fn %{path: path}, _entry ->
          dest = Path.join(dir, "upload-#{System.unique_integer([:positive])}.part")
          File.cp!(path, dest)
          {:ok, dest}
        end)

      case results do
        [dest] -> install(socket, {:file, dest})
        [] -> {:noreply, assign(socket, fp_error: gettext("Choose the file first."))}
      end
    else
      {:noreply, refuse(socket)}
    end
  end

  def handle_event("upload_pgn", params, socket) do
    if owner?(socket) do
      fields = params["pgn"] || %{}

      results =
        consume_uploaded_entries(socket, :pgn, fn %{path: path}, entry ->
          {:ok, {File.read!(path), entry.client_name}}
        end)

      case results do
        [{bytes, filename}] ->
          attrs = %{
            bytes: bytes,
            filename: filename,
            name: fields["name"],
            tournament_id: int(fields["tournament_id"])
          }

          case Uploads.create(socket.assigns.current_scope, socket.assigns.fp_hall.id, attrs) do
            {:ok, upload} ->
              {:noreply,
               socket
               |> put_flash(:info, gettext("Uploaded. The games are analysed in the background."))
               |> push_navigate(to: ~p"/fair-play/pgn/#{upload.id}")}

            {:error, :forbidden} ->
              {:noreply, refuse(socket)}

            {:error, reason} ->
              {:noreply, assign(socket, fp_pgn_error: pgn_message(reason))}
          end

        [] ->
          {:noreply, assign(socket, fp_pgn_error: gettext("Choose the file first."))}
      end
    else
      {:noreply, refuse(socket)}
    end
  end

  def handle_event("grant", %{"grant" => fields}, socket) do
    scope = socket.assigns.current_scope

    subject =
      case {socket.assigns.fp_hall, socket.assigns.fp_subject} do
        {%{id: hall_id}, _} -> {:hall, hall_id}
        {nil, subject} when subject != nil -> subject
      end

    case Grants.grant(scope, subject, int(fields["user_id"]) || 0, int(fields["days"]) || 0) do
      {:ok, _grant} ->
        {:noreply, socket |> put_flash(:info, gettext("Shared.")) |> reload()}

      {:error, :forbidden} ->
        {:noreply, refuse(socket)}

      {:error, :days} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Between 1 and %{max} days.", max: Grants.max_days())
         )}

      {:error, :not_member} ->
        {:noreply, put_flash(socket, :error, gettext("Choose one of the hall's people."))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Grants.revoke(socket.assigns.current_scope, int(id) || 0) do
      {:ok, _grant} ->
        {:noreply, socket |> put_flash(:info, gettext("No longer shared.")) |> reload()}

      {:error, _} ->
        {:noreply, refuse(socket)}
    end
  end

  def handle_event("analyse_round", %{"round" => round}, socket) do
    with %Tournaments.Tournament{} = tournament <- socket.assigns.fp_tournament,
         round when is_integer(round) <- int(round) do
      case FairPlay.analyse_round(socket.assigns.current_scope, tournament, round) do
        {:ok, n} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             ngettext(
               "Round %{round}: one game queued. Moves already analysed with this engine stay as they are.",
               "Round %{round}: %{count} games queued. Moves already analysed with this engine stay as they are.",
               n,
               round: round
             )
           )
           |> reload()}

        {:error, :not_working} ->
          {:noreply, put_flash(socket, :error, not_working_message())}

        {:error, :forbidden} ->
          {:noreply, refuse(socket)}
      end
    else
      _no -> {:noreply, refuse(socket)}
    end
  end

  def handle_event("requeue_upload", _params, socket) do
    with %Upload{} = upload <- socket.assigns.fp_subject,
         {:ok, n} <- Uploads.requeue(socket.assigns.current_scope, upload) do
      {:noreply,
       put_flash(
         socket,
         :info,
         ngettext("One game queued.", "%{count} games queued.", n)
       )}
    else
      {:error, :not_working} -> {:noreply, put_flash(socket, :error, not_working_message())}
      _no -> {:noreply, refuse(socket)}
    end
  end

  def handle_event("delete_analysis", params, socket) do
    scope = socket.assigns.current_scope
    reason = get_in(params, ["delete", "reason"])

    with %Tournaments.Tournament{} = tournament <- socket.assigns.fp_subject,
         {:ok, _snapshot} <- FairPlay.delete_analysis(scope, tournament, reason) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("The analysis is deleted. A frozen copy of the report is kept below.")
       )
       |> reload()}
    else
      {:error, :nothing} ->
        {:noreply, put_flash(socket, :error, gettext("There is no analysis to delete."))}

      _no ->
        {:noreply, refuse(socket)}
    end
  end

  def handle_event("delete_upload", _params, socket) do
    with %Upload{} = upload <- socket.assigns.fp_subject,
         :ok <- Uploads.delete(socket.assigns.current_scope, upload) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("The upload and its analysis are deleted."))
       |> push_navigate(to: ~p"/halls/#{upload.hall_id}/fair-play")}
    else
      _no -> {:noreply, refuse(socket)}
    end
  end

  def handle_event("extend", %{"keep" => %{"days" => days, "reason" => reason}}, socket) do
    scope = socket.assigns.current_scope
    subject = socket.assigns.fp_subject

    case subject && FairPlay.extend(scope, subject, int(days) || 0, reason) do
      {:ok, _keep} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Kept for longer."))
         |> reload()}

      {:error, :forbidden} ->
        {:noreply, refuse(socket)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, extend_message(error))}

      nil ->
        {:noreply, refuse(socket)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp reload(socket) do
    case socket.assigns.live_action do
      :settings -> load_hall_sharing(socket)
      :report -> load_report(socket, false)
      _other -> socket
    end
  end

  defp refuse(socket),
    do: put_flash(socket, :error, gettext("There is nothing at that address."))

  defp extend_message(:reason),
    do: gettext("Say why: a reason is needed to keep the analysis longer.")

  defp extend_message(:too_long),
    do: gettext("At most 365 days after the tournament's last round.")

  defp extend_message(:days), do: gettext("Give a number of days.")

  defp extend_message(:no_rounds),
    do: gettext("This tournament has no games yet, so there is no last round to count from.")

  defp extend_message(:attached),
    do: gettext("These games belong to a tournament and are kept as long as it is.")

  defp not_working_message,
    do: gettext("Fair play is off in this hall, or has no engine. Switch it on in the settings.")

  defp pgn_message(:not_working), do: not_working_message()

  defp pgn_message(:too_big),
    do:
      gettext("The file is larger than %{mb} MB. Split it and upload the parts.",
        mb: div(Uploads.max_bytes(), 1_000_000)
      )

  defp pgn_message(:binary),
    do: gettext("That is not a PGN file: it is not text. A zipped PGN must be unpacked first.")

  defp pgn_message(:no_games), do: gettext("There are no games with moves in that file.")

  defp pgn_message({:too_many, n}),
    do:
      gettext("The file has %{count} games; at most %{max} at a time.",
        count: n,
        max: Uploads.max_games()
      )

  defp pgn_message({:already, upload}),
    do: gettext("This file was uploaded before, as \"%{name}\".", name: upload.name)

  defp pgn_message(:tournament), do: gettext("Choose one of this hall's tournaments.")

  defp install(socket, source) do
    if owner?(socket) do
      scope = socket.assigns.current_scope
      hall_id = socket.assigns.fp_hall.id
      options = FairPlay.install_options()

      {:noreply,
       socket
       |> assign(fp_installing: source_kind(source), fp_error: nil)
       |> start_async(:install, fn ->
         result = FairPlay.install(scope, hall_id, source, options)
         with {:file, path} <- source, do: File.rm(path)
         result
       end)}
    else
      {:noreply, refuse(socket)}
    end
  end

  defp source_kind(:download), do: :download
  defp source_kind({:file, _path}), do: :file

  @impl true
  def handle_async(:install, {:ok, {:ok, setting}}, socket) do
    {:noreply,
     socket
     |> assign(fp_setting: setting, fp_installing: nil, fp_error: nil)
     |> put_flash(:info, gettext("The engine is installed."))}
  end

  def handle_async(:install, {:ok, {:error, :forbidden}}, socket),
    do: {:noreply, socket |> assign(fp_installing: nil) |> refuse()}

  def handle_async(:install, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, fp_installing: nil, fp_error: Installer.message(reason))}

  def handle_async(:install, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       fp_installing: nil,
       fp_error: gettext("The installation stopped unexpectedly. Try again.")
     )}
  end

  # --- words -------------------------------------------------------------------

  defp skip_label(:unrated), do: gettext("no rating")
  defp skip_label(:low_rating), do: gettext("rating under 1000")
  defp skip_label(:tracker_guessed), do: gettext("guessed by the tracker")
  defp skip_label(:tracker_rewritten), do: gettext("rewritten, result not yet confirmed")
  defp skip_label(:opening), do: gettext("opening (moves 1 to 8)")
  defp skip_label(:repetition), do: gettext("repeated position")
  defp skip_label(:forced), do: gettext("forced move")
  defp skip_label(:time_trouble), do: gettext("under a minute on the clock")
  defp skip_label(:decided), do: gettext("decided position")
  defp skip_label(:no_analysis), do: gettext("not analysed")

  defp skips(skipped) do
    for reason <- Selection.reasons(), n = Map.get(skipped, reason), n != nil, do: {reason, n}
  end

  defp percent(nil), do: "-"
  defp percent(share), do: "#{:erlang.float_to_binary(share * 100, decimals: 1)}%"

  defp loss(nil), do: "-"
  defp loss(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp score(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp interval(nil), do: ""

  defp interval({low, high}),
    do:
      "(#{:erlang.float_to_binary(low, decimals: 1)} .. #{:erlang.float_to_binary(high, decimals: 1)})"

  defp verdict_label(:closer_look), do: gettext("worth a closer look")
  defp verdict_label(:very_unusual), do: gettext("statistically very unusual")

  defp reason_label(:uncalibrated),
    do: gettext("no score until the engine is calibrated")

  defp reason_label(:too_few_moves), do: gettext("too few moves")
  defp reason_label(nil), do: ""

  # What the held-out games say about a score this high.
  defp rarity(model, score) do
    case FalsePositives.describe(model, score) do
      nil ->
        nil

      :uncalibrated ->
        gettext("not calibrated")

      :not_measured ->
        gettext("false-positive rate not measured for this calibration")

      %{one_in: nil, low_one_in: n, events: events, threshold: t} ->
        gettext(
          "none of %{events} normal player-events scored %{threshold} or more: fewer than about 1 in %{n}",
          events: number(events),
          threshold: threshold(t),
          n: number(n)
        )

      %{one_in: n, low_one_in: low, high_one_in: high, threshold: t} ->
        gettext(
          "about 1 in %{n} normal player-events scores %{threshold} or more (1 in %{low} to 1 in %{high})",
          n: number(n),
          low: number(low),
          high: number(high),
          threshold: threshold(t)
        )
    end
  end

  defp threshold(t), do: :erlang.float_to_binary(t / 1, decimals: 1)

  defp number(nil), do: "-"

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp tournament_title(tournament),
    do: Tournaments.title(tournament) || gettext("Tournament %{id}", id: tournament.id)

  defp subject_title(%Upload{name: name}), do: name
  defp subject_title(tournament), do: tournament_title(tournament)

  defp colour_label(:white), do: gettext("White")
  defp colour_label(:black), do: gettext("Black")

  defp base_path(%Upload{id: id}), do: "/fair-play/pgn/#{id}"
  defp base_path(%{id: id}), do: "/fair-play/#{id}"

  defp round_path(subject, round, only?) do
    base = base_path(subject) <> "/round/#{round}"
    if only?, do: base <> "?only=1", else: base
  end

  defp player_path(subject, key, round, only?) do
    query =
      [p: key] ++ if(round, do: [round: round], else: []) ++ if(only?, do: [only: 1], else: [])

    base_path(subject) <> "/player?" <> URI.encode_query(query)
  end

  defp round_label(0), do: "?"
  defp round_label(round), do: Integer.to_string(round)

  defp time(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp day(at), do: Calendar.strftime(at, "%Y-%m-%d")

  defp grant_state(grant) do
    now = DateTime.utc_now()

    cond do
      grant.revoked_at -> :revoked
      DateTime.compare(grant.expires_at, now) != :gt -> :expired
      true -> :active
    end
  end

  defp action_label("view"), do: gettext("opened")
  defp action_label("grant"), do: gettext("shared")
  defp action_label("revoke"), do: gettext("stopped sharing")
  defp action_label("upload"), do: gettext("uploaded")
  defp action_label("delete_upload"), do: gettext("deleted an upload")
  defp action_label("analyse_round"), do: gettext("had a round analysed")
  defp action_label("delete_analysis"), do: gettext("deleted the analysis")
  defp action_label(other), do: other

  defp problem_text(%{"kind" => "illegal", "detail" => detail}),
    do: gettext("refused: an illegal move, %{move}", move: detail)

  defp problem_text(%{"kind" => "position", "detail" => detail}),
    do: gettext("refused: the starting position cannot be read (%{why})", why: detail)

  defp problem_text(%{"kind" => "variant", "detail" => detail}),
    do: gettext("refused: not standard chess (%{variant})", variant: detail)

  defp problem_text(%{"kind" => "repeated", "detail" => detail}),
    do: gettext("refused: the same game as game %{n}", n: detail)

  defp problem_text(%{"kind" => "on_the_boards"}),
    do: gettext("not analysed again: the boards recorded this game")

  defp problem_text(%{"kind" => "unrated", "detail" => "both"}),
    do: gettext("no ratings in the file: neither player's moves count")

  defp problem_text(%{"kind" => "unrated", "detail" => "white"}),
    do: gettext("no rating for White in the file: White's moves do not count")

  defp problem_text(%{"kind" => "unrated", "detail" => "black"}),
    do: gettext("no rating for Black in the file: Black's moves do not count")

  defp problem_text(_other), do: gettext("a problem")

  defp people_options(people), do: Enum.map(people, &{&1.email, &1.id})

  defp tournament_options(tournaments),
    do:
      [{gettext("None: a report of its own"), ""}] ++
        Enum.map(tournaments, &{tournament_title(&1), &1.id})

  # --- rendering ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:fair_play}
      help={:fair_play}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Fair play")}
    >
      <%= case @live_action do %>
        <% :index -> %>
          <.index_page {assigns} />
        <% :settings -> %>
          <.settings_page {assigns} />
        <% :report -> %>
          <.report_page {assigns} />
        <% :player -> %>
          <.player_page {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  defp not_fide(assigns) do
    ~H"""
    <p id="fair-play-not-fide" class="note">
      <.badge tone="warn" icon="warning">{gettext("Screening, not evidence")}</.badge>
      {gettext(
        "This is not the method FIDE has approved (FIDE Fair Play Regulations 2024, Art. 1.6): it is a reason to look closer, nothing more. What to do with a high number is in the manual."
      )}
      <a id="fair-play-manual" href={ManualLink.path(:fair_play)} target="_blank" rel="noopener">
        {gettext("Read the manual section")}
      </a>
    </p>
    """
  end

  # --- the halls ---------------------------------------------------------------

  defp index_page(assigns) do
    ~H"""
    <div :if={assigns[:fp_rows]} class="stack" id="fair-play-index">
      <p :if={@fp_rows != []} class="note">
        {gettext("Fair play is the owner's of a hall and nobody else's. These are the halls you own.")}
      </p>

      <p :if={@fp_problem} id="fair-play-problem" class="error" role="alert">
        {platform_text(@fp_problem)}
      </p>

      <.panel
        :for={row <- @fp_rows}
        id={"fair-play-hall-#{row.hall.id}"}
        title={row.hall.name}
      >
        <:actions>
          <.button
            id={"fair-play-settings-#{row.hall.id}"}
            small
            navigate={~p"/halls/#{row.hall.id}/fair-play"}
          >
            {gettext("Settings")}
          </.button>
        </:actions>
        <div class="stack">
          <p id={"fair-play-hall-status-#{row.hall.id}"}>
            <%= if row.setting.enabled do %>
              <.badge tone="ok" icon="ok">{gettext("On")}</.badge>
            <% else %>
              <.badge tone="warn" icon="waiting">{gettext("Off")}</.badge>
            <% end %>
            <%= if installed?(row.setting) do %>
              <.badge tone="ok" icon="ok">{gettext("Engine installed")}</.badge>
            <% else %>
              <.badge tone="warn" icon="warning">{gettext("Engine not installed")}</.badge>
            <% end %>
          </p>
          <p :if={row.tournaments == [] and row.uploads == []} class="note">
            {gettext("This hall has no tournaments yet.")}
          </p>
          <ul :if={row.tournaments != [] or row.uploads != []} class="tight-list">
            <li :for={t <- row.tournaments} id={"fair-play-hall-#{row.hall.id}-report-#{t.id}"}>
              <.link navigate={~p"/fair-play/#{t.id}"}>{tournament_title(t)}</.link>
            </li>
            <li :for={u <- row.uploads} id={"fair-play-hall-#{row.hall.id}-upload-#{u.id}"}>
              <.link navigate={~p"/fair-play/pgn/#{u.id}"}>{u.name}</.link>
              <span class="note">{gettext("uploaded PGN")}</span>
            </li>
          </ul>
        </div>
      </.panel>

      <.panel :if={@fp_shared != []} id="fair-play-shared" title={gettext("Shared with you")}>
        <p class="note">
          {gettext(
            "The owners of these halls let you see these reports, until the date shown. You can look; you cannot change anything, and you cannot share them further."
          )}
        </p>
        <ul class="tight-list">
          <li :for={s <- @fp_shared} id={"fair-play-shared-#{s.grant.id}"}>
            <%= case s.subject do %>
              <% :hall -> %>
                {gettext("All reports of %{hall}", hall: s.hall && s.hall.name)}
              <% %Upload{} = u -> %>
                <.link navigate={~p"/fair-play/pgn/#{u.id}"}>{u.name}</.link>
              <% t -> %>
                <.link navigate={~p"/fair-play/#{t.id}"}>{tournament_title(t)}</.link>
            <% end %>
            <span class="note">{gettext("until %{date}", date: day(s.grant.expires_at))}</span>
            <ul :if={s.subject == :hall} class="tight-list">
              <li :for={r <- hall_reports(@current_scope, s.hall)}>
                <.link navigate={base_path(r)}>{subject_title(r)}</.link>
              </li>
            </ul>
          </li>
        </ul>
      </.panel>

      <.not_fide />
    </div>
    """
  end

  # The reports of a hall shared whole.
  defp hall_reports(_scope, nil), do: []

  defp hall_reports(scope, hall) do
    with {:ok, tournaments} <- FairPlay.shared_tournaments(scope, hall.id),
         {:ok, uploads} <- Uploads.list(scope, hall.id) do
      tournaments ++ uploads
    else
      _no -> []
    end
  end

  # --- settings ----------------------------------------------------------------

  defp settings_page(assigns) do
    ~H"""
    <div :if={@fp_hall} class="stack" id="fair-play-settings">
      <p class="note">
        <.link navigate={~p"/halls/#{@fp_hall.id}"} id="fair-play-back">
          {gettext("Back to %{hall}", hall: @fp_hall.name)}
        </.link>
      </p>

      <.panel id="fair-play-switch-panel" title={gettext("Fair play")}>
        <div class="stack">
          <p>
            {gettext(
              "Alnasl can check the games its boards record against a strong chess engine, and show you, as the owner of this hall and nobody else, which players' moves matched it more often than their rating predicts. It is off until you switch it on."
            )}
          </p>
          <%!-- A switch, not a checkbox: it does something the moment it is
               touched. Turning it off asks first, because the moves played
               while it is off are not analysed unless somebody remembers to
               ask for the round later. --%>
          <div class="switch-row" id="fair-play-switch">
            <button
              type="button"
              id="fair-play-enabled"
              class={["switch", @fp_setting.enabled && "is-on"]}
              role="switch"
              aria-checked={to_string(@fp_setting.enabled)}
              aria-labelledby="fair-play-switch-label"
              aria-describedby="fair-play-switch-hint"
              phx-click="toggle"
              phx-value-enabled={to_string(not @fp_setting.enabled)}
              data-confirm={
                @fp_setting.enabled &&
                  gettext(
                    "Switch fair play off? From now on this hall's moves are not analysed. The reports made so far stay, and a round played while it was off can still be analysed later, on demand."
                  )
              }
            >
              <span class="switch-track" aria-hidden="true"><span class="switch-knob"></span></span>
              <span class="switch-state">
                {if @fp_setting.enabled, do: gettext("On"), else: gettext("Off")}
              </span>
            </button>
            <div>
              <span id="fair-play-switch-label" class="switch-label">{gettext("Fair play")}</span>
              <span id="fair-play-switch-hint" class="hint own-line">
                {gettext("Analyses the moves of this hall's games as they are played.")}
              </span>
            </div>
          </div>
          <p
            :if={@fp_setting.enabled and not installed?(@fp_setting)}
            id="fair-play-needs-engine"
            class="note"
          >
            {gettext("It is on, and does nothing until an engine is installed (below).")}
          </p>
        </div>
      </.panel>

      <.panel id="fair-play-engine" title={gettext("Engine")}>
        <div class="stack">
          <p id="fair-play-engine-status">
            <%= cond do %>
              <% @fp_installing == :download -> %>
                <.badge tone="warn" icon="settling">{gettext("Downloading")}</.badge>
                {gettext("Fetching Stockfish 19 and checking it. This takes a minute.")}
              <% @fp_installing == :file -> %>
                <.badge tone="warn" icon="settling">{gettext("Installing")}</.badge>
                {gettext("Checking the file. This takes a minute.")}
              <% installed?(@fp_setting) -> %>
                <.badge tone="ok" icon="ok">{gettext("Installed")}</.badge>
                {gettext("Stockfish %{version}, bench %{bench}",
                  version: @fp_setting.engine_version,
                  bench: @fp_setting.engine_bench
                )}
              <% true -> %>
                <.badge tone="warn" icon="warning">{gettext("Not installed")}</.badge>
            <% end %>
          </p>

          <p :if={@fp_error} id="fair-play-error" class="error" role="alert">{@fp_error}</p>

          <p :if={@fp_problem} id="fair-play-problem" class="error" role="alert">
            {platform_text(@fp_problem)}
          </p>

          <div :if={!@fp_problem} class="row">
            <.button
              id="fair-play-download"
              phx-click="download"
              disabled={@fp_installing != nil}
            >
              {gettext("Download Stockfish 19")}
            </.button>
          </div>

          <.form
            :if={!@fp_problem}
            for={%{}}
            id="fair-play-upload"
            phx-submit="install_file"
            phx-change="validate_upload"
            class="stack"
          >
            <p class="note">
              {gettext(
                "No internet in the hall? Download the file for this computer on another one and choose it here: stockfish-windows-x86-64-universal.zip, stockfish-macos-universal.tar.gz or stockfish-linux-x86-64-universal.tar.gz, from the Stockfish 19 release on GitHub. It must be the official file; Alnasl checks it."
              )}
            </p>
            <div class="row">
              <.live_file_input upload={@uploads.archive} />
              <.button id="fair-play-install-file" type="submit" disabled={@fp_installing != nil}>
                {gettext("Choose a file")}
              </.button>
            </div>
            <p
              :for={entry <- @uploads.archive.entries}
              class="note"
              id={"fair-play-entry-#{entry.ref}"}
            >
              {entry.client_name} ({entry.progress}%)
            </p>
          </.form>

          <p id="fair-play-credit" class="note">
            {gettext(
              "Uses Stockfish (GPL-3.0), stockfishchess.org, downloaded from the official release."
            )}
          </p>
        </div>
      </.panel>

      <.panel id="fair-play-tournaments" title={gettext("Reports")} flush>
        <%= if @fp_tournaments == [] do %>
          <p id="fair-play-no-tournaments" class="note">
            {gettext("This hall has no tournaments yet.")}
          </p>
        <% else %>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>{gettext("Tournament")}</th>
                  <th><span class="sr-only">{gettext("Actions")}</span></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- @fp_tournaments} id={"fair-play-tournament-#{t.id}"}>
                  <td>{tournament_title(t)}</td>
                  <td class="act">
                    <.button
                      id={"fair-play-open-#{t.id}"}
                      small
                      navigate={~p"/fair-play/#{t.id}"}
                    >
                      {gettext("Open report")}
                    </.button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </.panel>

      <.panel id="fair-play-pgn" title={gettext("Games from a PGN file")}>
        <div class="stack">
          <p class="note">
            {gettext(
              "Games played without the boards, or a whole event: upload them as a PGN file and they are screened like the games the boards record. The ratings come from the WhiteElo and BlackElo tags; a player without one is not scored. The file is read once and not kept; its games and their analysis are kept as long as a tournament's would be."
            )}
          </p>
          <p
            :if={not FairPlay.working?(@fp_setting)}
            id="fair-play-pgn-off"
            class="note"
          >
            {not_working_message()}
          </p>
          <p :if={@fp_pgn_error} id="fair-play-pgn-error" class="error" role="alert">
            {@fp_pgn_error}
          </p>
          <.form
            :if={FairPlay.working?(@fp_setting)}
            for={@pgn_form}
            id="fair-play-pgn-form"
            phx-submit="upload_pgn"
            phx-change="validate_pgn"
            class="stack"
          >
            <.live_file_input upload={@uploads.pgn} />
            <p
              :for={entry <- @uploads.pgn.entries}
              class="note"
              id={"fair-play-pgn-entry-#{entry.ref}"}
            >
              {entry.client_name} ({entry.progress}%)
              <span :for={err <- upload_errors(@uploads.pgn, entry)} class="error">
                {upload_error(err)}
              </span>
            </p>
            <.input
              field={@pgn_form[:tournament_id]}
              type="select"
              label={gettext("Part of a tournament")}
              options={tournament_options(@fp_tournaments)}
              hint={
                gettext(
                  "Then its players are matched with the tournament's and its games count in its report."
                )
              }
            />
            <.input
              field={@pgn_form[:name]}
              type="text"
              label={gettext("Name (optional)")}
              maxlength="200"
            />
            <div class="row">
              <.button id="fair-play-pgn-submit" type="submit" variant="primary">
                {gettext("Upload and analyse")}
              </.button>
            </div>
          </.form>
          <ul :if={@fp_uploads != []} id="fair-play-uploads" class="tight-list">
            <li :for={u <- @fp_uploads} id={"fair-play-upload-#{u.id}"}>
              <.link navigate={~p"/fair-play/pgn/#{u.id}"}>{u.name}</.link>
              <span class="note">
                {ngettext("one game", "%{count} games", u.accepted)}, {day(u.inserted_at)}
              </span>
            </li>
          </ul>
        </div>
      </.panel>

      <.sharing_panel
        id="fair-play-sharing"
        title={gettext("Sharing")}
        intro={
          gettext(
            "Let someone see every fair-play report of this hall: the chief arbiter, a fair-play officer. They must be one of the hall's people. They can look, and nothing else; every opening is written down. A single report can be shared from the report itself."
          )
        }
        people={@fp_people}
        grants={@fp_grants}
        titles={@fp_titles}
        form={@grant_form}
      />

      <.panel
        :if={@fp_hall_audit != []}
        id="fair-play-hall-audit"
        title={gettext("What was done")}
        flush
      >
        <ul class="addresses">
          <li :for={v <- @fp_hall_audit}>
            {time(v.at)} {v.user_email || gettext("this computer")} {action_label(v.action)}
            <span :if={v.detail} class="note">{v.detail}</span>
          </li>
        </ul>
      </.panel>

      <.not_fide />
    </div>
    """
  end

  defp upload_error(:too_large),
    do: gettext("too large: at most %{mb} MB", mb: div(Uploads.max_bytes(), 1_000_000))

  defp upload_error(:not_accepted), do: gettext("not a .pgn file")
  defp upload_error(_other), do: gettext("cannot be uploaded")

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :intro, :string, required: true
  attr :people, :list, required: true
  attr :grants, :list, required: true
  attr :titles, :map, required: true
  attr :form, :any, required: true

  defp sharing_panel(assigns) do
    ~H"""
    <.panel id={@id} title={@title}>
      <div class="stack">
        <p class="note">{@intro}</p>
        <p :if={@people == []} id={"#{@id}-nobody"} class="note">
          {gettext(
            "The hall has nobody to share with yet: invite the person to the hall first (as a viewer is enough)."
          )}
        </p>
        <.form :if={@people != []} for={@form} id={"#{@id}-form"} phx-submit="grant" class="row">
          <.input
            field={@form[:user_id]}
            type="select"
            label={gettext("With")}
            options={people_options(@people)}
          />
          <.input
            field={@form[:days]}
            type="number"
            min="1"
            max={Grants.max_days()}
            label={gettext("For how many days")}
          />
          <.button id={"#{@id}-submit"} type="submit">{gettext("Share")}</.button>
        </.form>
        <ul :if={@grants != []} class="addresses" id={"#{@id}-list"}>
          <li :for={g <- @grants} id={"grant-#{g.id}"}>
            <b>{g.user_email}</b>
            <span class="note">{Map.get(@titles, g.id)}</span>
            <%= case grant_state(g) do %>
              <% :active -> %>
                <.badge tone="ok" icon="ok">
                  {gettext("until %{date}", date: day(g.expires_at))}
                </.badge>
                <.button
                  id={"revoke-#{g.id}"}
                  small
                  phx-click="revoke"
                  phx-value-id={g.id}
                >
                  {gettext("Stop sharing")}
                </.button>
              <% :expired -> %>
                <.badge tone="warn" icon="waiting">
                  {gettext("ended %{date}", date: day(g.expires_at))}
                </.badge>
              <% :revoked -> %>
                <.badge tone="warn" icon="waiting">
                  {gettext("stopped %{date}", date: day(g.revoked_at))}
                </.badge>
            <% end %>
          </li>
        </ul>
      </div>
    </.panel>
    """
  end

  defp platform_text({:macos, version}),
    do:
      gettext(
        "Fair play needs macOS 10.15 or newer; this Mac runs %{version}. Everything else in Alnasl works as before.",
        version: version
      )

  defp installed?(setting), do: Alnasl.FairPlay.Setting.installed?(setting)

  # --- the report --------------------------------------------------------------

  defp report_page(assigns) do
    ~H"""
    <div :if={@fp_subject} class="stack" id="fair-play-report">
      <p :if={@fp_owner?} class="note">
        <.link
          navigate={~p"/halls/#{FairPlay.hall_of(@fp_subject)}/fair-play"}
          id="fair-play-back"
        >
          {gettext("Fair-play settings")}
        </.link>
      </p>
      <p :if={not @fp_owner?} id="fair-play-shared-note" class="note">
        {gettext(
          "The owner of this hall shared this report with you. It is confidential: you can look, and your opening it is written down."
        )}
      </p>

      <.not_fide />

      <%= if @fp_data do %>
        <.upload_panel :if={@fp_data.upload} {assigns} />

        <.panel id="fair-play-players" title={subject_title(@fp_subject)} flush>
          <:actions>
            <nav
              :if={@fp_data.rounds != []}
              id="fair-play-rounds"
              class="seg"
              aria-label={gettext("Rounds")}
            >
              <.link
                :for={r <- @fp_data.rounds}
                id={"fair-play-round-#{r}"}
                navigate={round_path(@fp_subject, r, @fp_only?)}
                aria-current={to_string(r == @fp_data.round)}
              >
                {round_label(r)}
              </.link>
            </nav>
            <.link
              :if={@fp_data.round}
              id="fair-play-only"
              navigate={round_path(@fp_subject, @fp_data.round, not @fp_only?)}
            >
              <%= if @fp_only? do %>
                {gettext("Rounds 1 to %{round}", round: @fp_data.round)}
              <% else %>
                {gettext("Round %{round} only", round: @fp_data.round)}
              <% end %>
            </.link>
          </:actions>

          <p :if={not @fp_data.calibrated?} id="fair-play-uncalibrated" class="note">
            {gettext(
              "There is no score yet: this engine has not been calibrated, so there is nothing to compare a player's moves with. The counts below are real; do not read more into them than that."
            )}
          </p>

          <p :if={@fp_data.players == []} id="fair-play-empty" class="note">
            {gettext(
              "Nothing has been analysed for this tournament. Is fair play on in this hall, with an engine installed, and are the games recorded by the boards?"
            )}
          </p>

          <div :if={@fp_data.players != []} class="table-wrap">
            <table id="fair-play-table">
              <thead>
                <tr>
                  <th>{gettext("Player")}</th>
                  <th class="num">{gettext("Counted moves")}</th>
                  <th class="num">{gettext("Matches the engine")}</th>
                  <th class="num">{gettext("Expected")}</th>
                  <th class="num">{gettext("Average loss")}</th>
                  <th class="num">{gettext("Expected")}</th>
                  <th class="num">{gettext("Score")}</th>
                  <th>{gettext("Left out")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- @fp_data.players} id={"fair-play-player-#{player_dom(p.key)}"}>
                  <td>
                    <.link
                      id={"fair-play-player-link-#{player_dom(p.key)}"}
                      navigate={player_path(@fp_subject, p.key, @fp_data.round, @fp_only?)}
                    >
                      <b>{p.name}</b>
                    </.link>
                    <span :if={p.rating} class="note">{p.rating}</span>
                  </td>
                  <td class="num">{p.counted}</td>
                  <td class="num">{percent(p.mm_share)}</td>
                  <td class="num">{percent(p.expected_mm_share)}</td>
                  <td class="num">{loss(p.avg_loss)}</td>
                  <td class="num">{loss(p.expected_avg_loss)}</td>
                  <td class="num">
                    <%= if p.score do %>
                      <b>{score(p.score)}</b> <span class="note">{interval(p.interval)}</span>
                      <br />
                      <span :if={p.verdict} class="note">{verdict_label(p.verdict)}</span>
                      <span
                        :if={rarity(@fp_data.model, p.score)}
                        class="note fp-rarity"
                        id={"fair-play-rarity-#{player_dom(p.key)}"}
                      >
                        {rarity(@fp_data.model, p.score)}
                      </span>
                    <% else %>
                      <span class="note">{reason_label(p.reason)}</span>
                    <% end %>
                  </td>
                  <td>
                    <ul class="addresses">
                      <li :for={{reason, n} <- skips(p.skipped)}>{n} {skip_label(reason)}</li>
                    </ul>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel
          :if={(@fp_owner? and @fp_tournament) && @fp_data.played_rounds != []}
          id="fair-play-analyse-round"
          title={gettext("Analyse a round on demand")}
        >
          <div class="stack">
            <p class="note">
              {gettext(
                "For a round played while fair play was off, before the engine was installed, or that the queue could not keep up with. Moves already analysed with this engine are kept; only what is missing costs time. The live games go first."
              )}
            </p>
            <form id="fair-play-analyse-round-form" phx-submit="analyse_round" class="row">
              <.input
                type="select"
                id="fair-play-analyse-round-select"
                name="round"
                value={@fp_data.round}
                label={gettext("Round")}
                options={Enum.map(@fp_data.played_rounds, &{to_string(&1), &1})}
              />
              <.button id="fair-play-analyse-round-submit" type="submit">
                {gettext("Analyse this round")}
              </.button>
            </form>
          </div>
        </.panel>

        <.sharing_panel
          :if={@fp_owner?}
          id="fair-play-share"
          title={gettext("Shared with")}
          intro={
            gettext(
              "Let one of the hall's people see this report until a date you choose. They can look, and nothing else; you can stop it at any time; every opening is written down."
            )
          }
          people={@fp_data.people}
          grants={@fp_data.grants}
          titles={@fp_data.titles}
          form={@grant_form}
        />

        <.panel :if={@fp_owner?} id="fair-play-keep" title={gettext("How long this is kept")}>
          <div class="stack">
            <p id="fair-play-keep-text">
              <%= cond do %>
                <% @fp_data.keep == :with_tournament -> %>
                  {gettext("These games belong to a tournament and are kept as long as it is.")}
                <% @fp_data.keep -> %>
                  {gettext("Kept until %{date}. Reason: %{reason}",
                    date: time(@fp_data.keep.keep_until),
                    reason: @fp_data.keep.reason
                  )}
                <% match?(%Upload{}, @fp_subject) -> %>
                  {gettext(
                    "Deleted %{days} days after it was uploaded, along with the list below of who opened this page.",
                    days: FairPlay.retention_days()
                  )}
                <% true -> %>
                  {gettext(
                    "Deleted %{days} days after the tournament's last round, along with the list below of who opened this page.",
                    days: FairPlay.retention_days()
                  )}
              <% end %>
            </p>
            <.form
              :if={@fp_data.keep != :with_tournament}
              for={@extend_form}
              id="fair-play-extend"
              phx-submit="extend"
              class="row"
            >
              <.input
                field={@extend_form[:days]}
                type="number"
                min="1"
                max="365"
                label={keep_days_label(@fp_subject)}
              />
              <.input
                field={@extend_form[:reason]}
                type="text"
                label={gettext("Why (needed)")}
                required
              />
              <.button id="fair-play-extend-submit" type="submit">{gettext("Keep it")}</.button>
            </.form>
          </div>
        </.panel>

        <.panel
          :if={@fp_owner? and match?(%Tournaments.Tournament{}, @fp_subject)}
          id="fair-play-delete"
          title={gettext("Delete this analysis")}
        >
          <.form
            for={to_form(%{"reason" => ""}, as: :delete)}
            id="fair-play-delete-form"
            phx-submit="delete_analysis"
            class="stack"
          >
            <p class="note">
              {gettext(
                "Removes every analysed move of this tournament. A frozen copy of the report as it is now stays below, with who deleted it, when and why, for as long as the report would have been kept, and the audit says so. Games analysed again later make a new analysis."
              )}
            </p>
            <.input
              id="fair-play-delete-reason"
              type="text"
              name="delete[reason]"
              value=""
              label={gettext("Why (not needed, but written down)")}
            />
            <div class="row">
              <.button
                id="fair-play-delete-analysis"
                type="submit"
                variant="danger"
                data-confirm={
                  gettext(
                    "Delete the analysis of this tournament? The report goes; a frozen copy of it stays in this page for the owner."
                  )
                }
              >{gettext("Delete the analysis")}</.button>
            </div>
          </.form>
        </.panel>

        <.panel
          :if={@fp_owner? and @fp_data.snapshots != []}
          id="fair-play-snapshots"
          title={gettext("Deleted analyses (frozen copies)")}
        >
          <div :for={s <- @fp_data.snapshots} id={"fair-play-snapshot-#{s.id}"} class="stack">
            <p class="note">
              {gettext("Deleted %{when} by %{who}, %{moves} analysed moves.",
                when: time(s.deleted_at),
                who: s.deleted_by || gettext("this computer"),
                moves: s.moves
              )}
              <span :if={s.reason not in [nil, ""]}>
                {gettext("Reason: %{reason}", reason: s.reason)}
              </span>
            </p>
            <table id={"fair-play-snapshot-#{s.id}-players"}>
              <thead>
                <tr>
                  <th>{gettext("Player")}</th>
                  <th class="num">{gettext("Moves counted")}</th>
                  <th class="num">{gettext("Score")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- Alnasl.FairPlay.Snapshot.players(s)}>
                  <td>{p["name"]}</td>
                  <td class="num">{p["counted"]}</td>
                  <td class="num">
                    {if is_number(p["score"]), do: Float.round(p["score"] * 1.0, 2), else: "-"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel :if={@fp_owner?} id="fair-play-views" title={gettext("Who opened this")} flush>
          <ul class="addresses">
            <li :for={v <- @fp_data.views}>
              {time(v.at)} {v.user_email || gettext("this computer")}
              <span :if={v.action != "view"}>{action_label(v.action)}</span>
              <span :if={v.player_key} class="note">{v.player_key}</span>
              <span :if={v.detail} class="note">{v.detail}</span>
            </li>
          </ul>
        </.panel>
      <% else %>
        <p id="fair-play-loading" class="note">{gettext("Loading.")}</p>
      <% end %>
    </div>
    """
  end

  defp keep_days_label(%Upload{}), do: gettext("Days after the upload (at most 365)")
  defp keep_days_label(_tournament), do: gettext("Days after the last round (at most 365)")

  defp upload_panel(assigns) do
    ~H"""
    <.panel id="fair-play-upload-info" title={gettext("Uploaded PGN")}>
      <div class="stack">
        <p id="fair-play-upload-file" class="note">
          {@fp_subject.filename}
          <span :if={@fp_owner? and @fp_subject.uploaded_by}>
            · {gettext("uploaded by %{who}", who: @fp_subject.uploaded_by)}
          </span>
          · {day(@fp_subject.inserted_at)}
          <span :if={@fp_data.upload.tournament}>
            · {gettext("part of %{tournament}",
              tournament: tournament_title(@fp_data.upload.tournament)
            )}
          </span>
        </p>
        <p id="fair-play-upload-progress">
          <.badge tone="ok" icon="ok">
            {gettext("%{count} analysed", count: @fp_data.upload.progress.done)}
          </.badge>
          <.badge :if={@fp_data.upload.progress.waiting > 0} tone="warn" icon="settling">
            {gettext("%{count} waiting", count: @fp_data.upload.progress.waiting)}
          </.badge>
          <.badge :if={@fp_data.upload.progress.failed > 0} tone="warn" icon="warning">
            {gettext("%{count} failed", count: @fp_data.upload.progress.failed)}
          </.badge>
          <.badge :if={@fp_data.upload.progress.duplicate > 0} tone="warn" icon="waiting">
            {gettext("%{count} recorded by the boards", count: @fp_data.upload.progress.duplicate)}
          </.badge>
        </p>
        <details :if={@fp_data.upload.problems != []} id="fair-play-upload-problems">
          <summary>
            {ngettext(
              "One game with a remark",
              "%{count} games with a remark",
              length(@fp_data.upload.problems)
            )}
          </summary>
          <ul class="addresses">
            <li :for={p <- @fp_data.upload.problems}>
              {gettext("Game %{n}", n: p["game"])}
              <span :if={p["white"] || p["black"]}>({p["white"]} - {p["black"]})</span>: {problem_text(
                p
              )}
            </li>
          </ul>
        </details>
        <div :if={@fp_owner?} class="row">
          <.button
            :if={@fp_data.upload.progress.waiting > 0}
            id="fair-play-requeue"
            small
            phx-click="requeue_upload"
          >
            {gettext("Queue the waiting games again")}
          </.button>
          <.button
            id="fair-play-delete-upload"
            small
            variant="danger"
            phx-click="delete_upload"
            data-confirm={
              gettext("Delete this upload, its games and their analysis? This cannot be undone.")
            }
          >
            {gettext("Delete this upload")}
          </.button>
        </div>
      </div>
    </.panel>
    """
  end

  # A DOM-safe form of a player key.
  defp player_dom(key), do: String.replace(key, ~r/[^A-Za-z0-9_-]/, "-")

  # --- one player --------------------------------------------------------------

  defp player_page(assigns) do
    ~H"""
    <div :if={@fp_subject} class="stack" id="fair-play-player-page">
      <p class="note">
        <.link
          navigate={round_path(@fp_subject, @fp_round || 1, @fp_only?)}
          id="fair-play-back"
        >
          {gettext("Back to the report")}
        </.link>
      </p>

      <.not_fide />

      <%= cond do %>
        <% @fp_data == nil -> %>
          <p id="fair-play-loading" class="note">{gettext("Loading.")}</p>
        <% @fp_data.line == nil -> %>
          <p id="fair-play-no-player" class="note">
            {gettext("Nothing has been analysed for this player.")}
          </p>
        <% true -> %>
          <% line = @fp_data.line %>
          <.panel id="fair-play-player-numbers" title={line.name}>
            <dl class="kv">
              <dt>{gettext("Counted moves")}</dt>
              <dd id="fp-counted">{line.counted}</dd>
              <dt>{gettext("Matches the engine")}</dt>
              <dd id="fp-mm">
                {percent(line.mm_share)} ({gettext("expected")} {percent(line.expected_mm_share)})
              </dd>
              <dt>{gettext("Average loss")}</dt>
              <dd id="fp-loss">
                {loss(line.avg_loss)} ({gettext("expected")} {loss(line.expected_avg_loss)})
              </dd>
              <dt>{gettext("Score")}</dt>
              <dd id="fp-score">
                <%= if line.score do %>
                  <b>{score(line.score)}</b> {interval(line.interval)}
                  <span :if={line.verdict}>{verdict_label(line.verdict)}</span>
                  <span :if={rarity(@fp_data.model, line.score)} class="note" id="fp-rarity">
                    {rarity(@fp_data.model, line.score)}
                  </span>
                <% else %>
                  {reason_label(line.reason)}
                <% end %>
              </dd>
            </dl>
            <ul class="addresses">
              <li :for={{reason, n} <- skips(line.skipped)}>{n} {skip_label(reason)}</li>
            </ul>
          </.panel>

          <.panel id="fair-play-positions" title={gettext("Positions to look at")}>
            <p class="note">
              {gettext(
                "Moves this player made that were the engine's first choice, where that choice stood out most from the second. Look at them as a person would: a move like that is often the only sensible one."
              )}
            </p>
            <p :if={@fp_data.positions == []} id="fair-play-no-positions" class="note">
              {gettext("There are none yet.")}
            </p>
            <div class="cols">
              <article
                :for={{pos, i} <- Enum.with_index(@fp_data.positions)}
                id={"fair-play-position-#{i}"}
                class="fp-position stack"
              >
                <.board
                  id={"fair-play-board-#{i}"}
                  position={pos.board}
                  last={pos.last}
                  coords
                  label={gettext("The position before the move")}
                />
                <p>
                  <b>
                    <%= if pos.board_no > 0 do %>
                      {gettext("Round %{round}, board %{board}, move %{n}",
                        round: round_label(pos.round),
                        board: pos.board_no,
                        n: pos.move_number
                      )}
                    <% else %>
                      {gettext("Round %{round}, move %{n}",
                        round: round_label(pos.round),
                        n: pos.move_number
                      )}
                    <% end %>
                  </b>
                  ({colour_label(pos.colour)}) <br />
                  {gettext("Played %{move}", move: pos.played)} {Report.pawns(pos.played_cp)}
                </p>
                <ol class="addresses">
                  <li :for={l <- pos.lines}>{l.san} {Report.pawns(l.cp)}</li>
                </ol>
              </article>
            </div>
          </.panel>
      <% end %>
    </div>
    """
  end
end

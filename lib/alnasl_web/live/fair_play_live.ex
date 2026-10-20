defmodule AlnaslWeb.FairPlayLive do
  @moduledoc """
  Fair-play screening, the owner's pages (`docs/plan-fair-play.md`, section 7):

    * `:settings` (`/halls/:id/fair-play`) - the switch, the engine (download
      or choose a file), the credit, and the hall's tournaments with a link
      to each report;
    * `:report` (`/fair-play/:tid`, `/fair-play/:tid/round/:round`) - one line
      per player of a tournament, through a round or for that round only,
      and the owner's extension of how long it is kept;
    * `:player` (`/fair-play/:tid/player?p=KEY`) - one player's numbers and
      the positions worth a look.

  **Only the hall's owner gets in** (`Alnasl.FairPlay.Access`). A page
  anyone else asks for answers as a page that is not there, and says nothing
  about whether the tournament or the hall exists. The check is made when
  the page is reached and again by every function that reads or changes
  fair-play data (`Alnasl.FairPlay`), and every event repeats it. Nothing
  of a report is rendered before the page is connected: the first, static
  render holds no data, so a request that never opens a socket sees nothing
  - and every opening that does see data is written in the audit
  (`Alnasl.FairPlay.record_view/4`).

  The page never says "cheating": it says what the numbers are and that
  they are not the method FIDE has approved.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{FairPlay, Halls, Tournaments}
  alias Alnasl.FairPlay.{Access, Installer, Report, Selection}
  alias AlnaslWeb.Components.ManualLink

  @max_archive 400_000_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Fair-play screening"))
     |> assign(fp_hall: nil, fp_tournament: nil, fp_data: nil, fp_error: nil, fp_installing: nil)
     |> assign(extend_form: to_form(%{"days" => "90", "reason" => ""}, as: :keep))
     |> allow_upload(:archive,
       accept: ~w(.zip .gz),
       max_entries: 1,
       max_file_size: @max_archive
     )}
  end

  # --- reaching a page ---------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
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

  defp settings(params, socket) do
    scope = socket.assigns.current_scope

    with {id, ""} <- Integer.parse(params["id"] || ""),
         %{} = hall <- Halls.get(id),
         {:ok, tournaments} <- FairPlay.tournaments(scope, hall.id) do
      {:noreply,
       assign(socket,
         fp_hall: hall,
         fp_setting: FairPlay.settings(hall.id),
         fp_tournaments: tournaments,
         fp_error: nil,
         page_title: gettext("Fair-play screening")
       )}
    else
      _no -> nothing_here(socket)
    end
  end

  defp report(params, socket) do
    scope = socket.assigns.current_scope

    with {tid, ""} <- Integer.parse(params["tid"] || ""),
         {:ok, tournament} <- FairPlay.tournament(scope, tid) do
      socket =
        assign(socket,
          fp_tournament: tournament,
          fp_round: int(params["round"]),
          fp_only?: params["only"] == "1",
          fp_data: nil,
          page_title: gettext("Fair-play screening")
        )

      {:noreply, if(connected?(socket), do: load_report(socket), else: socket)}
    else
      _no -> nothing_here(socket)
    end
  end

  defp player(params, socket) do
    scope = socket.assigns.current_scope

    with {tid, ""} <- Integer.parse(params["tid"] || ""),
         {:ok, tournament} <- FairPlay.tournament(scope, tid),
         key when is_binary(key) and key != "" <- params["p"] do
      socket =
        assign(socket,
          fp_tournament: tournament,
          fp_round: int(params["round"]),
          fp_only?: params["only"] == "1",
          fp_player_key: key,
          fp_data: nil,
          page_title: gettext("Fair-play screening")
        )

      {:noreply, if(connected?(socket), do: load_player(socket), else: socket)}
    else
      _no -> nothing_here(socket)
    end
  end

  defp int(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  defp int(_none), do: nil

  # --- loading what is shown ---------------------------------------------------

  defp load_report(socket) do
    %{current_scope: scope, fp_tournament: tournament} = socket.assigns

    with {:ok, rounds} <- FairPlay.rounds(scope, tournament),
         round = socket.assigns.fp_round || List.last(rounds),
         {:ok, rows} <- FairPlay.moves(scope, tournament, filter(socket, round)),
         {:ok, _view} <- FairPlay.record_view(scope, tournament, round, nil),
         {:ok, views} <- FairPlay.views(scope, tournament),
         {:ok, keep} <- FairPlay.keep(scope, tournament) do
      setting = FairPlay.settings_for_tournament(tournament)
      model = Report.model(setting)

      assign(socket,
        fp_data: %{
          rounds: rounds,
          round: round,
          players: Report.build(rows, model),
          calibrated?: model != nil,
          setting: setting,
          views: views,
          keep: keep,
          last_round_end: Alnasl.FairPlay.Retention.last_round_end(tournament.id)
        }
      )
    else
      {:error, :forbidden} -> assign(socket, fp_data: nil)
    end
  end

  defp load_player(socket) do
    %{current_scope: scope, fp_tournament: tournament, fp_player_key: key} = socket.assigns

    with {:ok, rounds} <- FairPlay.rounds(scope, tournament),
         round = socket.assigns.fp_round || List.last(rounds),
         {:ok, rows} <- FairPlay.moves(scope, tournament, filter(socket, round)),
         {:ok, _view} <- FairPlay.record_view(scope, tournament, round, key) do
      setting = FairPlay.settings_for_tournament(tournament)
      model = Report.model(setting)
      rows = Enum.filter(rows, &(&1.player_key == key))

      line =
        if rows == [],
          do: nil,
          else: Report.player(key, rows, model)

      assign(socket,
        fp_data: %{
          round: round,
          line: line,
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

  def handle_event("extend", %{"keep" => %{"days" => days, "reason" => reason}}, socket) do
    scope = socket.assigns.current_scope
    tournament = socket.assigns.fp_tournament

    case FairPlay.extend(scope, tournament, int(days) || 0, reason) do
      {:ok, _keep} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Kept for longer."))
         |> load_report()}

      {:error, :forbidden} ->
        {:noreply, refuse(socket)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, extend_message(error))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp refuse(socket),
    do: put_flash(socket, :error, gettext("There is nothing at that address."))

  defp extend_message(:reason),
    do: gettext("Say why: a reason is needed to keep the analysis longer.")

  defp extend_message(:too_long),
    do: gettext("At most 365 days after the tournament's last round.")

  defp extend_message(:days), do: gettext("Give a number of days.")

  defp extend_message(:no_rounds),
    do: gettext("This tournament has no games yet, so there is no last round to count from.")

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

  defp tournament_title(tournament),
    do: Tournaments.title(tournament) || gettext("Tournament %{id}", id: tournament.id)

  defp colour_label(:white), do: gettext("White")
  defp colour_label(:black), do: gettext("Black")

  defp round_path(tournament, round, only?) do
    base = ~p"/fair-play/#{tournament.id}/round/#{round}"
    if only?, do: base <> "?only=1", else: base
  end

  defp player_path(tournament, key, round, only?) do
    query =
      [p: key] ++ if(round, do: [round: round], else: []) ++ if(only?, do: [only: 1], else: [])

    ~p"/fair-play/#{tournament.id}/player?#{query}"
  end

  defp time(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  # --- rendering ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:halls}
      help={:fair_play}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Fair-play screening")}
    >
      <%= case @live_action do %>
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

  # --- settings ----------------------------------------------------------------

  defp settings_page(assigns) do
    ~H"""
    <div :if={@fp_hall} class="stack" id="fair-play-settings">
      <p class="note">
        <.link navigate={~p"/halls/#{@fp_hall.id}"} id="fair-play-back">
          {gettext("Back to %{hall}", hall: @fp_hall.name)}
        </.link>
      </p>

      <.panel id="fair-play-switch-panel" title={gettext("Fair-play screening")}>
        <div class="stack">
          <p>
            {gettext(
              "Alnasl can check the games its boards record against a strong chess engine, and show you, as the owner of this hall and nobody else, which players' moves matched it more often than their rating predicts. It is off until you switch it on."
            )}
          </p>
          <.form for={%{}} id="fair-play-switch" phx-change="toggle">
            <.input
              type="checkbox"
              id="fair-play-enabled"
              name="enabled"
              checked={@fp_setting.enabled}
              label={gettext("Fair-play screening")}
              hint={gettext("Analyses the moves of this hall's games as they are played.")}
            />
          </.form>
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

          <div class="row">
            <.button
              id="fair-play-download"
              phx-click="download"
              disabled={@fp_installing != nil}
            >
              {gettext("Download Stockfish 19")}
            </.button>
          </div>

          <.form
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

      <.not_fide />
    </div>
    """
  end

  defp installed?(setting), do: Alnasl.FairPlay.Setting.installed?(setting)

  # --- the report --------------------------------------------------------------

  defp report_page(assigns) do
    ~H"""
    <div :if={@fp_tournament} class="stack" id="fair-play-report">
      <p class="note">
        <.link
          navigate={~p"/halls/#{FairPlay.hall_of(@fp_tournament)}/fair-play"}
          id="fair-play-back"
        >
          {gettext("Fair-play settings")}
        </.link>
      </p>

      <.not_fide />

      <%= if @fp_data do %>
        <.panel id="fair-play-players" title={tournament_title(@fp_tournament)} flush>
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
                navigate={round_path(@fp_tournament, r, @fp_only?)}
                aria-current={to_string(r == @fp_data.round)}
              >
                {r}
              </.link>
            </nav>
            <.link
              :if={@fp_data.round}
              id="fair-play-only"
              navigate={round_path(@fp_tournament, @fp_data.round, not @fp_only?)}
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
              "Nothing has been analysed for this tournament. Is fair-play screening on in this hall, with an engine installed, and are the games recorded by the boards?"
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
                      navigate={player_path(@fp_tournament, p.key, @fp_data.round, @fp_only?)}
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

        <.panel id="fair-play-keep" title={gettext("How long this is kept")}>
          <div class="stack">
            <p id="fair-play-keep-text">
              <%= if @fp_data.keep do %>
                {gettext("Kept until %{date}. Reason: %{reason}",
                  date: time(@fp_data.keep.keep_until),
                  reason: @fp_data.keep.reason
                )}
              <% else %>
                {gettext(
                  "Deleted %{days} days after the tournament's last round, along with the list below of who opened this page.",
                  days: FairPlay.retention_days()
                )}
              <% end %>
            </p>
            <.form for={@extend_form} id="fair-play-extend" phx-submit="extend" class="row">
              <.input
                field={@extend_form[:days]}
                type="number"
                min="1"
                max="365"
                label={gettext("Days after the last round (at most 365)")}
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

        <.panel id="fair-play-views" title={gettext("Who opened this")} flush>
          <ul class="addresses">
            <li :for={v <- @fp_data.views}>
              {time(v.at)} {v.user_email || gettext("this computer")}
              <span :if={v.player_key} class="note">{v.player_key}</span>
            </li>
          </ul>
        </.panel>
      <% else %>
        <p id="fair-play-loading" class="note">{gettext("Loading.")}</p>
      <% end %>
    </div>
    """
  end

  # A DOM-safe form of a player key.
  defp player_dom(key), do: String.replace(key, ~r/[^A-Za-z0-9_-]/, "-")

  # --- one player --------------------------------------------------------------

  defp player_page(assigns) do
    ~H"""
    <div :if={@fp_tournament} class="stack" id="fair-play-player-page">
      <p class="note">
        <.link
          navigate={round_path(@fp_tournament, @fp_round || 1, @fp_only?)}
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
                    {gettext("Round %{round}, board %{board}, move %{n}",
                      round: pos.round,
                      board: pos.board_no,
                      n: pos.move_number
                    )}
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

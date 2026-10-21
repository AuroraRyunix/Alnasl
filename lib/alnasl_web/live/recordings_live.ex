defmodule AlnaslWeb.RecordingsLive do
  @moduledoc """
  The raw captures: everything every board delivered, as it delivered it.

  A capture can be **replayed through the tracker** as a dry run - nothing is
  saved or sent - to see what moves it makes of it and where it lost the
  thread; **exported as a test fixture**, so a failure in a hall becomes a
  test at a desk; or downloaded.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Clock, Recorder}
  alias AlnaslWeb.Components.Pager
  alias AlnaslWeb.Words

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Recordings"), report: nil)
     |> assign(q: "", all?: false, page: 1)
     |> load()}
  end

  defp load(socket) do
    Recorder.flush()
    %{current_scope: account, all?: all?, q: q} = socket.assigns
    everything? = Alnasl.Accounts.Scope.everything?(account)

    # The default is this hall's boards; "all my halls" is every hall the
    # account may see. A capture of a board since removed belongs to no hall:
    # only an admin's all-halls list has it.
    boards =
      if all?,
        do: Alnasl.Halls.visible(account, Boards.list()),
        else: Alnasl.Halls.here(account, Boards.list())

    names = Map.new(boards, &{&1.id, &1.name})
    open? = account.open?

    captures =
      Recorder.list()
      |> Enum.filter(&(open? or (all? and everything?) or Map.has_key?(names, &1.board_id)))
      |> Enum.map(
        &Map.put(
          &1,
          :board_name,
          names[&1.board_id] || gettext("removed board %{id}", id: &1.board_id)
        )
      )
      |> Enum.filter(&Pager.match?([&1.board_name, &1.name], q))

    {rows, page, pages} = Pager.slice(captures, socket.assigns.page)

    socket
    |> assign(
      count: length(captures),
      total: captures |> Enum.map(& &1.size) |> Enum.sum(),
      page: page,
      pages: pages
    )
    |> stream(:captures, rows,
      reset: true,
      dom_id: &"capture-#{&1.board_id}-#{Path.rootname(&1.name)}"
    )
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("search", params, socket) do
    filter = params["filter"] || %{}

    {:noreply,
     socket
     |> assign(q: to_string(filter["q"] || ""), all?: filter["all"] == "1", page: 1)
     |> load()}
  end

  def handle_event("page", %{"to" => to}, socket),
    do: {:noreply, socket |> assign(page: Pager.page(to)) |> load()}

  def handle_event("dry_run", %{"board" => board, "name" => name}, socket) do
    with %{} = capture <- find(board, name, socket.assigns.current_scope),
         {:ok, report} <- Recorder.dry_run(capture.path) do
      {:noreply,
       assign(socket, report: Map.merge(report, %{name: name, board_id: capture.board_id}))}
    else
      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("That capture is empty or could not be read."))}
    end
  end

  def handle_event("close_report", _params, socket), do: {:noreply, assign(socket, report: nil)}

  def handle_event("export", %{"board" => board, "name" => name}, socket) do
    with %{} = capture <- find(board, name, socket.assigns.current_scope),
         {:ok, path} <-
           Recorder.export_fixture(
             capture.path,
             "board-#{capture.board_id}-#{Path.rootname(name)}"
           ) do
      {:noreply,
       put_flash(socket, :info, gettext("Exported as a test fixture: %{path}", path: path))}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("That capture could not be exported."))}
    end
  end

  def handle_event("delete", %{"board" => board, "name" => name}, socket) do
    case find(board, name, socket.assigns.current_scope) do
      %{path: path} ->
        case File.rm(path) do
          :ok ->
            {:noreply, socket |> put_flash(:info, gettext("The capture was deleted.")) |> load()}

          {:error, _reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("The capture could not be deleted. Is it open somewhere?")
             )}
        end

      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That capture is already gone."))
         |> load()}
    end
  end

  # A capture of a board since removed has no hall to give a role in
  # (`AlnaslWeb.Permit` finds no board), so only whoever sees everything may
  # touch it, as in the list and the download.
  defp find(board, name, scope) do
    with {id, ""} <- Integer.parse(board),
         true <- Boards.get(id) != nil or Alnasl.Accounts.Scope.everything?(scope) do
      Recorder.find(id, name)
    else
      _bad -> nil
    end
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  defp at(ms), do: Clock.format(ms)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:recordings}
      help={:recordings}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Recordings")}
      subtitle={gettext("%{n} files, %{size}", n: @count, size: Words.size(@total))}
    >
      <:actions>
        <.button id="refresh-captures" small phx-click="refresh">{gettext("Look again")}</.button>
      </:actions>

      <.form
        for={%{}}
        as={:filter}
        id="captures-filter"
        phx-change="search"
        phx-submit="search"
        class="row"
      >
        <label class="sr-only" for="captures-q">{gettext("Search the recordings")}</label>
        <input
          id="captures-q"
          type="search"
          name="filter[q]"
          value={@q}
          placeholder={gettext("search")}
          phx-debounce="300"
          class="input log-q"
        />
        <label :if={not @current_scope.open?} class="check" for="captures-all">
          <input type="hidden" name="filter[all]" value="" />
          <input id="captures-all" type="checkbox" name="filter[all]" value="1" checked={@all?} /> {gettext(
            "All my halls"
          )}
        </label>
      </.form>

      <.panel :if={@report} id="dry-run" title={gettext("Dry run: %{name}", name: @report.name)}>
        <:actions>
          <.button id="close-report" small phx-click="close_report">{gettext("Close")}</.button>
        </:actions>

        <p class="note">
          {gettext("The capture was played through a fresh tracker. Nothing was saved or sent.")}
        </p>

        <dl class="kv mb-5">
          <dt>{gettext("Readings")}</dt>

          <dd id="report-events">
            {@report.events}
            <span :if={@report.raw?} class="flag plain">{gettext("decoded from raw bytes")}</span>
          </dd>

          <dt>{gettext("Length")}</dt>

          <dd>{at(@report.duration_ms)}</dd>

          <dt>{gettext("Moves found")}</dt>

          <dd id="report-count">{length(@report.moves)}</dd>

          <dt>{gettext("Ends")}</dt>

          <dd><.state id="report-state" state={@report.status} /></dd>

          <dt>{gettext("Out of sync")}</dt>

          <dd id="report-alarms">
            <%= if @report.alarms == [] do %>
              {gettext("never")}
            <% else %>
              <span :for={{t, _why} <- @report.alarms} class="flag mr-2">{at(t)}</span>
            <% end %>
          </dd>

          <dt>{gettext("Corrections")}</dt>

          <dd>{length(@report.corrections)}</dd>

          <dt :if={@report.suggestions != []}>{gettext("Result suggested")}</dt>

          <dd :if={@report.suggestions != []}>{@report.suggestions |> List.last() |> elem(1)}</dd>
        </dl>

        <p :if={@report.moves == []} class="note">{gettext("The tracker found no moves in it.")}</p>

        <p :if={@report.moves != []} id="report-moves" class="loose">
          <%= for {ply, index} <- Enum.with_index(@report.plies) do %>
            <span :if={rem(index, 2) == 0} class="quiet">{div(index, 2) + 1}.</span>
            <span class={
              @report.plies |> Enum.at(index) |> Map.get(:flags) |> Kernel.!=([]) && "flag"
            }><.figurine san={ply.san} /></span>
          <% end %>
        </p>

        <ul :if={@report.notes != []} class="note">
          <li :for={{t, text} <- @report.notes}>{at(t)} - {text}</li>
        </ul>
      </.panel>

      <.panel id="captures" title={gettext("Captures")} flush>
        <div :if={@count == 0 and @q in [nil, ""]} id="captures-empty" class="empty">
          <b>{gettext("Nothing recorded yet")}</b>
          <p>{gettext("Every connected board is recorded from the moment it is connected.")}</p>
        </div>

        <div :if={@count == 0 and @q not in [nil, ""]} id="captures-empty" class="empty">
          <b>{gettext("No recording matches")}</b>
          <p>
            {gettext("Nothing here has that in its name. Empty the search field to see them all.")}
          </p>
        </div>

        <div :if={@count > 0} class="table-wrap">
          <table id="captures-table">
            <thead>
              <tr>
                <th>{gettext("Board")}</th>

                <th>{gettext("File")}</th>

                <th class="num">{gettext("Size")}</th>

                <th>{gettext("Last written")}</th>

                <th><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>

            <tbody id="captures-rows" phx-update="stream">
              <tr :for={{dom_id, c} <- @streams.captures} id={dom_id}>
                <td>{c.board_name}</td>

                <td class="mono">{c.name}</td>

                <td class="num">{Words.size(c.size)}</td>

                <td>{Words.datetime(c.modified)}</td>

                <td class="act">
                  <.button
                    id={"dry-#{c.board_id}-#{Path.rootname(c.name)}"}
                    small
                    variant="primary"
                    phx-click="dry_run"
                    phx-value-board={c.board_id}
                    phx-value-name={c.name}
                  >
                    {gettext("Replay through the tracker")}
                  </.button>

                  <.button
                    id={"fixture-#{c.board_id}-#{Path.rootname(c.name)}"}
                    small
                    phx-click="export"
                    phx-value-board={c.board_id}
                    phx-value-name={c.name}
                  >
                    {gettext("Export as test fixture")}
                  </.button>

                  <.button small href={~p"/files/capture/#{c.board_id}/#{c.name}"} download>{gettext(
                    "Download"
                  )}</.button>
                  <.button
                    id={"delete-#{c.board_id}-#{Path.rootname(c.name)}"}
                    small
                    variant="danger"
                    phx-click="delete"
                    phx-value-board={c.board_id}
                    phx-value-name={c.name}
                    data-confirm={gettext("Delete this capture? It cannot be brought back.")}
                  >
                    {gettext("Delete")}
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <AlnaslWeb.Components.Pager.pager
          id="captures-pager"
          page={@page}
          pages={@pages}
          total={@count}
        />
      </.panel>
    </Layouts.app>
    """
  end
end

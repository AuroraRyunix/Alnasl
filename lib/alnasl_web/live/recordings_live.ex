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
  alias AlnaslWeb.Words

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Recordings"), report: nil) |> load()}
  end

  defp load(socket) do
    Recorder.flush()
    names = Map.new(Boards.list(), &{&1.id, &1.name})
    captures = Recorder.list()

    assign(socket,
      captures:
        Enum.map(
          captures,
          &Map.put(
            &1,
            :board_name,
            names[&1.board_id] || gettext("removed board %{id}", id: &1.board_id)
          )
        ),
      total: captures |> Enum.map(& &1.size) |> Enum.sum()
    )
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("dry_run", %{"board" => board, "name" => name}, socket) do
    with %{} = capture <- find(board, name), {:ok, report} <- Recorder.dry_run(capture.path) do
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
    with %{} = capture <- find(board, name),
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
    case find(board, name) do
      %{path: path} ->
        File.rm(path)
        {:noreply, socket |> put_flash(:info, gettext("The capture was deleted.")) |> load()}

      nil ->
        {:noreply, socket}
    end
  end

  defp find(board, name) do
    case Integer.parse(board) do
      {id, ""} -> Recorder.find(id, name)
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
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      title={gettext("Recordings")}
      subtitle={gettext("%{n} files, %{size}", n: length(@captures), size: Words.size(@total))}
    >
      <:actions>
        <.button id="refresh-captures" small phx-click="refresh">{gettext("Look again")}</.button>
      </:actions>

      <.panel :if={@report} id="dry-run" title={gettext("Dry run: %{name}", name: @report.name)}>
        <:actions>
          <.button id="close-report" small phx-click="close_report">{gettext("Close")}</.button>
        </:actions>
        <p class="note">
          {gettext("The capture was played through a fresh tracker. Nothing was saved or sent.")}
        </p>
        <dl class="kv" style="margin-bottom:0.8rem">
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
              <span :for={{t, _why} <- @report.alarms} class="flag" style="margin-right:0.3rem">{at(t)}</span>
            <% end %>
          </dd>
          <dt>{gettext("Corrections")}</dt>
          <dd>{length(@report.corrections)}</dd>
          <dt :if={@report.suggestions != []}>{gettext("Result suggested")}</dt>
          <dd :if={@report.suggestions != []}>{@report.suggestions |> List.last() |> elem(1)}</dd>
        </dl>
        <p :if={@report.moves == []} class="note">{gettext("The tracker found no moves in it.")}</p>
        <p :if={@report.moves != []} id="report-moves" style="line-height:1.9">
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
        <div :if={@captures == []} id="captures-empty" class="empty">
          <b>{gettext("Nothing recorded yet")}</b>
          <p>{gettext("Every connected board is recorded from the moment it is connected.")}</p>
        </div>
        <div :if={@captures != []} class="table-wrap">
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
            <tbody>
              <tr :for={c <- @captures} id={"capture-#{c.board_id}-#{Path.rootname(c.name)}"}>
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
      </.panel>
    </Layouts.app>
    """
  end
end

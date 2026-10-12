defmodule AlnaslWeb.LogLive do
  @moduledoc """
  What happened, in sentences: a board connected, a move was recovered, a
  board went out of sync and came back, the arbiter repaired something, the
  server was away and returned. Newest first, and live.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.Log
  alias AlnaslWeb.Words

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Log.subscribe()

    {:ok,
     socket
     |> assign(page_title: gettext("Log"), filter: %{"level" => "", "kind" => "", "board" => ""})
     |> fill()}
  end

  defp fill(socket) do
    filter = socket.assigns.filter

    events =
      Log.list(
        level: filter["level"],
        kind: filter["kind"],
        board_no: board_no(filter),
        limit: 300
      )

    socket
    |> assign(form: to_form(filter, as: :filter), count: length(events))
    |> stream(:events, events, reset: true)
  end

  defp board_no(%{"board" => text}) do
    case Integer.parse(text) do
      {n, ""} -> n
      _none -> nil
    end
  end

  defp matches?(event, filter) do
    level_ok =
      case filter["level"] do
        "warn" -> event.level in ["warn", "error"]
        "error" -> event.level == "error"
        _all -> true
      end

    level_ok and String.starts_with?(event.kind, filter["kind"] || "") and
      (board_no(filter) == nil or event.board_no == board_no(filter))
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, socket |> assign(filter: Map.take(filter, ~w(level kind board))) |> fill()}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, socket |> assign(filter: %{"level" => "", "kind" => "", "board" => ""}) |> fill()}
  end

  @impl true
  def handle_info({:log, event}, socket) do
    if event.id && matches?(event, socket.assigns.filter),
      do:
        {:noreply,
         socket |> stream_insert(:events, event, at: 0) |> assign(count: socket.assigns.count + 1)},
      else: {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp where(event) do
    cond do
      event.round && event.board_no ->
        gettext("R%{r} board %{n}", r: event.round, n: event.board_no)

      event.board_no ->
        gettext("board %{n}", n: event.board_no)

      true ->
        ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:log}
      link={@link}
      update={@update}
      box={@box}
      locale={@locale}
      title={gettext("Log")}
    >
      <.panel id="log-panel" title={gettext("What happened")} flush>
        <:actions>
          <.form for={@form} id="log-filter" phx-change="filter" class="row">
            <label class="sr-only" for="log-level">{gettext("How serious")}</label>
            <select id="log-level" name="filter[level]" class="input" style="width:auto">
              {Phoenix.HTML.Form.options_for_select(
                [
                  {gettext("Everything"), ""},
                  {gettext("Needs attention and worse"), "warn"},
                  {gettext("Broken only"), "error"}
                ],
                @form[:level].value
              )}
            </select>
            <label class="sr-only" for="log-kind">{gettext("About")}</label>
            <select id="log-kind" name="filter[kind]" class="input" style="width:auto">
              {Phoenix.HTML.Form.options_for_select(Words.log_kinds(), @form[:kind].value)}
            </select>
            <label class="sr-only" for="log-board">{gettext("Board number")}</label>
            <input
              id="log-board"
              type="number"
              min="1"
              name="filter[board]"
              value={@form[:board].value}
              placeholder={gettext("board no.")}
              class="input"
              style="width:6.5rem"
            />
            <.button id="log-clear" small type="button" phx-click="clear_filter">{gettext("Show all")}</.button>
          </.form>
        </:actions>
        <ul id="log-lines" class="log" phx-update="stream">
          <li id="log-empty" class="only-empty empty">{gettext("Nothing to show.")}</li>
          <li :for={{id, event} <- @streams.events} id={id} class={event.level}>
            <time datetime={DateTime.to_iso8601(event.at)}>{Words.time(event.at)}</time>
            <span class="where">{where(event)}</span>
            <span class="what">
              <span :if={event.level == "error"} class="sr-only">{gettext("Broken:")}</span>
              <span :if={event.level == "warn"} class="sr-only">{gettext("Attention:")}</span>
              {Words.log(event)}
            </span>
          </li>
        </ul>
      </.panel>
    </Layouts.app>
    """
  end
end

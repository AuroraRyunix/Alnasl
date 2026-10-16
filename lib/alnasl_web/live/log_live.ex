defmodule AlnaslWeb.LogLive do
  @moduledoc """
  What happened, in sentences: a board connected, a move was recovered, a
  board went out of sync and came back, the arbiter repaired something, the
  server was away and returned. Newest first, and live.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.Log
  alias AlnaslWeb.Components.Pager
  alias AlnaslWeb.Words

  # How far back a search reaches: the newest lines, however many pages.
  @reach 2000

  @empty %{"level" => "", "kind" => "", "board" => "", "q" => "", "all" => ""}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Log.subscribe()

    {:ok,
     socket
     |> assign(page_title: gettext("Log"), filter: @empty, page: 1)
     |> fill()}
  end

  defp fill(socket) do
    filter = socket.assigns.filter
    scope = socket.assigns.current_scope
    ids = board_ids(scope, all?(filter))

    events =
      [
        level: filter["level"],
        kind: filter["kind"],
        board_no: board_no(filter),
        limit: @reach
      ]
      |> Log.list()
      |> Enum.filter(&(mine?(&1, ids) and found?(&1, filter["q"])))

    {rows, page, pages} = Pager.slice(events, socket.assigns.page)

    socket
    |> assign(
      form: to_form(filter, as: :filter),
      count: length(events),
      page: page,
      pages: pages,
      board_ids: ids
    )
    |> stream(:events, rows, reset: true)
  end

  defp all?(filter), do: filter["all"] == "1"

  # Which boards' lines are shown: those of this hall, or of every hall the
  # account may see (`:all` for whoever sees everything, the box's own lines
  # included). A box without accounts has one hall that matters: all.
  defp board_ids(scope, all?) do
    cond do
      scope.open? -> :all
      all? and Alnasl.Accounts.Scope.everything?(scope) -> :all
      all? -> scope |> Alnasl.Halls.visible(Alnasl.Boards.list()) |> MapSet.new(& &1.id)
      true -> scope |> Alnasl.Halls.here(Alnasl.Boards.list()) |> MapSet.new(& &1.id)
    end
  end

  defp mine?(_event, :all), do: true
  defp mine?(event, ids), do: MapSet.member?(ids, event.board_id)

  defp found?(event, q), do: Pager.match?([Words.log(event), where(event), event.kind], q)

  defp board_no(%{"board" => text}) do
    case Integer.parse(text) do
      {n, ""} -> n
      _none -> nil
    end
  end

  defp matches?(event, filter, ids) do
    level_ok =
      case filter["level"] do
        "warn" -> event.level in ["warn", "error"]
        "error" -> event.level == "error"
        _all -> true
      end

    level_ok and String.starts_with?(event.kind, filter["kind"] || "") and
      (board_no(filter) == nil or event.board_no == board_no(filter)) and mine?(event, ids) and
      found?(event, filter["q"])
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter = Map.merge(@empty, Map.take(filter, ~w(level kind board q all)))
    {:noreply, socket |> assign(filter: filter, page: 1) |> fill()}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, socket |> assign(filter: @empty, page: 1) |> fill()}
  end

  def handle_event("page", %{"to" => to}, socket),
    do: {:noreply, socket |> assign(page: Pager.page(to)) |> fill()}

  @impl true
  def handle_info({:log, event}, socket) do
    if event.id && socket.assigns.page == 1 &&
         matches?(event, socket.assigns.filter, socket.assigns.board_ids),
       do:
         {:noreply,
          socket
          |> stream_insert(:events, event, at: 0, limit: Pager.per_page())
          |> assign(count: socket.assigns.count + 1)},
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
      help={:log}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
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
            <label class="sr-only" for="log-q">{gettext("Search the log")}</label>
            <input
              id="log-q"
              type="search"
              name="filter[q]"
              value={@form[:q].value}
              placeholder={gettext("search")}
              phx-debounce="300"
              class="input log-q"
            />
            <label :if={not @current_scope.open?} class="check" for="log-all">
              <input type="hidden" name="filter[all]" value="" />
              <input
                id="log-all"
                type="checkbox"
                name="filter[all]"
                value="1"
                checked={@form[:all].value == "1"}
              />
              {gettext("All my halls")}
            </label>
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
              <span :if={event.level == "warn"} class="sr-only">{gettext("Attention:")}</span> {Words.log(
                event
              )}
            </span>
          </li>
        </ul>

        <AlnaslWeb.Components.Pager.pager id="log-pager" page={@page} pages={@pages} total={@count} />
      </.panel>
    </Layouts.app>
    """
  end
end

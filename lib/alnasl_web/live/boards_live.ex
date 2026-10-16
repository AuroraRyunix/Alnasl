defmodule AlnaslWeb.BoardsLive do
  @moduledoc """
  The physical boards: what is plugged in, what each one reads, how well it
  answers, and which board of the round it is.

  Before a round this is where the arbiter walks down the row: every board
  connected, every starting position right (the check says what is wrong, in
  pieces and squares), every board linked to its number.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Finder, Tables, Tournaments}
  alias AlnaslWeb.{Access, Scope, TableWords, Words}

  # How long a touched board stays lit.
  @found_ms 6_000

  @presets %{
    "none" => %{},
    "mild" => %{"lift" => 0.08, "hover" => 0.05, "slide" => 0.1, "takeback" => 0.03},
    "rough" => %{
      "lift" => 0.15,
      "knock" => 0.08,
      "hover" => 0.1,
      "slide" => 0.2,
      "takeback" => 0.08,
      "swap" => 0.03,
      "missed" => 0.05,
      "clock_miss" => 0.1
    }
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Boards.subscribe()
      Finder.subscribe()
    end

    # The page is about one tournament at a time: the first one shown, until
    # the arbiter picks another.
    first = hd(Tournaments.active())

    {:ok,
     socket
     |> assign(
       page_title: gettext("Boards"),
       refresh_due?: false,
       tid: first.id,
       round: first.round,
       find?: false,
       lit: nil,
       seeking: nil,
       missed: nil,
       swap_form: to_form(%{"a" => "", "b" => ""}, as: :swap)
     )
     |> assign(add_form: add_form(%{}), order_form: to_form(%{"first" => "1"}, as: :order))
     |> load()}
  end

  defp add_form(params) do
    defaults = %{
      "driver" => "simulator",
      "name" => "",
      "port" => "",
      "game" => "1",
      "speed" => "20",
      "faults" => "mild"
    }

    to_form(Map.merge(defaults, params), as: :board)
  end

  defp load(socket) do
    %{tid: tid, round: round} = socket.assigns
    snapshots = Boards.snapshots()
    checks = Tables.checks(tid, round)
    tournaments = Tournaments.list() |> Enum.reject(& &1.gone)

    assign(socket,
      snapshots: snapshots,
      checks: checks,
      ready?: Tables.ready?(checks),
      wizard?: Finder.state().wizard != nil,
      found: Boards.discover(),
      numbers: tid |> Tournaments.boards(round) |> Enum.map(& &1.board),
      rounds: Enum.uniq(Tournaments.rounds(tid) ++ [round]) |> Enum.sort(),
      tournaments: tournaments,
      shown: Tournaments.active(),
      names: Map.new(tournaments, &{&1.id, Tournaments.title(&1) || gettext("This box")}),
      refresh_due?: false
    )
  end

  # A real port: the box asks the line who is on it. One board is a board; two
  # or more are a loop, and each gets a row. Nobody has to know which it is.
  defp add_port(socket, "", _name),
    do: {:noreply, put_flash(socket, :error, gettext("Choose the serial port the board is on."))}

  defp add_port(socket, port, name) do
    case Alnasl.Loops.add(port, name) do
      {:ok, :loop, boards} ->
        {:noreply,
         socket
         |> put_flash(:info, loop_added(boards))
         |> assign(add_form: add_form(%{"driver" => "dgt_serial"}))
         |> load()}

      {:ok, :single, [board]} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("\"%{name}\" added and connected.", name: board.name))
         |> assign(add_form: add_form(%{"driver" => "dgt_serial"}))
         |> load()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, gettext("That board could not be added. Check the fields."))}
    end
  end

  defp loop_added(boards) do
    ngettext(
      "That port is a loop. %{count} board answers on it: %{names}.",
      "That port is a loop. %{count} boards answer on it, each with its own row: %{names}.",
      length(boards),
      names: Enum.map_join(boards, ", ", & &1.name)
    )
  end

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("change_add", %{"board" => params}, socket),
    do: {:noreply, assign(socket, add_form: add_form(params))}

  def handle_event("add", %{"board" => params}, socket) do
    driver = params["driver"]
    count = length(socket.assigns.snapshots)

    name =
      case String.trim(params["name"] || "") do
        "" ->
          if(driver == "simulator",
            do: gettext("Simulator %{n}", n: count + 1),
            else: gettext("Board %{n}", n: count + 1)
          )

        name ->
          name
      end

    if driver == "simulator" do
      attrs = %{
        name: name,
        driver: "simulator",
        port: "sim-#{System.unique_integer([:positive])}",
        options: %{
          "game" => int(params["game"], 1),
          "speed" => int(params["speed"], 20),
          "faults" => Map.get(@presets, params["faults"], %{}),
          # Fast play is more than faults: it is also how quickly the
          # hands move and how late the clock reports.
          "profile" => if(params["faults"] == "bullet", do: "bullet"),
          "seed" => count + 1
        }
      }

      case Boards.create(attrs) do
        {:ok, board} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("\"%{name}\" added and connected.", name: board.name))
           |> assign(add_form: add_form(%{"driver" => driver}))
           |> load()}

        {:error, _changeset} ->
          {:noreply,
           put_flash(socket, :error, gettext("That board could not be added. Check the fields."))}
      end
    else
      add_port(socket, String.trim(params["port"] || ""), name)
    end
  end

  def handle_event("read_as_loop", %{"id" => id}, socket) do
    case Alnasl.Loops.read_as_loop(Boards.get!(id)) do
      {:ok, boards} ->
        {:noreply, socket |> put_flash(:info, loop_added(boards)) |> load()}

      {:error, :not_a_loop} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Only one board answers on that port now. It is read as one board again.")
         )
         |> load()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The port could not be opened. Try again in a moment."))
         |> load()}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    board = Boards.get!(id)
    if board.enabled, do: Boards.disconnect(board), else: Boards.connect(board)
    {:noreply, load(socket)}
  end

  def handle_event("flip", %{"id" => id}, socket) do
    board = Boards.get!(id)

    case Boards.flip(board, not board.flipped) do
      :ok -> {:noreply, load(socket)}
      _not_running -> {:noreply, put_flash(socket, :error, gettext("Connect the board first."))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    board = Boards.get!(id)
    Boards.delete(board)

    {:noreply,
     socket
     |> put_flash(:info, gettext("\"%{name}\" removed. Its game is kept.", name: board.name))
     |> load()}
  end

  def handle_event("link", %{"board_id" => id, "board_no" => value}, socket) do
    board = Boards.get!(id)

    case Integer.parse(value) do
      {number, ""} when number > 0 -> Boards.link(board, socket.assigns.round, number)
      _none -> Boards.unlink(board)
    end

    {:noreply, load(socket)}
  end

  # Which tournament this board plays in: one board, by hand. A range of
  # tables is given to a tournament on the Setup page.
  def handle_event("tournament", %{"board_id" => id, "tournament_id" => value}, socket) do
    with %{} = board <- Boards.get(id),
         {tid, ""} <- Integer.parse(value),
         %{} = tournament <- Tournaments.get(tid) do
      Tables.assign(board, tournament)
    end

    {:noreply, load(socket)}
  end

  def handle_event("pick_tournament", %{"tournament_id" => value}, socket) do
    with {tid, ""} <- Integer.parse(value), %{} = tournament <- Tournaments.get(tid) do
      {:noreply, socket |> assign(tid: tournament.id, round: tournament.round) |> load()}
    else
      _none -> {:noreply, socket}
    end
  end

  def handle_event("link_in_order", %{"order" => %{"first" => first}}, socket) do
    first = int(first, 1)
    Tables.number_in_order(socket.assigns.round, first)
    count = length(socket.assigns.snapshots)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("%{count} board(s) numbered %{from}-%{to}: table and board of round %{round}.",
         count: count,
         from: first,
         to: first + count - 1,
         round: socket.assigns.round
       )
     )
     |> load()}
  end

  # The sticker: which table this board stands on.
  def handle_event("table", %{"board_id" => id, "table_no" => value}, socket) do
    board = Boards.get!(id)

    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 and number < 10_000 -> Tables.set_table(board, number)
      _empty -> if board.table_no, do: Tables.set_table(board, nil)
    end

    {:noreply, load(socket)}
  end

  def handle_event("back_to_table", %{"id" => id}, socket) do
    Tables.clear_remap(Boards.get!(id))
    {:noreply, load(socket)}
  end

  def handle_event("clear_remaps", _params, socket) do
    Tables.clear_remaps()

    {:noreply,
     socket
     |> put_flash(:info, gettext("Every board feeds the board of its table number again."))
     |> load()}
  end

  def handle_event("swap", %{"swap" => %{"a" => a, "b" => b}}, socket) do
    with {a, ""} <- Integer.parse(a),
         {b, ""} <- Integer.parse(b),
         true <- a != b,
         %{} = first <- Boards.get(a),
         %{} = second <- Boards.get(b) do
      Tables.swap(first, second)

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("\"%{a}\" and \"%{b}\" changed places for this round.",
           a: first.name,
           b: second.name
         )
       )
       |> load()}
    else
      _bad ->
        {:noreply, put_flash(socket, :error, gettext("Choose two different boards to swap."))}
    end
  end

  # "Which board is this?": from now on a touched board lights up.
  def handle_event("find_toggle", _params, socket) do
    {:noreply, assign(socket, find?: not socket.assigns.find?, lit: nil)}
  end

  # "Show me": the arbiter goes looking for this one; touching it confirms.
  def handle_event("show_me", %{"id" => id}, socket) do
    {:noreply, assign(socket, seeking: String.to_integer(id), missed: nil)}
  end

  def handle_event("stop_seeking", _params, socket),
    do: {:noreply, assign(socket, seeking: nil, missed: nil)}

  def handle_event("round", %{"round" => round}, socket) do
    {:noreply, socket |> assign(round: int(round, socket.assigns.round)) |> load()}
  end

  def handle_event("rescan", _params, socket), do: {:noreply, load(socket)}

  defp int(text, default) do
    case Integer.parse(to_string(text)) do
      {n, _} when n > 0 -> n
      _bad -> default
    end
  end

  @impl true
  def handle_info({:board, _id}, %{assigns: %{refresh_due?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:board, _id}, socket) do
    Process.send_after(self(), :refresh, 400)
    {:noreply, assign(socket, refresh_due?: true)}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  def handle_info({:finder, {:touch, id, at}}, %{assigns: %{seeking: seeking}} = socket)
      when seeking != nil do
    if id == seeking do
      name = Enum.find_value(socket.assigns.snapshots, &(&1.id == id && &1.name))

      {:noreply,
       socket
       |> assign(seeking: nil, missed: nil)
       |> light(id, at)
       |> put_flash(:info, gettext("That is the one: \"%{name}\".", name: name || "?"))}
    else
      {:noreply, socket |> assign(missed: id) |> light(id, at)}
    end
  end

  def handle_info({:finder, {:touch, id, at}}, %{assigns: %{find?: true}} = socket),
    do: {:noreply, light(socket, id, at)}

  def handle_info({:finder, :wizard}, socket), do: {:noreply, load(socket)}
  def handle_info({:finder, :complete}, socket), do: {:noreply, load(socket)}

  def handle_info({:unfound, at}, %{assigns: %{lit: %{at: at}}} = socket),
    do: {:noreply, assign(socket, lit: nil)}

  def handle_info(_other, socket), do: {:noreply, socket}

  # Lights a row up for a few seconds and brings it into view.
  defp light(socket, id, at) do
    Process.send_after(self(), {:unfound, at}, @found_ms)

    socket
    |> assign(lit: %{id: id, at: at})
    |> push_event("boards:found", %{id: "board-#{id}"})
  end

  defp touched_at(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Words.time()

  # --- page --------------------------------------------------------------------

  defp signal(%{polls_ok: ok, polls_missed: missed}) when ok + missed > 0 do
    percent = round(ok * 100 / (ok + missed))

    tone =
      cond do
        percent >= 98 -> nil
        percent >= 85 -> "warn"
        true -> "bad"
      end

    {percent, tone}
  end

  defp signal(_stats), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:boards}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      title={gettext("Boards")}
      subtitle={gettext("%{n} known", n: length(@snapshots))}
    >
      <:actions>
        <form
          :if={length(@shown) > 1}
          id="boards-tournament-form"
          phx-change="pick_tournament"
          class="row"
        >
          <label for="boards-tournament" class="note">{gettext("Tournament")}</label>
          <select id="boards-tournament" name="tournament_id" class="input" style="width:auto">
            <option :for={t <- @shown} value={t.id} selected={t.id == @tid}>{@names[t.id]}</option>
          </select>
        </form>
        <form id="boards-round-form" phx-change="round" class="row">
          <label for="boards-round" class="note">{gettext("Linking for round")}</label>
          <select id="boards-round" name="round" class="input" style="width:auto">
            <option :for={n <- @rounds} value={n} selected={n == @round}>{n}</option>
          </select>
        </form>
        <.button
          id="find-toggle"
          small
          variant={if @find?, do: "primary"}
          phx-click="find_toggle"
          aria-pressed={to_string(@find?)}
        >
          {gettext("Which board is this?")}
        </.button>
        <.button id="number-by-touch" small navigate={~p"/boards/number"}>
          {gettext("Number by touching")}
        </.button>
        <.button id="print-labels" small href={~p"/files/labels"}>{gettext("Labels")}</.button>
      </:actions>

      <div :if={@find?} id="find-banner" class="callout" role="status">
        <b>{gettext("Lift a piece on the board you mean.")}</b>
        <span>
          {gettext(
            "The board that feels it lights up here for a few seconds. With several boards touched, the last one wins."
          )}
        </span>
        <.link navigate={~p"/boards/find"}>{gettext("Open this on a phone-sized page")}</.link>
      </div>

      <div :if={@seeking} id="seeking-banner" class="callout" role="status">
        <% target = Enum.find(@snapshots, &(&1.id == @seeking)) %>
        <b :if={target}>
          {gettext("Look for \"%{name}\": %{sticker}.",
            name: target.name,
            sticker: TableWords.sticker(target)
          )}
        </b>
        <span>
          {gettext(
            "A DGT board carries its serial number on a label underneath. Lift a piece on the board you think it is: the box says whether you are right."
          )}
        </span>
        <span :if={@missed} id="seeking-missed" class="flag">
          <% other = Enum.find(@snapshots, &(&1.id == @missed)) %>
          {gettext("Not that one - that was \"%{name}\".", name: (other && other.name) || "?")}
        </span>
        <.button id="stop-seeking" small phx-click="stop_seeking">{gettext("Stop looking")}</.button>
      </div>

      <div :if={@wizard?} id="wizard-banner" class="callout" role="status">
        <b>{gettext("Numbering by touch is running.")}</b>
        <span>{gettext("Every board touched for the first time gets the next table number.")}</span>
        <.link navigate={~p"/boards/number"}>{gettext("Go to the run")}</.link>
      </div>

      <.panel
        :if={@snapshots != []}
        id="round-checks"
        title={gettext("Ready for round %{n}?", n: @round)}
      >
        <:actions>
          <.badge :if={@ready?} id="checks-ready" tone="ok" icon="ok">{gettext("Ready")}</.badge>
          <.badge :if={!@ready?} id="checks-not-ready" tone="warn" icon="warning">
            {gettext("Not ready")}
          </.badge>
        </:actions>
        <p :if={@checks == []} id="checks-none" class="note">
          {gettext(
            "Every board answers, has its table number, feeds its own board of the round and shows the starting position - the clock too, where there is one."
          )}
        </p>
        <ul :if={@checks != []} id="checks-list" class="checks">
          <li
            :for={{check, i} <- Enum.with_index(@checks)}
            id={"check-#{i}"}
            class={elem(TableWords.check(check), 0)}
          >
            <.icon name={if check.level == :info, do: "ok", else: "warning"} />
            <span>{elem(TableWords.check(check), 1)}</span>
          </li>
        </ul>
        <.form
          :if={length(@snapshots) > 1}
          for={@swap_form}
          id="swap-form"
          phx-submit="swap"
          class="row"
          style="margin-top:0.8rem"
        >
          <label for="swap-a" class="note">{gettext("For this round, swap the boards of")}</label>
          <select id="swap-a" name="swap[a]" class="input" style="width:auto">
            <option value="">{gettext("choose...")}</option>
            <option :for={s <- @snapshots} value={s.id}>{s.name}</option>
          </select>
          <label for="swap-b" class="note">{gettext("and")}</label>
          <select id="swap-b" name="swap[b]" class="input" style="width:auto">
            <option value="">{gettext("choose...")}</option>
            <option :for={s <- @snapshots} value={s.id}>{s.name}</option>
          </select>
          <.button id="swap-submit" small type="submit">{gettext("Swap")}</.button>
          <.button
            :if={Enum.any?(@snapshots, &Tables.remapped?/1)}
            id="clear-remaps"
            small
            type="button"
            phx-click="clear_remaps"
          >
            {gettext("All back to their table numbers")}
          </.button>
        </.form>
      </.panel>

      <.panel id="board-list" title={gettext("Connected and known boards")} flush>
        <:actions>
          <.form for={@order_form} id="link-in-order-form" phx-submit="link_in_order" class="row">
            <label for="order-first" class="note">{gettext(
              "Number all in connection order, starting at"
            )}</label>
            <input
              id="order-first"
              type="number"
              min="1"
              name="order[first]"
              value={@order_form[:first].value}
              class="input"
              style="width:4.5rem"
            />
            <.button
              id="link-in-order"
              small
              type="submit"
              data-confirm={
                gettext(
                  "Give every board, in the order listed, consecutive table numbers - and link each to that board of round %{n}?",
                  n: @round
                )
              }
            >
              {gettext("Number in order")}
            </.button>
          </.form>
        </:actions>

        <div :if={@snapshots == []} id="boards-empty" class="empty">
          <b>{gettext("No boards yet")}</b>
          <p>
            {gettext(
              "Add a DGT board on a serial port below - or a simulator board, to see everything work without hardware."
            )}
          </p>
        </div>

        <div :if={@snapshots != []} id="boards-wrap" class="table-wrap" phx-hook=".Found">
          <table id="boards-table">
            <thead>
              <tr>
                <th>{gettext("Board")}</th>
                <th>{gettext("Reads")}</th>
                <th>{gettext("State")}</th>
                <th>{gettext("Signal")}</th>
                <th>{gettext("Start position")}</th>
                <th>{gettext("Table")}</th>
                <th>{gettext("Board of round %{n}", n: @round)}</th>
                <th><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={s <- @snapshots}
                id={"board-#{s.id}"}
                class={[@lit && @lit.id == s.id && "found", @seeking == s.id && "sought"]}
              >
                <td class="b-name">
                  <b>{s.name}</b>
                  <.badge :if={Tables.new?(s)} id={"new-board-#{s.id}"} tone="warn" icon="warning">
                    {gettext("New board")}
                  </.badge>
                  <span :if={@lit && @lit.id == s.id} id={"touched-#{s.id}"} class="flag">
                    {gettext("touched %{t}", t: touched_at(@lit.at))}
                  </span>
                  <div class="note">
                    {Words.driver(s.driver)}
                    <span :if={s.driver != "simulator" && s.port}> · {s.port}</span>
                    <span :if={s.driver == "dgt_bus" && s.address} id={"loop-number-#{s.id}"}>
                      · {gettext("answers as %{a}", a: Arkab.Dgt.Bus.number(s.address))}
                    </span>
                  </div>
                  <div
                    :if={s.driver == "dgt_bus" && s.serial in [nil, ""] && s.firmware}
                    id={"loop-no-serial-#{s.id}"}
                    class="note"
                  >
                    {gettext(
                      "This board does not say its serial number on a loop. Plug it into a port of its own once, and the box knows it by its serial number from then on."
                    )}
                  </div>
                  <div
                    :for={o <- Enum.filter(@hall.seating.outside, &(&1.board.id == s.id))}
                    id={"board-outside-#{s.id}"}
                    class="callout warn"
                  >
                    <AlnaslWeb.SeatingComponents.outside_line entry={o} scope="row-" />
                  </div>
                  <div :if={s.serial || s.firmware} id={"identity-#{s.id}"} class="note">
                    <span :if={s.serial}>{gettext("serial %{s}", s: s.serial)}</span>
                    <span :if={s.firmware}> · {gettext("firmware %{v}", v: s.firmware)}</span>
                  </div>
                </td>
                <td class="b-reads">
                  <div class="mini">
                    <.board position={s.raw} label={gettext("What %{name} reads", name: s.name)} />
                  </div>
                  <span :if={s.flipped} class="flag plain">{gettext("turned round")}</span>
                </td>
                <td class="b-state" data-label={gettext("State")}>
                  <.state
                    id={"board-state-#{s.id}"}
                    state={if s.running?, do: s.status, else: :no_signal}
                  />
                  <div :if={!s.running?} class="note">{gettext("Disconnected here")}</div>
                  <div :if={s.info[:error] && !s.connected?} class="note">
                    {gettext("Cannot open the port")}
                  </div>
                  <div
                    :if={s.driver == "dgt_bus" && s.running? && !s.connected? && !s.info[:error]}
                    id={"loop-absent-#{s.id}"}
                    class="note"
                  >
                    {gettext(
                      "Does not answer on the loop: taken off it, switched off, or the cable before it is out. It is back by itself when it answers."
                    )}
                  </div>
                  <div :if={s.info[:loop] && !s.connected?} id={"is-a-loop-#{s.id}"} class="stack">
                    <.badge tone="warn" icon="warning">
                      {ngettext(
                        "More than one board answers on this port: it is a loop.",
                        "More than one board answers on this port (%{count}): it is a loop.",
                        length(s.info[:loop])
                      )}
                    </.badge>
                    <div class="note">
                      {gettext(
                        "Read as one board, a loop gives nonsense: every board answers at once. Nothing is read from it until you say so."
                      )}
                    </div>
                    <.button
                      id={"read-as-loop-#{s.id}"}
                      variant="primary"
                      phx-click="read_as_loop"
                      phx-value-id={s.id}
                      phx-disable-with={gettext("Asking the port...")}
                    >{gettext("Read it as a loop")}</.button>
                  </div>
                </td>
                <td class="b-signal" data-label={gettext("Signal")}>
                  <%= case signal(s.stats) do %>
                    <% {percent, tone} -> %>
                      <span class={["meter", tone]}><i style={"width:#{percent}%"}></i></span>{percent}%
                      <div class="note">
                        {gettext("%{ok} answered, %{missed} missed",
                          ok: s.stats.polls_ok,
                          missed: s.stats.polls_missed
                        )}
                      </div>
                    <% nil -> %>
                      <span class="note">{gettext("%{n} readings", n: s.stats.positions)}</span>
                  <% end %>
                  <div class="note">
                    {gettext("last seen %{t}", t: Words.time(s.last_seen))}
                    <span :if={s.info[:clock]}> · {gettext("clock")}</span>
                    <span :if={s.info[:clock_battery_low]} class="flag">{gettext("clock battery low")}</span>
                  </div>
                </td>
                <td class="b-start" data-label={gettext("Start position")}>
                  <%= cond do %>
                    <% s.raw == nil -> %>
                      <span class="note">-</span>
                    <% s.plies != [] -> %>
                      <span class="note">{gettext("game under way")}</span>
                      <span
                        :if={Enum.any?(s.plies, &(:guessed in &1.flags))}
                        id={"guessed-#{s.id}"}
                        class="flag guess"
                      >
                        {Words.marks(:guessed, Enum.count(s.plies, &(:guessed in &1.flags)))}
                      </span>
                      <span
                        :if={Enum.any?(s.plies, &(:recovered in &1.flags))}
                        id={"reconstructed-#{s.id}"}
                        class="flag rec"
                      >
                        {Words.marks(:recovered, Enum.count(s.plies, &(:recovered in &1.flags)))}
                      </span>
                      <.badge
                        :for={piece <- s[:unseen] || []}
                        id={"unseen-#{s.id}"}
                        tone="warn"
                        icon="warning"
                      >
                        {Words.unseen(piece)}
                      </.badge>
                    <% s.problems == [] and Words.clock_problem(s[:clock_check]) -> %>
                      <.badge id={"start-clock-#{s.id}"} tone="warn" icon="warning">
                        {gettext("Clock wrong")}
                      </.badge>
                      <div class="note" style="margin-top:0.2rem">
                        {Words.clock_problem(s[:clock_check])}
                      </div>
                    <% s.problems == [] -> %>
                      <.badge id={"start-ok-#{s.id}"} tone="ok" icon="ok">{gettext("Right")}</.badge>
                      <div :if={s[:clock_check] == :ok} id={"start-clock-ok-#{s.id}"} class="note">
                        {gettext("pieces and clock")}
                      </div>
                    <% true -> %>
                      <.badge id={"start-wrong-#{s.id}"} tone="warn" icon="warning">
                        {gettext("%{n} wrong", n: length(s.problems))}
                      </.badge>
                      <ul class="note" style="margin:0.2rem 0 0;padding-left:1rem">
                        <li :for={p <- Enum.take(s.problems, 3)}>{Words.problem(p)}</li>
                        <li :if={length(s.problems) > 3}>
                          {gettext("...and %{n} more", n: length(s.problems) - 3)}
                        </li>
                        <li :if={Words.clock_problem(s[:clock_check])} id={"start-clock-#{s.id}"}>
                          {Words.clock_problem(s[:clock_check])}
                        </li>
                      </ul>
                  <% end %>
                </td>
                <td class="b-table">
                  <form id={"table-form-#{s.id}"} phx-change="table" phx-submit="table">
                    <input type="hidden" name="board_id" value={s.id} />
                    <label class="sr-only" for={"table-#{s.id}"}>{gettext("Table number of %{name}",
                      name: s.name
                    )}</label>
                    <input
                      id={"table-#{s.id}"}
                      type="number"
                      inputmode="numeric"
                      min="1"
                      max="9999"
                      name="table_no"
                      value={s.table_no}
                      placeholder={gettext("no.")}
                      class="input table-no"
                      phx-debounce="blur"
                    />
                  </form>
                  <form
                    :if={length(@tournaments) > 1}
                    id={"tournament-form-#{s.id}"}
                    phx-change="tournament"
                  >
                    <input type="hidden" name="board_id" value={s.id} />
                    <label class="sr-only" for={"tournament-#{s.id}"}>{gettext(
                      "Tournament of %{name}",
                      name: s.name
                    )}</label>
                    <select
                      id={"tournament-#{s.id}"}
                      name="tournament_id"
                      class="input"
                      style="width:auto;max-width:11rem"
                    >
                      <option
                        :for={t <- @tournaments}
                        value={t.id}
                        selected={t.id == s[:tournament_id]}
                      >
                        {@names[t.id]}
                      </option>
                    </select>
                  </form>
                </td>
                <td
                  :if={s[:tournament_id] != @tid}
                  id={"elsewhere-#{s.id}"}
                  class="b-link"
                  data-label={gettext("Board of round %{n}", n: @round)}
                >
                  <span class="note">
                    <%= if s.board_no && s.round do %>
                      {gettext("%{name}: round %{r}, board %{n}",
                        name: @names[s[:tournament_id]] || "?",
                        r: s.round,
                        n: s.board_no
                      )}
                    <% else %>
                      {gettext("%{name}: not linked", name: @names[s[:tournament_id]] || "?")}
                    <% end %>
                  </span>
                </td>
                <td
                  :if={s[:tournament_id] == @tid}
                  class="b-link"
                  data-label={gettext("Board of round %{n}", n: @round)}
                >
                  <form id={"link-form-#{s.id}"} phx-change="link">
                    <input type="hidden" name="board_id" value={s.id} />
                    <label class="sr-only" for={"link-#{s.id}"}>{gettext("Board number for %{name}",
                      name: s.name
                    )}</label>
                    <select id={"link-#{s.id}"} name="board_no" class="input" style="width:auto">
                      <option value="">{gettext("not linked")}</option>
                      <option
                        :for={
                          n <-
                            Enum.uniq(
                              @numbers ++
                                if(s.round == @round && s.board_no, do: [s.board_no], else: [])
                            )
                            |> Enum.sort()
                        }
                        value={n}
                        selected={s.round == @round and s.board_no == n}
                      >
                        {gettext("board %{n}", n: n)}
                      </option>
                    </select>
                  </form>
                  <div :if={s.round == @round and Tables.remapped?(s)} class="note">
                    <span id={"remapped-#{s.id}"} class="flag plain">
                      {gettext("table %{t} plays board %{b}", t: s.table_no, b: s.board_no)}
                    </span>
                    <.button
                      id={"back-to-table-#{s.id}"}
                      small
                      variant="ghost"
                      phx-click="back_to_table"
                      phx-value-id={s.id}
                    >
                      {gettext("Back to board %{n}", n: Tables.home_board(s) || s.table_no)}
                    </.button>
                  </div>
                  <div :if={s.board_no && s.round != @round} class="note">
                    {gettext("linked to round %{r}, board %{n}", r: s.round, n: s.board_no)}
                  </div>
                </td>
                <td class="act">
                  <.button
                    :if={s.board_no && s.round}
                    id={"open-#{s.id}"}
                    small
                    navigate={Scope.game_path(s[:tournament_id], s.round, s.board_no)}
                  >{gettext("Open")}</.button>
                  <.button id={"show-me-#{s.id}"} small phx-click="show_me" phx-value-id={s.id}>
                    {gettext("Show me")}
                  </.button>
                  <.button id={"toggle-#{s.id}"} small phx-click="toggle" phx-value-id={s.id}>
                    {if s.running?, do: gettext("Disconnect"), else: gettext("Connect")}
                  </.button>
                  <.button
                    id={"flip-#{s.id}"}
                    small
                    icon="flip"
                    phx-click="flip"
                    phx-value-id={s.id}
                    aria-label={gettext("Turn %{name} round", name: s.name)}
                    title={gettext("Turn the board round")}
                  >
                    <span class="sr-only">{gettext("Turn round")}</span>
                  </.button>
                  <.button
                    id={"delete-#{s.id}"}
                    small
                    variant="danger"
                    phx-click="delete"
                    phx-value-id={s.id}
                    data-confirm={
                      gettext("Remove \"%{name}\"? Its game and captures are kept.", name: s.name)
                    }
                  >
                    {gettext("Remove")}
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Found">
        // Brings the board that was just touched into view.
        export default {
          mounted() {
            this.handleEvent("boards:found", ({id}) => {
              const row = document.getElementById(id)
              if (row) row.scrollIntoView({block: "center", behavior: "smooth"})
            })
          }
        }
      </script>

      <div class="cols">
        <.panel id="phone" title={gettext("Open this site on your phone")}>
          <Access.phone id="phone-access" path="/boards/number" />
        </.panel>

        <.panel id="add-board" title={gettext("Add a board")}>
          <.form
            for={@add_form}
            id="add-board-form"
            phx-change="change_add"
            phx-submit="add"
            class="stack"
          >
            <div class="form-grid">
              <.input
                field={@add_form[:driver]}
                id="add-driver"
                type="select"
                label={gettext("Kind")}
                options={[
                  {gettext("Simulator (no hardware)"), "simulator"},
                  {gettext("DGT board, or several on a loop (serial port)"), "dgt_serial"}
                ]}
              />
              <.input
                field={@add_form[:name]}
                id="add-name"
                label={gettext("Name")}
                placeholder={gettext("optional")}
              />
              <%= if @add_form[:driver].value == "simulator" do %>
                <.input
                  field={@add_form[:game]}
                  id="add-game"
                  type="number"
                  min="1"
                  max={@found.games}
                  label={gettext("Game to play (1-%{n})", n: @found.games)}
                />
                <.input
                  field={@add_form[:speed]}
                  id="add-speed"
                  type="number"
                  min="1"
                  max="2000"
                  label={gettext("Times faster than life")}
                />
                <.input
                  field={@add_form[:faults]}
                  id="add-faults"
                  type="select"
                  label={gettext("Hands")}
                  options={[
                    {gettext("Perfect"), "none"},
                    {gettext("Ordinary (lifts, slides, a takeback)"), "mild"},
                    {gettext("Rough (knocks, swaps, missed moves)"), "rough"},
                    {gettext("Bullet (a move a second, slammed and knocked-over pieces)"), "bullet"}
                  ]}
                />
              <% else %>
                <.input
                  field={@add_form[:port]}
                  id="add-port"
                  type="select"
                  label={gettext("Serial port")}
                  prompt={gettext("choose...")}
                  options={
                    for p <- @found.ports,
                        do:
                          {if(p.description != "", do: "#{p.port} - #{p.description}", else: p.port),
                           p.port}
                  }
                />
              <% end %>
            </div>
            <p :if={@add_form[:driver].value != "simulator"} id="add-loop-note" class="note">
              {gettext(
                "One board or a loop of them: the box asks the port who is on it, which takes a few seconds, and gives every board that answers a row of its own."
              )}
            </p>
            <p :if={@add_form[:driver].value != "simulator"} id="add-known-note" class="note">
              {gettext(
                "A board the box already knows is recognised by its serial number, whichever port it is on now: it keeps its table number."
              )}
            </p>
            <div class="row">
              <.button
                id="add-board-submit"
                variant="primary"
                type="submit"
                phx-disable-with={gettext("Asking the port...")}
              >{gettext("Add and connect")}</.button>
            </div>
          </.form>
        </.panel>

        <.panel id="ports" title={gettext("Serial ports on this machine")}>
          <:actions>
            <.button id="rescan" small phx-click="rescan">{gettext("Look again")}</.button>
          </:actions>
          <p :if={!@found.serial?} id="no-serial" class="note">
            {gettext(
              "The serial port library is not built into this copy of Alnasl, so real boards cannot be opened here. Simulator boards work. The installed versions have it; a copy built from the source code on Windows has it when asked for (README, \"Serial ports\")."
            )}
          </p>
          <p :if={@found.serial? and @found.ports == []} class="note">
            {gettext("No serial port found. Plug in the board or its adapter and look again.")}
          </p>
          <table :if={@found.ports != []} id="ports-table">
            <thead>
              <tr>
                <th>{gettext("Port")}</th>
                <th>{gettext("What it says it is")}</th>
                <th>{gettext("Used by")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @found.ports}>
                <td class="mono">{p.port}</td>
                <td>{p.description}</td>
                <td>{p.used_by || "-"}</td>
              </tr>
            </tbody>
          </table>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end

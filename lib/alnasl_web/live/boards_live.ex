defmodule AlnaslWeb.BoardsLive do
  @moduledoc """
  The physical boards: what is plugged in, what each one reads, how well it
  answers, and which board of the round it is.

  Before a round this is where the arbiter walks down the row: every board
  connected, every starting position right (the check says what is wrong, in
  pieces and squares), every board linked to its number.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Settings, Tournament}
  alias AlnaslWeb.Words

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
    if connected?(socket), do: Boards.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Boards"),
       refresh_due?: false,
       round: Settings.get("round") || 1
     )
     |> assign(add_form: add_form(%{}), order_form: to_form(%{"first" => "1"}, as: :order))
     |> load()}
  end

  defp add_form(params) do
    defaults = %{
      "driver" => "simulator",
      "name" => "",
      "port" => "",
      "address" => "",
      "game" => "1",
      "speed" => "20",
      "faults" => "mild"
    }

    to_form(Map.merge(defaults, params), as: :board)
  end

  defp load(socket) do
    round = socket.assigns.round
    snapshots = Boards.snapshots()

    assign(socket,
      snapshots: snapshots,
      found: Boards.discover(),
      numbers: round |> Tournament.boards() |> Enum.map(& &1.board),
      rounds: Enum.uniq(Tournament.rounds() ++ [round]) |> Enum.sort(),
      refresh_due?: false
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

    address =
      case Integer.parse(params["address"] || "") do
        {n, ""} -> n
        _none -> nil
      end

    attrs =
      case driver do
        "simulator" ->
          %{
            name: name,
            driver: "simulator",
            port: "sim-#{System.unique_integer([:positive])}",
            options: %{
              "game" => int(params["game"], 1),
              "speed" => int(params["speed"], 20),
              "faults" => Map.get(@presets, params["faults"], %{}),
              "seed" => count + 1
            }
          }

        driver when driver in ["dgt_serial", "dgt_bus"] ->
          %{
            name: name,
            driver: driver,
            port: String.trim(params["port"] || ""),
            address: address,
            options: %{}
          }
      end

    cond do
      driver in ["dgt_serial", "dgt_bus"] and attrs.port == "" ->
        {:noreply, put_flash(socket, :error, gettext("Choose the serial port the board is on."))}

      driver == "dgt_bus" and address == nil ->
        {:noreply, put_flash(socket, :error, gettext("A board on a loop needs its bus address."))}

      true ->
        case Boards.create(attrs) do
          {:ok, board} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("\"%{name}\" added and connected.", name: board.name))
             |> assign(add_form: add_form(%{"driver" => driver}))
             |> load()}

          {:error, _changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("That board could not be added. Check the fields.")
             )}
        end
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

  def handle_event("link_in_order", %{"order" => %{"first" => first}}, socket) do
    first = int(first, 1)
    Boards.link_in_order(socket.assigns.round, first)
    count = length(socket.assigns.snapshots)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("%{count} board(s) linked to boards %{from}-%{to} of round %{round}.",
         count: count,
         from: first,
         to: first + count - 1,
         round: socket.assigns.round
       )
     )
     |> load()}
  end

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
  def handle_info(_other, socket), do: {:noreply, socket}

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
      box={@box}
      locale={@locale}
      title={gettext("Boards")}
      subtitle={gettext("%{n} known", n: length(@snapshots))}
    >
      <:actions>
        <form id="boards-round-form" phx-change="round" class="row">
          <label for="boards-round" class="note">{gettext("Linking for round")}</label>
          <select id="boards-round" name="round" class="input" style="width:auto">
            <option :for={n <- @rounds} value={n} selected={n == @round}>{n}</option>
          </select>
        </form>
      </:actions>

      <.panel id="board-list" title={gettext("Connected and known boards")} flush>
        <:actions>
          <.form for={@order_form} id="link-in-order-form" phx-submit="link_in_order" class="row">
            <label for="order-first" class="note">{gettext("Link all in order, starting at board")}</label>
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
                  "Link every board, in the order listed, to consecutive board numbers of round %{n}?",
                  n: @round
                )
              }
            >
              {gettext("Link in order")}
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

        <div :if={@snapshots != []} class="table-wrap">
          <table id="boards-table">
            <thead>
              <tr>
                <th>{gettext("Board")}</th>
                <th>{gettext("Reads")}</th>
                <th>{gettext("State")}</th>
                <th>{gettext("Signal")}</th>
                <th>{gettext("Start position")}</th>
                <th>{gettext("Board of round %{n}", n: @round)}</th>
                <th><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @snapshots} id={"board-#{s.id}"}>
                <td>
                  <b>{s.name}</b>
                  <div class="note">
                    {Words.driver(s.driver)}
                    <span :if={s.driver != "simulator" && s.port}> · {s.port}</span>
                    <span :if={s.address}> · {gettext("address %{a}", a: s.address)}</span>
                  </div>
                  <div :if={s.serial || s.firmware} class="note">
                    <span :if={s.serial}>{gettext("serial %{s}", s: s.serial)}</span>
                    <span :if={s.firmware}> · {gettext("firmware %{v}", v: s.firmware)}</span>
                  </div>
                </td>
                <td>
                  <div class="mini">
                    <.board position={s.raw} label={gettext("What %{name} reads", name: s.name)} />
                  </div>
                  <span :if={s.flipped} class="flag plain">{gettext("turned round")}</span>
                </td>
                <td>
                  <.state
                    id={"board-state-#{s.id}"}
                    state={if s.running?, do: s.status, else: :no_signal}
                  />
                  <div :if={!s.running?} class="note">{gettext("Disconnected here")}</div>
                  <div :if={s.info[:error] && !s.connected?} class="note">
                    {gettext("Cannot open the port")}
                  </div>
                </td>
                <td>
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
                <td>
                  <%= cond do %>
                    <% s.raw == nil -> %>
                      <span class="note">-</span>
                    <% s.plies != [] -> %>
                      <span class="note">{gettext("game under way")}</span>
                    <% s.problems == [] -> %>
                      <.badge id={"start-ok-#{s.id}"} tone="ok" icon="ok">{gettext("Right")}</.badge>
                    <% true -> %>
                      <.badge id={"start-wrong-#{s.id}"} tone="warn" icon="warning">
                        {gettext("%{n} wrong", n: length(s.problems))}
                      </.badge>
                      <ul class="note" style="margin:0.2rem 0 0;padding-left:1rem">
                        <li :for={p <- Enum.take(s.problems, 3)}>{Words.problem(p)}</li>
                        <li :if={length(s.problems) > 3}>
                          {gettext("...and %{n} more", n: length(s.problems) - 3)}
                        </li>
                      </ul>
                  <% end %>
                </td>
                <td>
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
                  <div :if={s.board_no && s.round != @round} class="note">
                    {gettext("linked to round %{r}, board %{n}", r: s.round, n: s.board_no)}
                  </div>
                </td>
                <td class="act">
                  <.button
                    :if={s.board_no && s.round}
                    id={"open-#{s.id}"}
                    small
                    navigate={~p"/round/#{s.round}/board/#{s.board_no}"}
                  >{gettext("Open")}</.button>
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

      <div class="cols">
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
                  {gettext("DGT board on its own serial port"), "dgt_serial"},
                  {gettext("DGT board on a loop (bus) - not verified"), "dgt_bus"}
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
                    {gettext("Rough (knocks, swaps, missed moves)"), "rough"}
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
                <.input
                  :if={@add_form[:driver].value == "dgt_bus"}
                  field={@add_form[:address]}
                  id="add-address"
                  type="number"
                  min="1"
                  label={gettext("Bus address")}
                />
              <% end %>
            </div>
            <p :if={@add_form[:driver].value == "dgt_bus"} id="bus-warning" class="note">
              {gettext(
                "The loop's wire format has not been checked against real boards yet. See docs/tomorrow.md."
              )}
            </p>
            <div class="row">
              <.button id="add-board-submit" variant="primary" type="submit">{gettext(
                "Add and connect"
              )}</.button>
            </div>
          </.form>
        </.panel>

        <.panel id="ports" title={gettext("Serial ports on this machine")}>
          <:actions>
            <.button id="rescan" small phx-click="rescan">{gettext("Look again")}</.button>
          </:actions>
          <p :if={!@found.serial?} id="no-serial" class="note">
            {gettext(
              "The serial port library is not built into this copy of Alnasl, so real boards cannot be opened here. Simulator boards work. See the README (\"Serial ports\")."
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

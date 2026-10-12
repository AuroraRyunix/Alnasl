defmodule AlnaslWeb.WalkLive do
  @moduledoc """
  Two pages for an arbiter walking the hall with a phone in one hand.

  **Number the boards** (`/boards/number`): start, then lift a piece on table
  1's board, then table 2's... The number that comes next fills the screen;
  each board that registers answers with a flash, its number and serial, a
  short buzz and a beep. Undo, Skip and Stop sit under the thumb.

  **Which board is this?** (`/boards/find`): lift a piece on any board and
  the page says which one it is.

  Nothing of the run is kept in this page. It is on the box
  (`Alnasl.Finder`), so a phone that drops off the Wi-Fi between two tables
  comes back to the run where it stands, and the same page open on the box's
  own screen shows the same thing at the same time.

  Both pages are behind the same door as the rest of the site
  (`AlnaslWeb.Hall`): with a PIN set, a spectator's phone gets the PIN
  question and nothing else.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Finder}
  alias AlnaslWeb.{TableWords, Words}

  @fresh_ms 6_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Finder.subscribe()
      Boards.subscribe()
    end

    {:ok,
     socket
     |> assign(flash_event: nil, start_form: to_form(%{"first" => "1"}, as: :walk), fresh: nil)
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    title =
      case socket.assigns.live_action do
        :number -> gettext("Number the boards")
        :find -> gettext("Which board is this?")
      end

    {:noreply, assign(socket, page_title: title)}
  end

  defp load(socket) do
    state = Finder.state()
    boards = Map.new(Boards.list(), &{&1.id, &1})

    recent =
      state.touches
      |> Enum.sort_by(fn {_id, at} -> -at end)
      |> Enum.take(6)
      |> Enum.flat_map(fn {id, at} ->
        case boards[id] do
          nil -> []
          board -> [%{board: board, at: at}]
        end
      end)

    assign(socket,
      wizard: state.wizard,
      recent: recent,
      board_count: map_size(boards),
      numbered: Enum.count(boards, fn {_id, b} -> b.table_no != nil end)
    )
  end

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("start", %{"walk" => %{"first" => first}}, socket) do
    first =
      case Integer.parse(first) do
        {n, _} when n > 0 and n < 10_000 -> n
        _bad -> 1
      end

    Finder.start_wizard(first)
    {:noreply, socket |> assign(flash_event: nil) |> load()}
  end

  def handle_event("undo", _params, socket) do
    Finder.undo()
    {:noreply, socket |> assign(flash_event: nil) |> load()}
  end

  def handle_event("skip", _params, socket) do
    Finder.skip()
    {:noreply, load(socket)}
  end

  def handle_event("stop", _params, socket) do
    Finder.stop()
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:finder, {:assigned, entry}}, socket) do
    {:noreply,
     socket
     |> assign(flash_event: {:assigned, entry})
     |> push_event("walk:buzz", %{kind: "assigned"})
     |> load()}
  end

  def handle_info({:finder, {:already, entry}}, socket) do
    {:noreply,
     socket
     |> assign(flash_event: {:already, entry})
     |> push_event("walk:buzz", %{kind: "already"})}
  end

  def handle_info({:finder, :complete}, socket) do
    {:noreply, socket |> assign(flash_event: :complete) |> load()}
  end

  def handle_info({:finder, {:touch, id, at}}, socket) do
    socket = load(socket)

    if socket.assigns.live_action == :find do
      Process.send_after(self(), {:fade, at}, @fresh_ms)
      {:noreply, socket |> assign(fresh: {id, at}) |> push_event("walk:buzz", %{kind: "touch"})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:finder, _other}, socket), do: {:noreply, load(socket)}

  def handle_info({:fade, at}, %{assigns: %{fresh: {_id, at}}} = socket),
    do: {:noreply, assign(socket, fresh: nil)}

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- page --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:boards}
      link={@link}
      box={@box}
      locale={@locale}
      title={@page_title}
    >
      <:actions>
        <.button id="walk-back" small navigate={~p"/boards"}>{gettext("Back to Boards")}</.button>
      </:actions>

      <div id="walk" class="walk" phx-hook=".Buzz">
        <div class="seg walk-tabs" role="group" aria-label={gettext("What to do")}>
          <.link
            id="walk-tab-number"
            patch={~p"/boards/number"}
            aria-current={to_string(@live_action == :number)}
          >
            {gettext("Number")}
          </.link>
          <.link
            id="walk-tab-find"
            patch={~p"/boards/find"}
            aria-current={to_string(@live_action == :find)}
          >
            {gettext("Find")}
          </.link>
        </div>

        <%!-- ignored by the patch: the hook owns what this shows, and a
              re-render must not put "Sound off" back over a context that is
              running --%>
        <div id="walk-sound" class="walk-sound" phx-update="ignore">
          <button
            id="walk-mute"
            type="button"
            class="btn small walk-mute"
            data-mute
            data-state="off"
            aria-pressed="false"
            aria-label={gettext("Sound on or off")}
          >
            <span data-for="on" hidden>{gettext("Sound on")}</span>
            <span data-for="off">{gettext("Sound off")}</span>
            <span data-for="tap" hidden>{gettext("Tap to enable sound")}</span>
            <span data-for="blocked" hidden>{gettext("Sound blocked by the browser")}</span>
          </button>
          <p class="note">
            {gettext(
              "The beep needs the browser's permission, which a tap gives. An iPhone plays nothing with the ring/silent switch on silent, and iPhones do not vibrate; Android phones do."
            )}
          </p>
        </div>

        <%= if @live_action == :number do %>
          <.number_page
            wizard={@wizard}
            flash_event={@flash_event}
            start_form={@start_form}
            board_count={@board_count}
            numbered={@numbered}
          />
        <% else %>
          <.find_page recent={@recent} fresh={@fresh} />
        <% end %>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Buzz">
        // The phone's answer to a touch on a board: a buzz, and a beep that
        // has to be switched on. A phone keeps sound locked until a tap, so
        // the tap on the switch makes the context and beeps at once, the
        // context lives on window (a re-render or a reconnect does not lose
        // it) and every later beep asks it to resume first. Web Audio needs
        // no secure context; vibrate exists on Android only.
        const KEY = "alnasl-walk-sound"
        const wanted = () => { try { return localStorage.getItem(KEY) === "1" } catch (_e) { return false } }
        const remember = (on) => { try { localStorage.setItem(KEY, on ? "1" : "0") } catch (_e) { /* private mode */ } }
        const context = () => {
          const Ctx = window.AudioContext || window.webkitAudioContext
          if (!window.alnaslAudio && Ctx) { try { window.alnaslAudio = new Ctx() } catch (_e) { /* no sound here */ } }
          return window.alnaslAudio
        }

        export default {
          mounted() {
            this.blocked = false
            this.onClick = (event) => {
              if (event.target.closest("[data-mute]")) return this.toggle()
              if (wanted() && !this.running()) this.unlock(false)
            }
            this.onVisible = () => { if (document.visibilityState === "visible" && wanted()) this.resumeQuietly() }
            this.el.addEventListener("click", this.onClick)
            document.addEventListener("visibilitychange", this.onVisible)
            this.handleEvent("walk:buzz", ({kind}) => {
              if (navigator.vibrate) {
                try { navigator.vibrate(kind === "already" ? [40, 60, 40] : 90) } catch (_e) { /* not allowed */ }
              }
              if (wanted()) this.play(kind === "already" ? 330 : 880)
            })
            this.show()
          },
          updated() { this.show() },
          destroyed() { document.removeEventListener("visibilitychange", this.onVisible) },
          running() { return !!window.alnaslAudio && window.alnaslAudio.state === "running" },
          state() {
            if (!wanted()) return "off"
            if (this.running()) return "on"
            return this.blocked ? "blocked" : "tap"
          },
          show() {
            const button = document.getElementById("walk-mute")
            if (!button) return
            const state = this.state()
            button.dataset.state = state
            button.setAttribute("aria-pressed", String(state === "on"))
            button.querySelectorAll("[data-for]").forEach((span) => { span.hidden = span.dataset.for !== state })
          },
          toggle() {
            if (wanted() && this.running()) {
              remember(false)
              this.show()
            } else {
              remember(true)
              this.unlock(true)
            }
          },
          // Inside a tap: make the context, start a tone at once (iOS wants
          // the sound begun in the gesture), then see whether it runs.
          unlock(confirm) {
            const ctx = context()
            if (!ctx) { this.blocked = true; return this.show() }
            this.blocked = false
            if (confirm) this.beep(ctx, 660)
            const check = () => {
              this.blocked = ctx.state !== "running"
              this.show()
            }
            let settled = false
            const once = () => { if (!settled) { settled = true; check() } }
            try { ctx.resume().then(once, once) } catch (_e) { once() }
            setTimeout(once, 700)
            ctx.onstatechange = () => this.show()
            this.show()
          },
          resumeQuietly() {
            const ctx = window.alnaslAudio
            if (!ctx || ctx.state === "running") return this.show()
            try { ctx.resume().then(() => this.show(), () => this.show()) } catch (_e) { this.show() }
          },
          play(frequency) {
            const ctx = context()
            if (!ctx) return
            if (ctx.state === "running") return this.beep(ctx, frequency)
            const fail = () => { this.blocked = true; this.show() }
            try {
              ctx.resume().then(() => {
                if (ctx.state === "running") { this.blocked = false; this.show(); this.beep(ctx, frequency) } else fail()
              }, fail)
            } catch (_e) { fail() }
          },
          beep(ctx, frequency) {
            const now = ctx.currentTime
            const tone = ctx.createOscillator()
            const gain = ctx.createGain()
            tone.frequency.value = frequency
            gain.gain.setValueAtTime(0.0001, now)
            gain.gain.exponentialRampToValueAtTime(0.35, now + 0.01)
            gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.2)
            tone.connect(gain).connect(ctx.destination)
            tone.start(now)
            tone.stop(now + 0.22)
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :wizard, :any, required: true
  attr :flash_event, :any, required: true
  attr :start_form, :any, required: true
  attr :board_count, :integer, required: true
  attr :numbered, :integer, required: true

  defp number_page(assigns) do
    ~H"""
    <%= if @wizard do %>
      <section id="walk-run" class="walk-stage" aria-live="polite">
        <p class="walk-ask">{gettext("Lift a piece on the board of table")}</p>
        <div id="walk-next" class="walk-number">{@wizard.next}</div>
        <p class="note">
          {gettext("%{done} of %{all} board(s) numbered in this run.",
            done: length(@wizard.done),
            all: @board_count
          )}
        </p>
        <.walk_flash event={@flash_event} />
      </section>

      <ol :if={@wizard.done != []} id="walk-done" class="walk-list">
        <li :for={entry <- @wizard.done} id={"walk-done-#{entry.board_id}"}>
          <b>{entry.table}</b>
          <span>{entry.name}</span>
          <span class="note">{serial(entry)}</span>
        </li>
      </ol>

      <div id="walk-keys" class="walk-keys">
        <.button
          id="walk-undo"
          phx-click="undo"
          disabled={@wizard.done == [] and @wizard.skipped == []}
        >
          {gettext("Undo")}
        </.button>
        <.button id="walk-skip" phx-click="skip">
          {gettext("Skip %{n}", n: @wizard.next)}
        </.button>
        <.button id="walk-stop" variant="primary" phx-click="stop">{gettext("Stop")}</.button>
      </div>
    <% else %>
      <section id="walk-start" class="walk-stage">
        <.walk_flash event={@flash_event} />
        <p class="walk-ask">{gettext("Number the boards by touching them")}</p>
        <p>
          {gettext(
            "Press Start, walk to table 1 and lift any piece on its board. Put it back, walk to table 2, lift a piece there - and so on. Each board gets the next number the moment it feels the piece go."
          )}
        </p>
        <p id="walk-count" class="note">
          {gettext("%{numbered} of %{all} board(s) have a table number now.",
            numbered: @numbered,
            all: @board_count
          )}
        </p>
        <.form for={@start_form} id="walk-start-form" phx-submit="start" class="walk-start-form">
          <label for="walk-first">{gettext("First table number")}</label>
          <input
            id="walk-first"
            class="input walk-first"
            type="number"
            inputmode="numeric"
            min="1"
            max="9999"
            name="walk[first]"
            value={@start_form[:first].value}
          />
          <.button id="walk-start-button" variant="primary" type="submit" class="walk-go">
            {gettext("Start")}
          </.button>
        </.form>
        <p class="note">
          {gettext(
            "Do this before the round, with the pieces set up and nobody at the boards: during play every move is a touch. The run stops by itself when every board has a number, or after fifteen minutes without a touch."
          )}
        </p>
      </section>
    <% end %>
    """
  end

  attr :event, :any, required: true

  defp walk_flash(assigns) do
    ~H"""
    <%= case @event do %>
      <% {:assigned, entry} -> %>
        <div id={"walk-flash-#{entry.table}"} class="walk-flash ok" role="status">
          <.icon name="ok" />
          <div>
            <b>{gettext("Table %{n}", n: entry.table)}</b>
            <span>{serial(entry)} · {entry.name}</span>
          </div>
        </div>
      <% {:already, entry} -> %>
        <div id={"walk-flash-again-#{entry.table}"} class="walk-flash" role="status">
          <.icon name="waiting" />
          <div>
            <b>{gettext("Already table %{n}", n: entry.table)}</b>
            <span>{serial(entry)} · {entry.name}</span>
          </div>
        </div>
      <% :complete -> %>
        <div id="walk-flash-complete" class="walk-flash ok" role="status">
          <.icon name="ok" />
          <div>
            <b>{gettext("Every board has a number")}</b>
            <span>{gettext("The run has stopped.")}</span>
          </div>
        </div>
      <% _none -> %>
        <div id="walk-flash-none" class="walk-flash quiet" role="status">
          <span>{gettext("Waiting for a touch...")}</span>
        </div>
    <% end %>
    """
  end

  attr :recent, :list, required: true
  attr :fresh, :any, required: true

  defp find_page(assigns) do
    ~H"""
    <section id="walk-find" class="walk-stage" aria-live="polite">
      <p class="walk-ask">{gettext("Lift a piece on the board you mean")}</p>
      <%= case @recent do %>
        <% [%{board: board, at: at} | _] -> %>
          <div
            id="walk-found"
            class={["walk-found", match?({id, _} when id == board.id, @fresh) && "fresh"]}
          >
            <%= if board.board_no do %>
              <span class="walk-label">{gettext("Board")}</span>
              <div id="walk-found-number" class="walk-number">{board.board_no}</div>
            <% else %>
              <span class="walk-label">{gettext("New board")}</span>
              <div id="walk-found-number" class="walk-number small">?</div>
            <% end %>
            <p id="walk-found-sticker"><b>{TableWords.sticker(board)}</b></p>
            <p class="note">
              {board.name} · {gettext("touched at %{t}", t: time(at))}
            </p>
            <.button
              :if={board.board_no && board.round}
              id="walk-found-open"
              navigate={
                AlnaslWeb.Scope.game_path(Map.get(board, :tournament_id), board.round, board.board_no)
              }
            >
              {gettext("Open this board")}
            </.button>
          </div>
        <% [] -> %>
          <div id="walk-found-none" class="walk-flash quiet" role="status">
            <span>{gettext("No board has been touched yet.")}</span>
          </div>
      <% end %>
    </section>

    <ol :if={length(@recent) > 1} id="walk-recent" class="walk-list">
      <li :for={%{board: board, at: at} <- tl(@recent)} id={"walk-recent-#{board.id}"}>
        <b>{board.board_no || "?"}</b>
        <span>{TableWords.sticker(board)}</span>
        <span class="note">{time(at)}</span>
      </li>
    </ol>
    """
  end

  defp serial(%{serial: serial}) when is_binary(serial) and serial != "",
    do: gettext("serial %{s}", s: serial)

  defp serial(_entry), do: gettext("no serial")

  defp time(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Words.time()
end

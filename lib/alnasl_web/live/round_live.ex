defmodule AlnaslWeb.RoundLive do
  @moduledoc """
  The main screen during play: every board of the round at a glance.

  A tile per board: who plays, the position the box is sure of, the clocks,
  the last move, and the state as a shape and a word. A board that needs the
  arbiter stands out by its frame as well as its colour, and is counted at
  the top. A tile is a link to the board's own page, where the repair tools
  are.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Games, Position, Settings, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Boards.subscribe()
    {:ok, assign(socket, refresh_due?: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    round =
      case Integer.parse(params["round"] || "") do
        {n, ""} when n > 0 -> n
        _none -> Settings.get("round") || 1
      end

    {:noreply,
     socket |> assign(round: round, page_title: gettext("Round %{n}", n: round)) |> load()}
  end

  defp load(socket) do
    round = socket.assigns.round

    snapshots =
      for s <- Boards.snapshots(),
          s.round == round,
          s.board_no != nil,
          into: %{},
          do: {s.board_no, s}

    games = Map.new(Games.list(round), &{&1.board_no, &1})
    pairings = Map.new(Tournament.boards(round), &{&1.board, &1})

    numbers =
      Enum.uniq(Map.keys(pairings) ++ Map.keys(snapshots) ++ Map.keys(games)) |> Enum.sort()

    tiles =
      for no <- numbers do
        snap = snapshots[no]
        game = games[no]
        pairing = pairings[no] || %{}

        {fen, last} =
          cond do
            snap && snap[:fen] -> {snap.fen, snap[:last_move]}
            game -> Games.position(game)
            true -> {nil, nil}
          end

        plies = (snap && snap.plies) || (game && Games.plies(game)) || []

        %{
          no: no,
          white: (snap && snap[:white]) || (game && game.white) || pairing[:white],
          black: (snap && snap[:black]) || (game && game.black) || pairing[:black],
          state: tile_state(snap, game),
          position: fen && fen |> Position.from_fen() |> then(&(&1 && Position.to_text(&1))),
          last: last,
          clock: snap && snap[:clock],
          count: length(plies),
          last_san: plies |> List.last() |> then(&(&1 && &1.san)),
          result: (game && game.result) || (snap && snap[:result]),
          suggestion: snap && snap[:suggestion],
          paused: (snap && snap[:paused]) || (game && game.paused) || false,
          warning: snap && snap[:warning],
          board_name: snap && snap.name,
          published: pairing[:result]
        }
      end

    counts = Enum.frequencies_by(tiles, & &1.state)

    assign(socket,
      tiles: tiles,
      counts: counts,
      alarms: Map.get(counts, :out_of_sync, 0) + Map.get(counts, :no_signal, 0),
      rounds: Enum.uniq(Tournament.rounds() ++ Games.rounds() ++ [round]) |> Enum.sort(),
      tournament: Tournament.info().name,
      configured?: Settings.connection_configured?(),
      refresh_due?: false
    )
  end

  defp tile_state(nil, nil), do: :unlinked
  defp tile_state(nil, %{status: "finished"}), do: :finished
  defp tile_state(nil, _game), do: :unlinked
  defp tile_state(snap, _game), do: snap.status

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    case Tournament.refresh() do
      {:ok, _snapshot} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Pairings fetched from the results server."))
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AlnaslWeb.Words.fetch_error(reason))}
    end
  end

  def handle_event("next_round", _params, socket) do
    next = socket.assigns.round + 1
    Boards.move_to_round(next)
    Tournament.refresh()

    {:noreply,
     socket
     |> put_flash(:info, gettext("The boards now follow round %{n}.", n: next))
     |> push_patch(to: ~p"/round/#{next}")}
  end

  def handle_event("make_current", _params, socket) do
    Boards.move_to_round(socket.assigns.round)

    {:noreply,
     socket
     |> put_flash(:info, gettext("The boards now follow round %{n}.", n: socket.assigns.round))
     |> load()}
  end

  # Boards change several times a second during a move; the grid is redrawn
  # at most three times a second.
  @impl true
  def handle_info({:board, _id}, %{assigns: %{refresh_due?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:board, _id}, socket) do
    Process.send_after(self(), :refresh, 300)
    {:noreply, assign(socket, refresh_due?: true)}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  # --- page --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:round}
      link={@link}
      box={@box}
      locale={@locale}
      alarms={@alarms}
      title={gettext("Round %{n}", n: @round)}
      subtitle={@tournament}
    >
      <:actions>
        <div class="seg" role="group" aria-label={gettext("Rounds")}>
          <.link
            :for={n <- @rounds}
            id={"round-#{n}"}
            patch={~p"/round/#{n}"}
            aria-current={to_string(n == @round)}
          >
            {n}
          </.link>
        </div>
        <.button id="refresh-pairings" small phx-click="refresh">{gettext("Fetch pairings")}</.button>
        <.button
          id="next-round"
          small
          phx-click="next_round"
          data-confirm={
            gettext(
              "Move every linked board to round %{n}? The games of this round stay as they are.",
              n: @round + 1
            )
          }
        >
          {gettext("Start round %{n}", n: @round + 1)}
        </.button>
      </:actions>

      <div
        :if={@tiles != []}
        id="round-summary"
        class="summary"
        aria-label={gettext("Boards by state")}
      >
        <span
          :for={
            state <- [
              :out_of_sync,
              :no_signal,
              :recovered,
              :live,
              :settling,
              :waiting_start,
              :finished,
              :unlinked
            ]
          }
          :if={@counts[state]}
          class="row"
          style="gap:0.3rem"
        >
          <b>{@counts[state]}</b><.state state={state} />
        </span>
      </div>

      <div :if={@tiles == []} id="round-empty" class="panel">
        <div class="empty">
          <b>{gettext("No boards in round %{n} yet", n: @round)}</b>
          <%= if @configured? do %>
            <p>
              {gettext(
                "Fetch the pairings from the results server, or link a board to a board number."
              )}
            </p>
            <.button id="empty-boards" navigate={~p"/boards"} variant="primary">{gettext(
              "Go to Boards"
            )}</.button>
          <% else %>
            <p>{gettext("Tell the box which results server and tournament it works for first.")}</p>
            <.button id="empty-setup" navigate={~p"/setup"} variant="primary">{gettext("Go to Setup")}</.button>
          <% end %>
        </div>
      </div>

      <div
        :if={@tiles != []}
        id="tiles"
        class={["tiles", length(@tiles) <= 4 && "few", length(@tiles) > 12 && "many"]}
      >
        <.link
          :for={tile <- @tiles}
          id={"tile-#{tile.no}"}
          navigate={~p"/round/#{@round}/board/#{tile.no}"}
          class={["tile", tone(tile.state)]}
          aria-label={gettext("Board %{n}: %{state}", n: tile.no, state: state_word(tile.state))}
        >
          <div class="tile-head">
            <span class="tile-no">{tile.no}</span>
            <span :if={tile.paused} class="flag plain">{gettext("Not sending")}</span>
            <span :if={tile.warning} class="flag">{gettext("Move missing?")}</span>
            <.state state={tile.state} />
          </div>
          <div class="side">
            <span class="dot black"></span>
            <span class="name">{tile.black || gettext("Black")}</span>
            <.clock :if={tile.clock} ms={tile.clock.black_ms} running={tile.clock.running == :black} />
          </div>
          <div class="tile-board">
            <.board
              position={tile.position}
              last={tile.last}
              label={gettext("Position on board %{n}", n: tile.no)}
            />
          </div>
          <div class="side">
            <span class="dot white"></span>
            <span class="name">{tile.white || gettext("White")}</span>
            <.clock :if={tile.clock} ms={tile.clock.white_ms} running={tile.clock.running == :white} />
          </div>
          <div class="tile-foot">
            <%= cond do %>
              <% tile.result -> %>
                <span class="last">{tile.result}</span>
              <% tile.last_san -> %>
                <span>{div(tile.count + 1, 2)}{if rem(tile.count, 2) == 1, do: ".", else: "..."}</span>
                <span class="last"><.figurine san={tile.last_san} /></span>
              <% true -> %>
                <span>{gettext("No moves")}</span>
            <% end %>
            <span :if={tile.suggestion && !tile.result} class="flag">{gettext("Result? %{r}",
              r: tile.suggestion
            )}</span>
            <span :if={tile.board_name} class="right">{tile.board_name}</span>
          </div>
        </.link>
      </div>
    </Layouts.app>
    """
  end
end

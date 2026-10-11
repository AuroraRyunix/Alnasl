defmodule AlnaslWeb.GameLive do
  @moduledoc """
  One board of the round, large: the position, the moves, the clocks - and,
  when the board and the game have parted ways, what the board reads beside
  what the box is sure of, and the tools to bring them together again.

  Every tool here is a statement by the arbiter and is logged as one.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Chess, Games, Position, Tournament}
  alias AlnaslWeb.Words

  @impl true
  def mount(%{"round" => round, "board" => board}, _session, socket) do
    with {round, ""} <- Integer.parse(round), {board, ""} <- Integer.parse(board) do
      if connected?(socket), do: Boards.subscribe()

      {:ok,
       socket
       |> assign(round: round, no: board, refresh_due?: false, notice: nil, compare: nil)
       |> assign(page_title: gettext("Board %{n}", n: board))
       |> assign(forms())
       |> load()}
    else
      _bad -> {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp forms do
    %{
      moves_form: to_form(%{"moves" => ""}, as: :typed),
      edit_form: to_form(%{"ply" => "", "san" => ""}, as: :edit),
      fen_form: to_form(%{"fen" => ""}, as: :position)
    }
  end

  defp load(socket) do
    %{round: round, no: no} = socket.assigns
    board = Enum.find(Boards.list(), &(&1.round == round and &1.board_no == no))
    game = Games.get(round, no)
    pairing = Tournament.board(round, no) || %{}

    snap =
      cond do
        board -> Boards.snapshot(board)
        game -> offline(game)
        true -> nil
      end

    view =
      if snap do
        certain = snap[:certain] || fen_text(snap[:fen])
        raw = snap[:raw]
        diff = if raw && certain && raw != certain, do: diff(raw, certain), else: []

        %{
          snap: snap,
          certain: certain,
          raw: raw,
          diff: diff,
          apart?:
            diff != [] and snap.status in [:out_of_sync, :settling, :waiting_start, :no_signal],
          white: snap[:white] || pairing[:white],
          black: snap[:black] || pairing[:black],
          rows: rows(snap.plies, snap[:start_fen])
        }
      end

    assign(socket, board: board, game: game, view: view, refresh_due?: false)
  end

  defp offline(game) do
    {fen, last} = Games.position(game)

    %{
      status: if(game.status == "finished", do: :finished, else: :unlinked),
      detail: nil,
      plies: Enum.map(Games.plies(game), &Map.take(&1, [:san, :flags])),
      fen: fen,
      last_move: last,
      start_fen: game.start_fen || Chess.start_fen(),
      candidates: [],
      clock: nil,
      white: game.white,
      black: game.black,
      result: game.result,
      suggestion: game.suggestion,
      paused: game.paused,
      game_status: game.status,
      problems: [],
      running?: false,
      linked?: false,
      warning: nil,
      player: nil
    }
  end

  defp fen_text(nil), do: nil

  defp fen_text(fen) do
    case Position.from_fen(fen) do
      nil -> nil
      board -> Position.to_text(board)
    end
  end

  defp diff(a, b) do
    for {{x, y}, i} <- Enum.with_index(Enum.zip(String.to_charlist(a), String.to_charlist(b))),
        x != y,
        do: i
  end

  # The move list as rows of a move number, White's ply and Black's ply.
  defp rows(plies, start_fen) do
    {number, black_first?} =
      case start_fen && Chess.parse_fen(start_fen) do
        {:ok, pos} -> {pos.fullmove, pos.turn == :b}
        _standard -> {1, false}
      end

    indexed = Enum.with_index(plies, 1)
    indexed = if black_first?, do: [nil | indexed], else: indexed

    indexed
    |> Enum.chunk_every(2, 2, [nil])
    |> Enum.with_index(number)
    |> Enum.map(fn {[white, black], n} -> {n, white, black} end)
  end

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("resync", _params, socket) do
    with_board(socket, fn board ->
      case Boards.resync(board.id, 6) do
        {:ok, :accepted} ->
          {:info, gettext("The moves were found and added.")}

        {:ok, {:candidates, n}} ->
          {:info, gettext("%{n} sequences fit the board. Pick the right one.", n: n)}

        {:ok, :none} ->
          {:error,
           gettext(
             "No sequence of up to 6 moves leads to what the board reads. Type the moves, or set the position."
           )}

        {:ok, :budget} ->
          {:error,
           gettext(
             "The search took too long and was stopped. Type the moves, or set the position."
           )}

        other ->
          other
      end
    end)
  end

  def handle_event("choose", %{"index" => index}, socket) do
    with_board(socket, fn board ->
      Boards.choose(board.id, String.to_integer(index))
      {:info, gettext("Those moves were added.")}
    end)
  end

  def handle_event("undo", _params, socket) do
    with_board(socket, fn board ->
      Boards.undo(board.id)

      {:info,
       gettext("The last move was taken back. The board is read again when it next changes.")}
    end)
  end

  def handle_event("type_moves", %{"typed" => %{"moves" => text}}, socket) do
    sans = text |> String.replace(~r/\d+\.+/, " ") |> String.split(~r/[\s,]+/, trim: true)

    with_board(socket, fn board ->
      cond do
        sans == [] ->
          {:error, gettext("Type one or more moves, like: Nf3 Nc6 Bb5")}

        true ->
          case Boards.append(board.id, sans) do
            :ok ->
              {:info, gettext("%{n} move(s) added.", n: length(sans))}

            {:error, {index, _message}} ->
              {:error,
               gettext("\"%{move}\" is not a legal move there. Nothing was added.",
                 move: Enum.at(sans, index - 1)
               )}

            other ->
              other
          end
      end
    end)
  end

  def handle_event("edit_move", %{"edit" => %{"ply" => ply, "san" => san}}, socket) do
    with_board(socket, fn board ->
      case Integer.parse(ply) do
        {number, ""} ->
          case Boards.edit(board.id, number, String.trim(san)) do
            {:ok, 0} ->
              {:info, gettext("Move %{n} changed. The moves after it still fit.", n: number)}

            {:ok, dropped} ->
              {:info,
               gettext(
                 "Move %{n} changed. %{dropped} later move(s) no longer fit and were removed.",
                 n: number,
                 dropped: dropped
               )}

            {:error, _message} ->
              {:error,
               gettext("\"%{move}\" is not a legal move at that point. Nothing was changed.",
                 move: san
               )}
          end

        _bad ->
          {:error, gettext("Give the number of the move in the list (1 is White's first move).")}
      end
    end)
  end

  def handle_event("set_fen", %{"position" => %{"fen" => fen}}, socket) do
    with_board(socket, fn board ->
      case Boards.set_fen(board.id, String.trim(fen)) do
        :ok -> {:info, gettext("The game now starts from that position.")}
        {:error, _message} -> {:error, gettext("That is not a position (FEN) the box can use.")}
      end
    end)
  end

  def handle_event("result", %{"result" => result}, socket) do
    %{round: round, no: no} = socket.assigns

    case Boards.set_game_result(round, no, result) do
      :ok ->
        {:noreply, socket |> put_flash(:info, gettext("Result set: %{r}", r: result)) |> load()}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("The result could not be set."))}
    end
  end

  def handle_event("reopen", _params, socket) do
    with_board(socket, fn board ->
      Boards.reopen(board.id)
      {:info, gettext("The game is open again.")}
    end)
  end

  def handle_event("pause", %{"paused" => paused}, socket) do
    with_board(socket, fn board ->
      Boards.pause(board.id, paused == "true")

      if paused == "true",
        do: {:info, gettext("Nothing is sent for this board until you resume.")},
        else: {:info, gettext("Sending resumed. The game was sent in full.")}
    end)
  end

  def handle_event("flip", _params, socket) do
    with_board(socket, fn board ->
      Boards.flip(board, not board.flipped)
      {:info, gettext("The board is now read the other way up.")}
    end)
  end

  def handle_event("player", %{"do" => action}, socket) do
    with_board(socket, fn board ->
      if action == "pause", do: Boards.pause_player(board), else: Boards.resume_player(board)

      {:info,
       if(action == "pause",
         do: gettext("The simulated board stands still."),
         else: gettext("The simulated board plays on.")
       )}
    end)
  end

  def handle_event("use_board_fen", _params, socket) do
    fen =
      case socket.assigns.view do
        %{raw: raw} when is_binary(raw) ->
          {:ok, board} = Position.from_text(raw)
          Position.placement(board) <> " w - - 0 1"

        _none ->
          ""
      end

    {:noreply, assign(socket, fen_form: to_form(%{"fen" => fen}, as: :position))}
  end

  defp with_board(socket, fun) do
    case socket.assigns.board do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No board is linked to this game. Link one on the Boards page.")
         )}

      board ->
        case fun.(board) do
          {kind, message} when kind in [:info, :error] and is_binary(message) ->
            {:noreply, socket |> put_flash(kind, message) |> assign(forms()) |> load()}

          {:error, :not_running} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("The board is not connected. Connect it on the Boards page.")
             )}

          _other ->
            {:noreply, load(socket)}
        end
    end
  end

  @impl true
  def handle_info({:board, _id}, %{assigns: %{refresh_due?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:board, _id}, socket) do
    Process.send_after(self(), :refresh, 250)
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
      title={gettext("Board %{n}", n: @no)}
      subtitle={gettext("Round %{n}", n: @round)}
    >
      <:actions>
        <.button id="back-to-round" small icon="back" navigate={~p"/round/#{@round}"}>{gettext(
          "All boards"
        )}</.button>
        <.button
          :if={@game}
          id="download-pgn"
          small
          href={~p"/files/round/#{@round}/board/#{@no}"}
          download
        >
          PGN
        </.button>
      </:actions>

      <div :if={@view == nil} id="game-empty" class="panel">
        <div class="empty">
          <b>{gettext("Nothing is known about board %{n} of round %{r}", n: @no, r: @round)}</b>
          <p>{gettext("Link a physical board to it, or attach a game from a PGN.")}</p>
          <.button id="game-empty-boards" navigate={~p"/boards"} variant="primary">{gettext(
            "Go to Boards"
          )}</.button>
        </div>
      </div>

      <div :if={@view} class="game">
        <div class="stack">
          <.panel id="position">
            <div class="row spread" style="margin-bottom:0.6rem">
              <.state id="game-state" state={@view.snap.status} />
              <span :if={@view.snap[:paused]} id="game-paused" class="flag plain">{gettext(
                "Not sending"
              )}</span>
              <span :if={@view.snap[:warning]} id="game-warning" class="flag">{gettext(
                "Move missing?"
              )}</span>
              <span :if={@board} class="note">{@board.name} · {Words.driver(@board.driver)}</span>
            </div>

            <div class="side">
              <span class="dot black"></span>
              <span class="name">{@view.black || gettext("Black")}</span>
              <.clock
                :if={@view.snap[:clock]}
                ms={@view.snap.clock.black_ms}
                running={@view.snap.clock.running == :black}
              />
            </div>

            <div :if={@view.apart?} id="twin" class="twin">
              <figure>
                <figcaption>{gettext("What the board reads")}</figcaption>
                <.board
                  id="board-raw"
                  position={@view.raw}
                  diff={@view.diff}
                  label={gettext("What the board reads now")}
                />
              </figure>
              <figure>
                <figcaption>{gettext("What is certain")}</figcaption>
                <.board
                  id="board-certain"
                  position={@view.certain}
                  last={@view.snap[:last_move]}
                  diff={@view.diff}
                  label={gettext("The last certain position")}
                />
              </figure>
            </div>
            <div :if={!@view.apart?} class="solo">
              <.board
                id="board-certain"
                position={@view.certain}
                last={@view.snap[:last_move]}
                coords
                label={gettext("The position")}
              />
            </div>

            <div class="side">
              <span class="dot white"></span>
              <span class="name">{@view.white || gettext("White")}</span>
              <.clock
                :if={@view.snap[:clock]}
                ms={@view.snap.clock.white_ms}
                running={@view.snap.clock.running == :white}
              />
            </div>
            <p :if={@view.apart?} class="note" style="margin-top:0.5rem">
              {gettext("The outlined squares are where the two differ.")}
            </p>
          </.panel>

          <.help_box state={@view.snap.status} detail={@view.snap[:detail]} />

          <div
            :if={@view.snap[:problems] not in [nil, []] and @view.snap.plies == []}
            id="start-check"
            class="alarm warn"
            role="status"
          >
            <.icon name="warning" />
            <div>
              <b>{gettext("The starting position is not right")}</b>
              <ul style="margin:0.3rem 0 0;padding-left:1.1rem;color:var(--ink)">
                <li :for={problem <- Enum.take(@view.snap.problems, 8)}>{Words.problem(problem)}</li>
                <li :if={length(@view.snap.problems) > 8}>
                  {gettext("...and %{n} more", n: length(@view.snap.problems) - 8)}
                </li>
              </ul>
            </div>
          </div>

          <div
            :if={@view.snap[:suggestion] && @view.snap[:game_status] != "finished"}
            id="suggestion"
            class="alarm ok"
            role="status"
          >
            <.icon name="finished" />
            <div>
              <b>{gettext("The board suggests a result: %{r}", r: @view.snap.suggestion)}</b>
              <p>{gettext("Nothing is final until you say so.")}</p>
              <.button
                id="confirm-suggestion"
                small
                variant="primary"
                phx-click="result"
                phx-value-result={@view.snap.suggestion}
                style="margin-top:0.4rem"
              >
                {gettext("Confirm %{r}", r: @view.snap.suggestion)}
              </.button>
            </div>
          </div>
        </div>

        <div class="stack">
          <.panel id="moves" title={gettext("Moves")}>
            <:actions>
              <span class="note">{gettext("%{n} played", n: length(@view.snap.plies))}</span>
              <b :if={@view.snap[:result]} id="game-result">{@view.snap.result}</b>
            </:actions>
            <p :if={@view.snap.plies == []} class="note">{gettext("No moves yet.")}</p>
            <div :if={@view.snap.plies != []} id="move-list" class="moves" phx-hook="StickToEnd">
              <%= for {number, white, black} <- @view.rows do %>
                <span class="num">{number}.</span>
                <.ply ply={white} last={length(@view.snap.plies)} />
                <.ply ply={black} last={length(@view.snap.plies)} />
              <% end %>
            </div>
          </.panel>

          <.panel
            :if={@view.snap[:candidates] not in [nil, []]}
            id="candidates"
            title={gettext("Which moves were played?")}
          >
            <p class="note">
              {gettext(
                "Each of these leads to what the board reads. Compare with a scoresheet and pick one."
              )}
            </p>
            <div class="cands">
              <button
                :for={{sans, index} <- Enum.with_index(Enum.take(@view.snap.candidates, 64))}
                id={"candidate-#{index}"}
                type="button"
                class="btn"
                phx-click="choose"
                phx-value-index={index}
              >
                <span :for={san <- sans} style="margin-right:0.5rem"><.figurine san={san} /></span>
              </button>
            </div>
          </.panel>

          <.panel id="tools" title={gettext("Repair")}>
            <div class="tools">
              <div class="tool">
                <b>{gettext("The board is right")}</b>
                <p>
                  {gettext(
                    "Search deeper for the moves between the last certain position and what the board reads now."
                  )}
                </p>
                <.button id="tool-resync" phx-click="resync">{gettext("Resync from here")}</.button>
              </div>

              <div class="tool">
                <b>{gettext("Type the moves")}</b>
                <.form for={@moves_form} id="type-moves-form" phx-submit="type_moves" class="stack">
                  <.input
                    field={@moves_form[:moves]}
                    id="typed-moves"
                    label={gettext("Moves to add, in order")}
                    placeholder="Nf3 Nc6 Bb5"
                    autocomplete="off"
                    spellcheck="false"
                  />
                  <.button id="tool-type" type="submit">{gettext("Add these moves")}</.button>
                </.form>
              </div>

              <div class="tool">
                <b>{gettext("Undo or change a move")}</b>
                <.button
                  id="tool-undo"
                  phx-click="undo"
                  data-confirm={gettext("Take back the last move?")}
                >{gettext("Undo last move")}</.button>
                <.form for={@edit_form} id="edit-move-form" phx-submit="edit_move" class="stack">
                  <div class="row">
                    <.input
                      field={@edit_form[:ply]}
                      id="edit-ply"
                      type="number"
                      min="1"
                      label={gettext("Move no. in list")}
                      class="mini"
                    />
                    <.input
                      field={@edit_form[:san]}
                      id="edit-san"
                      label={gettext("Should be")}
                      placeholder="Nbd2"
                      autocomplete="off"
                      spellcheck="false"
                    />
                  </div>
                  <.button id="tool-edit" type="submit">{gettext("Change that move")}</.button>
                </.form>
              </div>

              <div class="tool">
                <b>{gettext("Result")}</b>
                <p>
                  {gettext(
                    "Sent to the results site as provisional; the published result comes from the pairing program."
                  )}
                </p>
                <div class="row">
                  <.button
                    :for={result <- ["1-0", "1/2-1/2", "0-1"]}
                    id={"result-#{String.replace(result, "/", "")}"}
                    phx-click="result"
                    phx-value-result={result}
                  >
                    {result}
                  </.button>
                </div>
                <.button
                  :if={@view.snap[:game_status] == "finished"}
                  id="tool-reopen"
                  phx-click="reopen"
                >{gettext("Reopen the game")}</.button>
              </div>

              <div class="tool">
                <b>{gettext("Start from a position")}</b>
                <p>
                  {gettext("For a resumed game, or as a last resort. The moves so far are replaced.")}
                </p>
                <.form for={@fen_form} id="set-fen-form" phx-submit="set_fen" class="stack">
                  <.input
                    field={@fen_form[:fen]}
                    id="fen-input"
                    label="FEN"
                    autocomplete="off"
                    spellcheck="false"
                  />
                  <div class="row">
                    <.button id="tool-fen-from-board" type="button" small phx-click="use_board_fen">{gettext(
                      "Take it from the board"
                    )}</.button>
                    <.button
                      id="tool-fen"
                      type="submit"
                      data-confirm={gettext("Replace the game by this position?")}
                    >{gettext("Set position")}</.button>
                  </div>
                </.form>
              </div>

              <div class="tool">
                <b>{gettext("This board")}</b>
                <.button
                  :if={!@view.snap[:paused]}
                  id="tool-pause"
                  phx-click="pause"
                  phx-value-paused="true"
                >{gettext("Pause sending")}</.button>
                <.button
                  :if={@view.snap[:paused]}
                  id="tool-resume"
                  variant="primary"
                  phx-click="pause"
                  phx-value-paused="false"
                >{gettext("Resume sending")}</.button>
                <.button id="tool-flip" icon="flip" phx-click="flip">{gettext("Turn the board round")}</.button>
                <%= if @view.snap[:player] do %>
                  <.button
                    :if={!@view.snap.player.paused?}
                    id="tool-sim-pause"
                    phx-click="player"
                    phx-value-do="pause"
                  >{gettext("Stop the simulated game")}</.button>
                  <.button
                    :if={@view.snap.player.paused?}
                    id="tool-sim-resume"
                    phx-click="player"
                    phx-value-do="resume"
                  >{gettext("Let the simulated game go on")}</.button>
                <% end %>
              </div>
            </div>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :ply, :any, required: true
  attr :last, :integer, required: true

  defp ply(%{ply: nil} = assigns) do
    ~H"""
    <span class="ply"></span>
    """
  end

  defp ply(assigns) do
    {ply, index} = assigns.ply
    assigns = assign(assigns, move: ply, index: index, flags: ply.flags -- [:long_gap])

    ~H"""
    <span id={"ply-#{@index}"} class={["ply", @index == @last && "last", @flags != [] && "flagged"]}>
      <.figurine san={@move.san} />
      <span :for={flag <- @flags} class="flag">{Words.flag(flag)}</span>
    </span>
    """
  end

  attr :state, :atom, required: true
  attr :detail, :any, default: nil

  defp help_box(assigns) do
    {headline, text} = Words.state_help(assigns.state, assigns.detail)
    assigns = assign(assigns, headline: headline, text: text)

    ~H"""
    <div
      :if={@headline && @state in [:out_of_sync, :no_signal, :recovered]}
      id="state-help"
      class={["alarm", @state == :recovered && "warn"]}
      role={if @state == :recovered, do: "status", else: "alert"}
    >
      <.icon name={if @state == :recovered, do: "warning", else: "error"} />
      <div>
        <b>{@headline}</b>
        <p>{@text}</p>
      </div>
    </div>
    <p
      :if={@headline && @state not in [:out_of_sync, :no_signal, :recovered]}
      id="state-help"
      class="note"
    >
      <b>{@headline}.</b> {@text}
    </p>
    """
  end
end

defmodule AlnaslWeb.GameLive do
  @moduledoc """
  One board of the round, large: the position, the moves, the clocks - and,
  when the board and the game have parted ways, what the board reads beside
  what the box is sure of, and the tools to bring them together again.

  Every tool here is a statement by the arbiter and is logged as one.

  ## Looking back

  The board follows the game. Left and Right (and the buttons under the
  board, and a click on a move) step through it; `@at` is then the number
  of plies shown, and moves that arrive meanwhile are added to the list
  without moving the board. End, the "Live" button, or stepping forward
  onto the last move goes back to following (`@at == nil`).

  ## Guessed moves

  Moves the box took from several that fit are marked, and a tap on one -
  or "Check them" in the notice above the tools - asks which line it was,
  a move at a time (`AlnaslWeb.Choice`). `@choice` is that conversation:
  the ply it started from, the alternatives, the answers so far.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Chess, Games, Position, Tournament}
  alias AlnaslWeb.{Choice, Words}

  @impl true
  def mount(%{"round" => round, "board" => board}, _session, socket) do
    with {round, ""} <- Integer.parse(round), {board, ""} <- Integer.parse(board) do
      if connected?(socket), do: Boards.subscribe()

      {:ok,
       socket
       |> assign(round: round, no: board, refresh_due?: false, notice: nil, compare: nil)
       |> assign(at: nil, choice: nil)
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
          rows: rows(snap.plies, snap[:start_fen]),
          line: line(snap.plies, snap[:start_fen])
        }
      end

    # A game that got shorter than the ply being looked at: back to live.
    at = socket.assigns.at
    at = if at && view && at < length(view.snap.plies), do: at

    # The game shown is the one being played; a new one begun on the board
    # is another game, and whatever was being asked about the old is void.
    fresh? = socket.assigns[:game] != nil and game != nil and socket.assigns.game.id != game.id

    socket
    |> assign(board: board, game: game, view: view, refresh_due?: false)
    |> assign(at: if(fresh?, do: nil, else: at), history: Games.history(round, no))
    |> then(&if(fresh?, do: assign(&1, choice: nil), else: &1))
  end

  # The position after each ply, the start included, as what the board
  # component draws: `[{position_text, last_move_squares}]`. Empty when the
  # moves do not replay (they always should).
  defp line(plies, start_fen) do
    start = start_fen || Chess.start_fen()

    case Chess.replay(start, Enum.map(plies, & &1.san)) do
      {:ok, replayed} ->
        {line, _fen} =
          Enum.map_reduce(replayed, start, fn ply, before ->
            {{fen_text(ply.fen), Chess.last_squares(before, ply.san)}, ply.fen}
          end)

        [{fen_text(start), nil} | line]

      _error ->
        []
    end
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
      unseen: [],
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
  def handle_event("nav", %{"to" => to}, socket) do
    count = if socket.assigns.view, do: length(socket.assigns.view.snap.plies), else: 0
    at = socket.assigns.at || count

    at =
      case to do
        "start" -> 0
        "back" -> max(at - 1, 0)
        "forward" -> at + 1
        _live -> count
      end

    {:noreply, assign(socket, at: if(at < count, do: at))}
  end

  def handle_event("goto", %{"ply" => ply}, socket) do
    count = if socket.assigns.view, do: length(socket.assigns.view.snap.plies), else: 0

    case Integer.parse(ply) do
      {at, ""} when at >= 0 and at <= count ->
        socket = assign(socket, at: if(at < count, do: at))
        # A guessed move: the question that goes with it.
        {:noreply, if(guessed?(socket, at), do: review(socket, at), else: socket)}

      _bad ->
        {:noreply, assign(socket, at: nil)}
    end
  end

  def handle_event("review", %{"ply" => ply}, socket),
    do: {:noreply, review(socket, String.to_integer(ply))}

  def handle_event("pick", %{"san" => san}, %{assigns: %{choice: %{} = choice}} = socket),
    do: {:noreply, assign(socket, choice: %{choice | picked: choice.picked ++ [san]})}

  def handle_event("choice_back", _params, %{assigns: %{choice: %{} = choice}} = socket),
    do: {:noreply, assign(socket, choice: %{choice | picked: Enum.drop(choice.picked, -1)})}

  def handle_event("choice_close", _params, socket), do: {:noreply, assign(socket, choice: nil)}

  # "Keep it": the line as it stands is the arbiter's now, and no longer a guess.
  def handle_event("choice_keep", _params, %{assigns: %{choice: %{} = choice}} = socket),
    do: decide(socket, choice, choice.alt.current)

  def handle_event("choice_apply", _params, %{assigns: %{choice: %{} = choice}} = socket) do
    case Choice.ask(choice.alt, choice.picked) do
      %{line: line} when is_list(line) -> decide(socket, choice, line)
      _not_yet -> {:noreply, socket}
    end
  end

  def handle_event(event, _params, socket)
      when event in ~w(pick choice_back choice_keep choice_apply),
      do: {:noreply, socket}

  def handle_event("resync", _params, socket) do
    with_board(socket, fn board ->
      case Boards.resync(board.id, 6) do
        {:ok, {:accepted, sans}} ->
          {:info, gettext("Found and added: %{moves}", moves: Enum.join(sans, " "))}

        {:ok, {:guessed, sans, others}} ->
          {:info,
           gettext(
             "Added: %{moves}. %{n} other line(s) lead to the same board, so these are marked as a guess - check them.",
             moves: Enum.join(sans, " "),
             n: others
           )}

        {:ok, {:rejected, sans}} ->
          {:error,
           gettext(
             "The board still shows the moves you took back (%{moves}), and nothing else leads to what it reads. Put the pieces right, type the moves, or set the position.",
             moves: Enum.join(sans, " ")
           )}

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
      :ok when result == "*" ->
        {:noreply,
         socket |> put_flash(:info, gettext("The game is closed without a result.")) |> load()}

      :ok ->
        {:noreply, socket |> put_flash(:info, gettext("Result set: %{r}", r: result)) |> load()}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("The result could not be set."))}
    end
  end

  def handle_event("new_game", _params, socket) do
    with_board(socket, fn board ->
      case Boards.new_game(board.id) do
        :ok ->
          {:info,
           gettext(
             "A new game on this board. Set up the pieces; the first move starts it. The game before it is kept below."
           )}

        other ->
          other
      end
    end)
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
          # The side whose clock runs is the side to move; without a
          # running clock, White - the arbiter can change the letter.
          turn = if match?(%{running: :black}, socket.assigns.view.snap[:clock]), do: :b, else: :w
          Position.fen(board, turn)

        _none ->
          ""
      end

    {:noreply, assign(socket, fen_form: to_form(%{"fen" => fen}, as: :position))}
  end

  defp guessed?(socket, number) do
    case socket.assigns.view do
      %{snap: %{plies: plies}} when number >= 1 ->
        match?(%{flags: flags} when is_list(flags), Enum.at(plies, number - 1)) and
          :guessed in Enum.at(plies, number - 1).flags

      _none ->
        false
    end
  end

  # Opens the question about the guessed moves around ply `number`.
  defp review(%{assigns: %{board: %{id: id}}} = socket, number) do
    case Boards.alternatives(id, number) do
      %{options: [_, _ | _]} = alt ->
        assign(socket, choice: %{ply: number, alt: alt, picked: []})

      # Nothing else fits after all (or the board is not running): the
      # line as it stands is the only one.
      _one_or_none ->
        assign(socket, choice: nil)
    end
  end

  defp review(socket, _number), do: socket

  defp decide(socket, choice, line) do
    with_board(assign(socket, choice: nil), fn board ->
      case Boards.choose(board.id, choice.ply, line) do
        {:ok, 0} ->
          {:info, gettext("Settled: %{moves}", moves: Enum.join(line, " "))}

        {:ok, dropped} ->
          {:info,
           gettext(
             "Settled: %{moves}. %{dropped} later move(s) no longer fit and were removed.",
             moves: Enum.join(line, " "),
             dropped: dropped
           )}

        _error ->
          {:error, gettext("Those moves no longer fit the game. Nothing was changed.")}
      end
    end)
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
              <span
                :for={{piece, index} <- Enum.with_index(@view.snap[:unseen] || [])}
                id={"game-unseen-#{index}"}
                class="flag"
              >{Words.unseen(piece)}</span>
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

            <div :if={@at} id="looking-back" class="solo">
              <.board
                id="board-at"
                position={@view.line |> Enum.at(@at) |> elem(0)}
                last={@view.line |> Enum.at(@at) |> elem(1)}
                coords
                label={gettext("The position after move %{n} in the list", n: @at)}
              />
            </div>
            <div :if={@view.apart? and !@at} id="twin" class="twin">
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
            <div :if={!@view.apart? and !@at} class="solo">
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
            <p :if={@view.apart? and !@at} class="note" style="margin-top:0.5rem">
              {gettext("The outlined squares are where the two differ.")}
            </p>
            <div :if={@view.line != [] and @view.snap.plies != []} id="move-nav" class="move-nav">
              <.button
                id="nav-start"
                small
                phx-click="nav"
                phx-value-to="start"
                disabled={@at == 0}
                aria-label={gettext("To the start of the game (Home)")}
              >|&lt;</.button>
              <.button
                id="nav-back"
                small
                phx-click="nav"
                phx-value-to="back"
                disabled={@at == 0}
                aria-label={gettext("One move back (Left arrow)")}
              >&lt;</.button>
              <span id="nav-at" class="note" aria-live="polite">
                {gettext("%{at} of %{n}",
                  at: @at || length(@view.snap.plies),
                  n: length(@view.snap.plies)
                )}
              </span>
              <.button
                id="nav-forward"
                small
                phx-click="nav"
                phx-value-to="forward"
                disabled={@at == nil}
                aria-label={gettext("One move forward (Right arrow)")}
              >&gt;</.button>
              <.button
                id="nav-live"
                small
                variant={if @at, do: "primary"}
                phx-click="nav"
                phx-value-to="live"
                disabled={@at == nil}
                aria-label={gettext("Back to the game as it is played (End)")}
              >{gettext("Live")}</.button>
            </div>
          </.panel>

          <.help_box state={@view.snap.status} detail={help_detail(@view.snap)} />

          <div
            :if={@view.snap[:unseen] not in [nil, []]}
            id="unseen-help"
            class="alarm warn"
            role="status"
          >
            <.icon name="warning" />
            <div>
              <b :for={piece <- @view.snap.unseen}>{Words.unseen(piece)}</b>
              <p>
                {gettext(
                  "The piece left its square and the game went on, so it is taken to be standing there still. This goes away when it is seen there again, moves, or is taken. If it was in fact captured, correct the moves below."
                )}
              </p>
            </div>
          </div>

          <div
            :if={@view.snap.plies == [] and Words.clock_problem(@view.snap[:clock_check])}
            id="clock-check"
            class="alarm warn"
            role="status"
          >
            <.icon name="warning" />
            <div>
              <b>{gettext("The clock is not in its starting position")}</b>
              <p>{Words.clock_problem(@view.snap[:clock_check])}.</p>
            </div>
          </div>

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
            <div
              :if={@view.snap.plies != []}
              id="move-list"
              class="moves"
              phx-hook=".MoveList"
              data-follow={to_string(@at == nil)}
            >
              <%= for {number, white, black} <- @view.rows do %>
                <span class="num">{number}.</span>
                <.ply ply={white} last={length(@view.snap.plies)} at={@at} />
                <.ply ply={black} last={length(@view.snap.plies)} at={@at} />
              <% end %>
            </div>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".MoveList">
              // The move list: kept at its end while the game is followed, at
              // the move being looked at otherwise - and the keys that step
              // through it. Keys typed into a field are that field's.
              const KEYS = {ArrowLeft: "back", ArrowRight: "forward", Home: "start", End: "live"}

              export default {
                mounted() {
                  this.onKey = (event) => {
                    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return
                    const el = event.target
                    if (el && (el.isContentEditable || /^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName || ""))) return
                    const to = KEYS[event.key]
                    if (!to) return
                    event.preventDefault()
                    this.pushEvent("nav", {to})
                  }
                  window.addEventListener("keydown", this.onKey)
                  this.place()
                },
                updated() { this.place() },
                destroyed() { window.removeEventListener("keydown", this.onKey) },
                place() {
                  const at = this.el.querySelector(".ply.at")
                  if (this.el.dataset.follow === "true" || !at) this.el.scrollTop = this.el.scrollHeight
                  else at.scrollIntoView({block: "nearest"})
                }
              }
            </script>
          </.panel>

          <div
            :if={marked(@view.snap.plies, :guessed) > 0 and @choice == nil}
            id="guess-notice"
            class="alarm mark-guess"
            role="status"
          >
            <.icon name="warning" />
            <div>
              <b>{Words.marks(:guessed, marked(@view.snap.plies, :guessed))}</b>
              <p>
                {gettext(
                  "More than one line of moves led to what the board showed. The box took one and went on. Compare with a scoresheet when there is a moment."
                )}
              </p>
              <.button
                id="review-guess"
                small
                phx-click="review"
                phx-value-ply={first_marked(@view.snap.plies, :guessed)}
                style="margin-top:0.4rem"
              >{gettext("Check them")}</.button>
            </div>
          </div>
          <div
            :if={marked(@view.snap.plies, :recovered) > 0}
            id="reconstructed-notice"
            class="note mark-rec"
          >
            <span class="flag rec">{Words.flag(:recovered)}</span>
            {Words.marks(:recovered, marked(@view.snap.plies, :recovered))}: {gettext(
              "not seen one by one, and only one line of moves fits."
            )}
          </div>

          <.choice :if={@choice} choice={@choice} line={@view.line} />

          <.panel id="finish" title={gettext("This game")}>
            <:actions>
              <span :if={length(@history) > 1} id="game-no" class="note">
                {gettext("game %{n} on this board", n: @view.snap[:game_no] || length(@history))}
              </span>
            </:actions>
            <p :if={@view.snap[:game_status] == "finished"} id="finish-done">
              <b>{finished_word(@view.snap[:result])}</b>
            </p>
            <b>
              {if @view.snap[:game_status] == "finished",
                do: gettext("Change the result"),
                else: gettext("Finish game")}
            </b>
            <div class="row finish-row">
              <.button
                :for={result <- ["1-0", "1/2-1/2", "0-1"]}
                id={"result-#{String.replace(result, "/", "")}"}
                phx-click="result"
                phx-value-result={result}
              >
                {result}
              </.button>
              <.button
                :if={@view.snap[:game_status] != "finished"}
                id="result-none"
                phx-click="result"
                phx-value-result="*"
                data-confirm={gettext("Close this game without a result?")}
              >
                {gettext("No result")}
              </.button>
            </div>
            <p class="note">
              {gettext(
                "Sent to the results site as provisional; the published result comes from the pairing program."
              )}
            </p>
            <div class="row" style="margin-top:0.5rem">
              <.button
                :if={@board}
                id="new-game"
                variant={if @view.snap[:game_status] == "finished", do: "primary"}
                phx-click="new_game"
                data-confirm={
                  if @view.snap[:game_status] != "finished",
                    do: gettext("Close this game without a result and start a new one on this board?")
                }
              >{gettext("New game on this board")}</.button>
              <.button
                :if={@view.snap[:game_status] == "finished"}
                id="tool-reopen"
                phx-click="reopen"
              >{gettext("Reopen the game")}</.button>
            </div>
            <div :if={length(@history) > 1} id="games-here" class="games-here">
              <b>{gettext("Games on this board this round")}</b>
              <ol>
                <li :for={game <- @history} id={"game-here-#{game.game_no}"}>
                  <span>{gettext("Game %{n}", n: game.game_no)}</span>
                  <span>{game.result || gettext("in play")}</span>
                  <span class="note">
                    {gettext("%{n} played", n: length(Games.sans(game)))}
                  </span>
                  <.link
                    id={"game-here-pgn-#{game.game_no}"}
                    href={~p"/files/round/#{@round}/board/#{@no}?game=#{game.game_no}"}
                    download
                  >PGN</.link>
                </li>
              </ol>
              <p class="note">
                {gettext(
                  "Only the first game of a board goes to the results site and to Lichess: they know a game by its round and board. The others are kept here."
                )}
              </p>
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
                    hint={
                      gettext(
                        "Taken from the board: a side may castle wherever its king and rook stand on their home squares, and the side to move is the one whose clock runs (White without a clock). Change the text if the game says otherwise."
                      )
                    }
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
  attr :at, :any, default: nil

  defp ply(%{ply: nil} = assigns) do
    ~H"""
    <span class="ply"></span>
    """
  end

  defp ply(assigns) do
    {ply, index} = assigns.ply
    # `:unseen` is said once, above the board, not beside every move made
    # while it lasted.
    assigns =
      assign(assigns,
        move: ply,
        index: index,
        flags: ply.flags -- [:long_gap, :unseen],
        mark: Enum.find([:guessed, :recovered], &(&1 in ply.flags))
      )

    ~H"""
    <button
      id={"ply-#{@index}"}
      type="button"
      class={[
        "ply",
        @index == @last && "last",
        @index == @at && "at",
        @flags != [] && "flagged",
        @mark == :guessed && "guess",
        @mark == :recovered && "rec"
      ]}
      phx-click="goto"
      phx-value-ply={@index}
      aria-current={if @index == (@at || @last), do: "true"}
    >
      <.figurine san={@move.san} />
      <span
        :for={flag <- @flags}
        class={["flag", flag == :guessed && "guess", flag == :recovered && "rec"]}
      >{Words.flag(flag)}</span>
    </button>
    """
  end

  defp finished_word("*"), do: gettext("Closed without a result")
  defp finished_word(nil), do: gettext("Finished")
  defp finished_word(result), do: gettext("Finished: %{r}", r: result)

  defp marked(plies, mark), do: Enum.count(plies, &(mark in &1.flags))

  defp first_marked(plies, mark),
    do: (Enum.find_index(plies, &(mark in &1.flags)) || 0) + 1

  # The question about guessed moves: the position before them, the
  # position after, and one move at a time.
  attr :choice, :map, required: true
  attr :line, :list, required: true

  defp choice(assigns) do
    %{alt: alt, picked: picked} = assigns.choice
    ask = Choice.ask(alt, picked)
    before = alt.fen |> Position.from_fen() |> Position.to_text()

    after_them =
      case Enum.at(assigns.line, alt.to) do
        {position, _squares} -> position
        nil -> nil
      end

    assigns =
      assign(assigns,
        alt: alt,
        ask: ask,
        picked: picked,
        before: before,
        after_them: after_them,
        total: length(alt.options)
      )

    ~H"""
    <.panel id="choice" title={gettext("Which moves were played?")}>
      <p id="choice-what" class="note">
        {gettext(
          "Moves %{from} to %{to} in the list were not seen one by one, and %{n} lines of moves lead from the first board to the second. One question at a time; moves that every line has are not asked about.",
          from: @alt.from,
          to: @alt.to,
          n: @total
        )}
      </p>
      <div class="choice-ends">
        <figure>
          <figcaption>{gettext("Before them")}</figcaption>
          <.board
            id="choice-before"
            position={@before}
            label={gettext("The position before those moves")}
          />
        </figure>
        <figure>
          <figcaption>{gettext("After them")}</figcaption>
          <.board
            id="choice-after"
            position={@after_them}
            label={gettext("The position after those moves")}
          />
        </figure>
      </div>

      <p :if={@ask.settled != []} id="choice-settled" class="choice-line">
        <span class="note">{gettext("So far")}:</span>
        <span :for={san <- @ask.settled} class="choice-san"><.figurine san={san} /></span>
      </p>

      <div :if={@ask.line == nil} id="choice-question">
        <b id="choice-ask">
          {if @ask.white?,
            do:
              gettext("Move %{n} in the list, White: which was it?",
                n: @ask.number
              ),
            else:
              gettext("Move %{n} in the list, Black: which was it?",
                n: @ask.number
              )}
        </b>
        <div class="choice-options">
          <button
            :for={{option, index} <- Enum.with_index(@ask.options)}
            id={"choice-option-#{index}"}
            type="button"
            class={["choice-option", option.standing? && "standing"]}
            phx-click="pick"
            phx-value-san={option.san}
          >
            <.board
              position={option.position}
              last={option.squares}
              label={gettext("The board after %{move}", move: option.san)}
            />
            <span class="choice-san"><.figurine san={option.san} /></span>
            <span :if={option.standing?} class="flag plain">{gettext("as it stands")}</span>
            <span class="note">
              {ngettext("%{count} line left", "%{count} lines left", option.left)}
            </span>
          </button>
        </div>
      </div>

      <div :if={@ask.line} id="choice-answer">
        <b>{gettext("That leaves one line:")}</b>
        <p class="choice-line">
          <span
            :for={{san, changed?} <- Enum.zip(@ask.line, @ask.changed)}
            class={["choice-san", changed? && "changed"]}
          ><.figurine san={san} /></span>
        </p>
        <p :if={Enum.any?(@ask.changed)} class="note">
          {gettext("The outlined moves differ from the game as it stands.")}
        </p>
      </div>

      <div class="row" style="margin-top:0.6rem">
        <.button :if={@ask.line} id="choice-apply" variant="primary" phx-click="choice_apply">
          {gettext("Use this line")}
        </.button>
        <.button
          id="choice-keep"
          variant={if @ask.line, do: nil, else: "primary"}
          phx-click="choice_keep"
        >
          {gettext("Keep it as it stands")}
        </.button>
        <.button :if={@picked != []} id="choice-back" phx-click="choice_back">
          {gettext("One question back")}
        </.button>
        <.button id="choice-close" variant="ghost" phx-click="choice_close">
          {gettext("Not now")}
        </.button>
      </div>
    </.panel>
    """
  end

  # What the sentence under the state is about: for a clock alarm the side
  # that runs; for a board waiting with its pieces right, the clock if that
  # is what it is still waiting for.
  defp help_detail(%{status: :clock_alarm} = snap), do: snap[:clock_alarm]

  defp help_detail(%{status: :waiting_start, detail: detail, clock_check: {:wrong, _} = check})
       when detail != :not_start,
       do: {:clock, check}

  defp help_detail(snap), do: snap[:detail]

  attr :state, :atom, required: true
  attr :detail, :any, default: nil

  defp help_box(assigns) do
    {headline, text} = Words.state_help(assigns.state, assigns.detail)
    assigns = assign(assigns, headline: headline, text: text)

    ~H"""
    <div
      :if={@headline && @state in [:out_of_sync, :no_signal, :recovered, :clock_alarm]}
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
      :if={@headline && @state not in [:out_of_sync, :no_signal, :recovered, :clock_alarm]}
      id="state-help"
      class="note"
    >
      <b>{@headline}.</b> {@text}
    </p>
    """
  end
end

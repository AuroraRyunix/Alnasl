defmodule AlnaslWeb.HelpLive do
  @moduledoc "The short guide on the box itself: before the round, during, after, and when something is wrong."

  use AlnaslWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: gettext("Help"))}

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:help}
      link={@link}
      box={@box}
      locale={@locale}
      title={gettext("Help")}
    >
      <.panel id="help">
        <div class="prose">
          <h2 id="help-what">{gettext("What this box does")}</h2>
          <p>
            {gettext(
              "Alnasl reads the electronic boards in the hall, works out the moves from where the pieces stand, and sends moves and clock times to the results site. It keeps everything itself first, so a hall without internet loses nothing: what could not be sent goes out, in order, when the connection is back."
            )}
          </p>
          <p>
            {gettext(
              "It never decides a result. A mate on the board or kings in the centre is a suggestion; you confirm it."
            )}
          </p>

          <h2 id="help-before">{gettext("Before the round")}</h2>
          <ol>
            <li>
              {gettext(
                "Setup: the results site's address, the tournament and the relay key. Press \"Test connection\" - it says in words what is wrong if something is."
              )}
            </li>
            <li>
              {gettext(
                "Boards: every board should show a state other than \"No signal\", and its picture should match the pieces on it."
              )}
            </li>
            <li>
              {gettext(
                "Boards: the column \"Start position\" must say \"Right\" for every board. If not, it names the pieces and squares - a king and queen swapped is the usual one."
              )}
            </li>
            <li>
              {gettext(
                "A board with a clock is only \"Right\" when its clock is too: to the right of the board, the lever up on White's side so that White's time runs first. If not, the same column says the clock is not in its starting position."
              )}
            </li>
            <li>
              {gettext(
                "Boards: link each board to its board number of the round. \"Link in order\" does a whole row at once."
              )}
            </li>
            <li>
              {gettext(
                "Round: every tile should read \"Waiting for start\". A board plugged in turned round is noticed by itself."
              )}
            </li>
          </ol>

          <h2 id="help-during">{gettext("During the round")}</h2>
          <p>{gettext("Keep the Round page open. Each tile shows a shape and a word:")}</p>
          <dl>
            <dt><.state state={:live} /></dt>
            <dd>{gettext("The game is being followed.")}</dd>
            <dt><.state state={:settling} /></dt>
            <dd>{gettext("A hand is over the board, or a move is half made. Nothing to do.")}</dd>
            <dt><.state state={:recovered} /></dt>
            <dd>
              {gettext(
                "Moves were not seen one by one and were worked out from the position. Worth a glance; nothing is wrong."
              )}
            </dd>
            <dt><.state state={:out_of_sync} /></dt>
            <dd>
              {gettext(
                "The board does not match the game and nothing is being sent for it. Open the board: it shows what it reads beside what is certain, and the tools to repair it."
              )}
            </dd>
            <dt><.state state={:no_signal} /></dt>
            <dd>{gettext("The board does not answer. Check cable and power. The game is kept.")}</dd>
            <dt><.state state={:clock_alarm} /></dt>
            <dd>
              {gettext(
                "Black's clock is running and White has not moved: the clock is turned round, or it was started with the lever the wrong way. Stop it, put it right, start it again; the alarm goes away by itself. The moves are still followed."
              )}
            </dd>
          </dl>
          <p>
            {gettext(
              "A banner across the top means the results site cannot be reached. Play goes on and nothing is lost; the Outbox page says how much is waiting and why."
            )}
          </p>

          <h2 id="help-repair">{gettext("Repairing a board")}</h2>
          <ul>
            <li>
              <b>{gettext("The board is right - resync from here")}</b>: {gettext(
                "searches deeper for the moves that were missed. If several sequences fit, it lists them and you pick."
              )}
            </li>
            <li>
              <b>{gettext("Type the moves")}</b>: {gettext("from the scoresheet, like Nf3 Nc6 Bb5.")}
            </li>
            <li>
              <b>{gettext("Undo last move / Change a move")}</b>: {gettext(
                "the spectators' copy is corrected too."
              )}
            </li>
            <li>
              <b>{gettext("Start from a position")}</b>: {gettext(
                "for a resumed game, or when nothing else helps."
              )}
            </li>
            <li>
              <b>{gettext("Pause sending")}</b>: {gettext(
                "the board is followed but nothing goes out until you resume."
              )}
            </li>
          </ul>
          <p>{gettext("Everything you do here is written in the Log with the time.")}</p>

          <h2 id="help-after">{gettext("After the round")}</h2>
          <ol>
            <li>{gettext("Set the result on every board (or confirm the suggestion).")}</li>
            <li>
              {gettext(
                "A game that was not captured: PGN page, read the scoresheet's moves, \"Attach\" to its board."
              )}
            </li>
            <li>{gettext("PGN page: \"Whole round as PGN\" for the bulletin.")}</li>
            <li>{gettext("Round page: \"Start round N\" moves all boards on to the next round.")}</li>
          </ol>

          <h2 id="help-trouble">{gettext("When something is wrong")}</h2>
          <dl>
            <dt>{gettext("A board shows \"Out of sync\" right after the start")}</dt>
            <dd>
              {gettext(
                "The starting position was wrong or the first moves were made before the board was linked. Use \"Resync from here\"."
              )}
            </dd>
            <dt>{gettext("\"Clock not in starting position\" before the round")}</dt>
            <dd>
              {gettext(
                "The clock always stands to the right of the board, White's display toward White; the cable does not reach anywhere else, and the box cannot be told otherwise. Before the first move the lever must be up on White's side, so that White's time runs first. Turn the clock or tip the lever; the message goes away by itself."
              )}
            </dd>
            <dt>{gettext("Moves appear late")}</dt>
            <dd>
              {gettext(
                "A move is believed once the pieces have stood still for a moment; a clock press makes it immediate. Castling and promotion wait a little longer."
              )}
            </dd>
            <dt>{gettext("\"Move missing?\" on a tile")}</dt>
            <dd>
              {gettext(
                "The clock was pressed more often than moves were seen. Compare the board with the move list."
              )}
            </dd>
            <dt>{gettext("The results site shows nothing")}</dt>
            <dd>
              {gettext(
                "Outbox: is anything waiting, and why? Was the round published from the pairing program? A game is only shown for a published board."
              )}
            </dd>
            <dt>{gettext("The box was switched off by accident")}</dt>
            <dd>
              {gettext(
                "Switch it on. Games, queue and settings are on disk; boards reconnect and carry on."
              )}
            </dd>
          </dl>
        </div>
      </.panel>
    </Layouts.app>
    """
  end
end

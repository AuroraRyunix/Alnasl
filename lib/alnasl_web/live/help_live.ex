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
                "Boards: give each board its table number - by touching them in order, or all at once in the order they are connected. See \"Which board is which\" below."
              )}
            </li>
            <li>
              {gettext(
                "Boards: \"Ready for round N?\" must say Ready. If not, it lists what is wrong, board by board - a clock that is not set for White included."
              )}
            </li>
            <li>
              {gettext(
                "Round: every tile should read \"Waiting for start\". A board plugged in turned round is noticed by itself."
              )}
            </li>
          </ol>

          <h2 id="help-which">{gettext("Which board is which")}</h2>
          <p>
            {gettext(
              "Twelve boards look alike, and so do twelve cables. The box keeps three things apart:"
            )}
          </p>
          <dl>
            <dt>{gettext("Which board it is")}</dt>
            <dd>
              {gettext(
                "A DGT board tells the box its serial number (it is also on a label under the board). That is what the box knows it by - not the USB port. Unplug it, plug it in elsewhere, restart the box: it is still the same board and keeps its number. If it comes back on another port, add it on that port: the box recognises the serial and puts it back in its old place. A board the box has never seen is marked \"New board\" and asks for a number."
              )}
            </dd>
            <dt>{gettext("Its table number")}</dt>
            <dd>
              {gettext(
                "The sticker on the board: \"this is table 7\". You set it once for the hall and it stays. \"Labels\" on the Boards page prints a sheet of stickers with the table number and the serial."
              )}
            </dd>
            <dt>{gettext("Its board of the round")}</dt>
            <dd>
              {gettext(
                "Normally the same number as the table. For one round you can say otherwise in the column \"Board of round N\" (\"table 7 plays board 3 today\"), swap two boards, or put everything back. The next round starts from the table numbers again. On the Round page the board number is the big one; \"table 7 · serial 06310\" is the small print."
              )}
            </dd>
          </dl>
          <p>{gettext("Three ways to give the numbers:")}</p>
          <ul>
            <li>
              <b>{gettext("Number by touching")}</b>: {gettext(
                "press Start, then lift a piece on table 1's board, then on table 2's, and so on. Each board gets the next number the moment it feels the piece go. Undo takes the last one back, Skip leaves a number out, Stop ends it."
              )}
            </li>
            <li>
              <b>{gettext("Number all in connection order")}</b>: {gettext(
                "one click, when the boards were connected in the order of the tables."
              )}
            </li>
            <li>
              <b>{gettext("By hand")}</b>: {gettext("type the number in the column \"Table\".")}
            </li>
          </ul>
          <p>
            <b>{gettext("Which board is this?")}</b>
            {gettext(
              "Press it on the Boards page and lift a piece on the board you mean: its row lights up for a few seconds. The other way round, \"Show me\" on a row tells you which serial to look for, and says whether the board you then touch is the right one. (The box cannot make a board beep or blink; a touch is the signal.)"
            )}
          </p>

          <h2 id="help-phone">{gettext("Number the boards with your phone")}</h2>
          <ol>
            <li>
              {gettext(
                "Start the box so that other devices can reach it (ALNASL_LISTEN=lan, see the README) and set a PIN in Setup - before the hall fills up: without one, anybody on the hall's network who finds the address can renumber your boards."
              )}
            </li>
            <li>
              {gettext(
                "On the box, open Boards (or Setup): \"Open this site on your phone\" shows the address and a QR code. Point the phone's camera at it and give the PIN."
              )}
            </li>
            <li>
              {gettext(
                "On the phone: Boards, \"Number by touching\", Start. The next table number fills the screen. Walk to that table and lift any piece; the phone flashes the number and the board's serial, buzzes and beeps (the beep can be switched off)."
              )}
            </li>
            <li>
              {gettext(
                "Undo, Skip and Stop are at the bottom of the screen. If the phone loses the network between two tables, nothing is lost: the run is kept on the box, and the page shows where it stands as soon as it is back. The same page on the box's own screen shows the same thing."
              )}
            </li>
          </ol>
          <p>
            {gettext(
              "Do this before the round, with the pieces set up and nobody at the boards. The run ends by itself when every board has a number, or after fifteen minutes without a touch."
            )}
          </p>

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

          <h2 id="help-lichess">{gettext("Broadcasting on Lichess")}</h2>
          <p>
            {gettext(
              "Two ways, and they can run side by side. Either way, first make a broadcast on Lichess (lichess.org/broadcast/new) and a round in it."
            )}
          </p>
          <dl>
            <dt>{gettext("Push: the box sends the games to Lichess")}</dt>
            <dd>
              <ol>
                <li>
                  {gettext(
                    "On Lichess, leave the round's source empty: the games will be pushed. Copy the link to the round."
                  )}
                </li>
                <li>
                  {gettext(
                    "On Lichess, make a personal access token (lichess.org/account/oauth/token) with the permission to create and update studies and broadcasts. It is shown once: copy it."
                  )}
                </li>
                <li>
                  {gettext(
                    "On the box, Setup, \"Lichess broadcast\": paste the link and the token, say which round of the tournament it is, tick \"Send the games\", Save. \"Test\" asks Lichess whether the token and the round are right, and says in words what is not."
                  )}
                </li>
                <li>
                  {gettext(
                    "From then on every move, correction and result goes to Lichess within a couple of seconds, with the clocks. The Outbox page shows Lichess as a destination of its own: connected or not, how many games wait, and why."
                  )}
                </li>
              </ol>
              {gettext(
                "Needs: internet at the box. Works without the results site. A new round on Lichess is a new round id: change it in Setup when the round changes."
              )}
            </dd>
            <dt>{gettext("Pull: Lichess fetches the games from the results site")}</dt>
            <dd>
              {gettext(
                "The results site serves each round as one PGN at https://<results site>/t/<tournament>/live/<round>/pgn. Give that address to Lichess as the round's source and Lichess reads it every few seconds. The box needs no Lichess token for this; it only has to reach the results site. Spectators on Lichess then see what the results site shows, including its delay. The same address works for any other broadcast tool that follows a PGN on the web."
              )}
            </dd>
          </dl>

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
                "A move is believed once the pieces have stood still for a moment, or as soon as the next player picks up a piece; the move's own clock press makes it immediate. Castling and promotion wait a little longer."
              )}
            </dd>
            <dt>{gettext("Blitz and bullet")}</dt>
            <dd>
              {gettext(
                "Setup has \"Bullet / fast play\" for games of a few minutes or less: a move has to stand for a shorter time, and a board put back is not read as a takeback. The box works out up to two moves it did not see; beyond that the board goes \"Out of sync\" and \"Resync from here\" searches deeper. Everything a real board says is recorded whatever is set (Recordings), so a game can be looked at again afterwards."
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

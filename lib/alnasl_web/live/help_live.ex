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
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      title={gettext("Help")}
    >
      <.panel id="help">
        <div class="prose">
          <h2 id="help-what">{gettext("What this box does")}</h2>
          <p>
            {gettext(
              "Alnasl reads the electronic boards in the hall, works out the moves from where the pieces stand, and sends moves and clock times to the results site. Who plays whom it learns from OpenPairings, and what each board saw goes back there. It keeps everything itself first, so a hall without internet loses nothing: what could not be sent goes out, in order, when the connection is back."
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
                "Setup, Tournaments: paste the connect code from OpenPairings (see \"Working with OpenPairings\" below) and say which tables play in which tournament. Press \"Test connection\" - it says in words what is wrong if something is. Without OpenPairings: the results site's address, the tournament and the relay key, typed in on the same page."
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

          <h2 id="help-openpairings">{gettext("Working with OpenPairings")}</h2>
          <ol>
            <li>
              {gettext(
                "In OpenPairings: Settings, Live boards, make a connect code - for one tournament, or for a group of tournaments. It is shown once, as a line of text and as a QR code holding the same text."
              )}
            </li>
            <li>
              {gettext(
                "On the box: Setup, Tournaments, paste the line and press Add. From a phone: scan the QR code with the phone's own camera, copy the link it shows instead of opening it, and paste it in the field. (The box cannot scan it itself: a browser only lends its camera to a page served over https, and the box is not.)"
              )}
            </li>
            <li>
              {gettext(
                "The tournaments the code reaches appear, each with what came with it: players, the rounds that are paired, the rate of play, and - when the tournament is published - its results page and relay key. Nothing is typed on the box for the results site. A tournament added to the group later appears by itself."
              )}
            </li>
            <li>
              {gettext(
                "The boards are put in the tournament for you. With one tournament and nothing played yet in the box's own, every board the box knows plays there at once, its table number being its board; the line under the bar says so and has an Undo. With a group, or a game already under way, the box asks which tables play in which, with ranges filled in: \"Tables from 5 to 8\", table 5 being the tournament's board 1. One board can also be put in a tournament on the Boards page."
              )}
            </li>
          </ol>
          <p id="help-outside">
            {gettext(
              "A board that plays in no linked tournament is never left silent: the line under the bar, the Boards page, the Round page and \"Ready for round N?\" all say \"Board 1 is not playing in ...\", with a button to put it there. If a game is under way on it, the button offers \"these moves are board N of round R\" (the moves stay, under the pairing's names, and are sent in full) or \"start fresh\" (the game is closed without a result and kept where it was). A board connected later joins the only linked tournament by itself, as long as the box's own has not been used."
            )}
          </p>
          <p id="help-statuses">
            {gettext(
              "The bar names what it is about: \"OpenPairings: connected\" is the code you pasted; \"Results site: ...\" is the tournament's results page. \"No relay key yet\" means OpenPairings has not saved a relay key for the tournament: in OpenPairings, Settings, Live boards, The results site. The box starts sending by itself a few seconds after the key is saved. \"Live\" and the number beside it is this browser's connection to the box, not to the internet."
            )}
          </p>
          <p id="help-sending-automatic">
            {gettext(
              "Sending is automatic: to OpenPairings from the moment a tournament is linked, to the results site from the moment it has an address and a key (a game recorded before that goes out in full). Lichess stays off until you fill in a round and a token. \"Send now\" on the Outbox page only nudges a destination that is waiting out a pause, and always says what it did or why it did nothing."
            )}
          </p>
          <p id="help-rounds-start">
            {gettext(
              "From then on a round starts by itself: a few seconds after the arbiter pairs it in OpenPairings, that tournament's boards show the new round with names, ratings and colours. The boards of the other tournaments are not touched. \"Start round N\" on the Round page stays for when there is no connection, and a tournament can be told not to start rounds by itself (Setup)."
            )}
          </p>
          <p id="help-board-saw">
            {gettext(
              "What goes back to OpenPairings, per game: the moves, the clocks, the PGN, and the result the board saw - with how many moves the box reconstructed or guessed. It is shown beside the pairing there, in red when it differs from the result the arbiter entered. A board never enters a result."
            )}
          </p>
          <p id="help-pairing-changed">
            {gettext(
              "When a pairing is changed in OpenPairings after the round began: a board where nothing was played simply takes the new pairing. A game that has moves is kept as it is and its tile says \"Pairing changed\" - open the board and choose. \"These moves are that game\" when the players are the ones in the new pairing (a colour switch, a corrected name): the moves stand under the new names. \"Set it aside, begin again\" when the game on the board is nobody's any more: it is kept on the box with its PGN, and the board begins again for the new pairing. A game that only got another board number moves there by itself."
            )}
          </p>
          <p id="help-desktop">
            {gettext(
              "With a desktop copy of OpenPairings on the same computer, the code begins with http://127.0.0.1 and everything works with no internet at all. Such a code does not work from a box elsewhere in the hall: the desktop copy answers only on its own computer."
            )}
          </p>
          <p id="help-team-events">
            {gettext(
              "A team event reads as matches on the Round page: \"Match 3: Team A - Team B\", the match's boards under it in board order, each tile naming the team of each player and its place in the match. Beside the match, its score as the boards saw it finish - only that: the score that counts is the one the arbiter enters in OpenPairings. Boards keep the number they have through the round, as on the results site, so board 6 is board 2 of match 2 with four boards a match."
            )}
          </p>
          <p id="help-team-tables">
            {gettext(
              "Tables for a team event: \"Keep each match together\" (on by default) counts a tournament's tables match by match, so a match sits side by side and numbering by touching goes match by match. \"Ready for round N?\" names a missing board by its match, and says when only part of a match is on electronic boards. The PGN of a team game carries WhiteTeam and BlackTeam, and Round as round and board (\"3.6\")."
            )}
          </p>
          <p id="help-two-codes">
            {gettext(
              "Two codes that reach one tournament - a group's and the tournament's own, or a desktop copy's code for this computer and for the hall's network - make one tournament on the box, not two: the second code says \"This code reaches ..., which this box already has through ...\". When the old code was withdrawn and a new one made, press \"Use this code\" under the new one: the tournament keeps its boards and games, and the old code goes when it reaches nothing else."
            )}
          </p>
          <p id="help-no-pairing-program">
            {gettext(
              "Without OpenPairings the box still works: type the results page in on Setup, and say who plays on each board's page (\"Players\") or attach a PGN that says it. The box does not read pairings from the results site."
            )}
          </p>

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

          <h2 id="help-loop">{gettext("Several boards on one cable (a loop)")}</h2>
          <p>
            {gettext(
              "DGT boards can be chained on one serial cable, as in DGT LiveChess. For the box that is one port. Boards, Add a board: choose the port and press Add. The box asks the port who is on it - a few seconds - and every board that answers gets a row of its own. There is nothing to type and nothing to choose: one board is read as one board, two or more as a loop."
            )}
          </p>
          <p id="help-loop-later">
            {gettext(
              "A board plugged into the chain later gets its row by itself within some ten seconds, and the log says so. A board taken off the chain keeps its row, which says \"No signal\" and why; it is back when the board is. Close DGT LiveChess first: a port can be read by one program at a time."
            )}
          </p>
          <p id="help-loop-identity">
            {gettext(
              "The older boards say their serial number on a loop and are known by it, like any board. The newer ones (firmware 4) do not: such a board is shown by the number it answers to on the loop, in small print, and keeps its table number under that. Plug it into a port of its own once and the box knows its serial number from then on, on a loop too."
            )}
          </p>
          <p id="help-loop-limits">
            {gettext(
              "What has been checked on real boards: finding the boards, who they are, and what stands on each, with two boards on one cable. Not yet seen on a real loop: a move as it is played, a clock, and more than two boards. The box reads the whole board every few seconds as well, so a move can be late there but not wrong."
            )}
          </p>

          <h2 id="help-phone">{gettext("Number the boards with your phone")}</h2>
          <ol>
            <li>
              {gettext(
                "Setup, \"Access from other machines\": set a PIN, then let other machines in the hall open the site, and start Alnasl again. Do it before the hall fills up - and never without the PIN: anybody on the hall's network who finds the address could renumber your boards."
              )}
            </li>
            <li>
              {gettext(
                "On the box, open Boards (or Setup): \"Open this site on your phone\" shows the address and a QR code. Point the phone's camera at it and give the PIN."
              )}
            </li>
            <li>
              {gettext(
                "On the phone: Boards, \"Number by touching\", Start. The next table number fills the screen. Walk to that table and lift any piece; the phone flashes the number and the board's serial, buzzes (Android only) and beeps once \"Sound off\" has been tapped to \"Sound on\"; a phone wants one tap per visit before it makes any sound, and an iPhone on silent plays none."
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
                "Moves were not seen one by one and were worked out from the position, so that the board keeps up. Each such move is marked in the list: \"reconstructed\" (orange, a diamond) when only one line of moves fits, \"guessed\" (red, a question mark) when several did and the box took one. The tile and the Boards list count them. Tap a guessed move, or \"Check them\" on the board's page, and the box asks which move it was, one question at a time, each option on a small board, the likeliest first; \"Keep it as it stands\" is one tap. When no other line fits, it says so and offers to keep the moves, take them back, or go to where you type the right ones. The results site and Lichess get these moves like any other, without the mark; a correction replaces the game there."
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
          <p id="help-named-alarms">
            {gettext(
              "\"Black moved (Nc6), but it is White's turn\" and \"A move that is not legal: white bishop c1-g5\" are alarms that say what the board shows: somebody moved out of turn, or made a move the rules do not allow. The box adds nothing to the game for it and invents no moves to make it fit. Put the piece back and the alarm is gone. If the board missed a move before it, \"A move is missing before this\" takes you to where moves are typed."
            )}
          </p>
          <p id="help-rewritten">
            {gettext(
              "\"read as d3\" beside a move means the board read that move one square off - a piece set down between two squares - and a later move showed where it really went. The box has put it right and says so above the moves; \"Check it\" has the move as it was read, if you know better. The box never adds more moves than the clock was pressed for: when it would have to, the board goes out of sync instead, and \"the board is right\" is yours to press."
            )}
          </p>
          <p id="help-unseen">
            {gettext(
              "\"White knight not seen on f3\" on a tile or a board's page is a warning, not an alarm: a piece left its square (parked beside the board, or the sensor lost it) and the game went on, so the box takes it to be standing there still and follows the moves. It goes away when the piece is seen there again, moves, or is taken. If the piece was in fact captured, correct the moves on the board's page. Setup has the switch."
            )}
          </p>
          <p id="help-looking-back">
            {gettext(
              "On a board's page the Left and Right arrow keys, the buttons under the board, or a tap on a move step back through the game; Home is the start, End or \"Live\" is the game as it is played. Moves that arrive while you look back are added to the list and do not move the board."
            )}
          </p>
          <p>
            {gettext(
              "A banner across the top means the results site cannot be reached. Play goes on and nothing is lost; the Outbox page says how much is waiting and why."
            )}
          </p>

          <p id="help-results-links">
            {gettext(
              "To see what spectators see: on the Round page \"Open the results site\" opens the live boards of the round in a new tab, \"QR\" shows a code of the tournament's live page to hold up in the hall, and each tile has a \"Live page\" link to its board. A board's page has \"This game on the results site\", Setup > Tournaments and the Outbox link to the tournament's page. A tournament that is not on a results site has no link, and says so."
            )}
          </p>
          <p id="help-results-lag">
            {gettext(
              "The public page may be behind on purpose: the results site can hold live boards back by a delay that its admin sets, so a move made a minute ago may not be there yet. That is not a fault, and nothing is missing."
            )}
          </p>

          <h2 id="help-repair">{gettext("Repairing a board")}</h2>
          <ul>
            <li>
              <b>{gettext("The board is right - resync from here")}</b>: {gettext(
                "searches deeper and longer for the moves that were missed, and says which it added. If several lines fit, one is taken and marked as a guess for you to check. Moves you have just taken back with Undo are not put back by it."
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
            <li>
              {gettext(
                "Set the result on every board (or confirm the suggestion): \"Finish game\" on the board's page, or under its tile on the Round page - the three results, or \"No result\" for a game that was abandoned."
              )}
            </li>
            <li id="help-new-game">
              {gettext(
                "Another game on the same board: \"New game on this board\". The game before it is kept and listed with its PGN. One game of a board goes to the results site, Lichess and OpenPairings. Where a pairing names the board and its game has no result (abandoned, a false start, \"No result\"), the new game is that one: it replaces the old game on all three and the old one stays on the box. Where the game has a result, the new game is an extra one that stays on the box, so a finished game is never overwritten; \"It replaces the game of the pairing\" is there for when you mean it. A game that stays on the box says so on its tile, on its page and in the Outbox, with \"Send this one instead\". On a board no pairing names, setting up the pieces again starts the next game by itself (Setup can make that always, or never)."
              )}
            </li>
            <li>
              {gettext(
                "A game that was not captured: PGN page, read the scoresheet's moves, \"Attach\" to its board."
              )}
            </li>
            <li>{gettext("PGN page: \"Whole round as PGN\" for the bulletin.")}</li>
            <li>
              {gettext(
                "The next round starts by itself when OpenPairings pairs it. Without OpenPairings: Round page, \"Start round N\" moves the tournament's boards on to the next round."
              )}
            </li>
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

          <h2 id="help-install">{gettext("Installing, updating, and where your data is")}</h2>
          <dl>
            <dt>{gettext("Windows")}</dt>
            <dd>
              {gettext(
                "Alnasl-Setup.exe installs for you alone, without an administrator, and puts \"Alnasl\" in the Start menu. The program is not signed, so the first time Windows says \"Windows protected your PC\": choose \"More info\", then \"Run anyway\". The small Alnasl window is the program: closing it stops Alnasl, and while it is stopped the boards are not read. There is also a zip that installs nothing: unzip it and start Alnasl.exe."
              )}
            </dd>
            <dt>{gettext("Linux and the Raspberry Pi")}</dt>
            <dd>
              {gettext(
                "One line installs Alnasl as a service that starts with the box (64-bit; Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm, or newer):"
              )}
              <code>
                curl -fsSL https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh | sudo sh
              </code>
            </dd>
            <dt>{gettext("Mac")}</dt>
            <dd id="help-install-mac">
              {gettext(
                "Download alnasl-macos-aarch64.zip for a Mac with an Apple chip (M1 and later) or alnasl-macos-x86_64.zip for an Intel Mac, open it, and drag Alnasl into Applications. Apple has not signed it yet, so the first time macOS refuses to open it: in System Settings, Privacy & Security, click \"Open Anyway\" beside the message about Alnasl (on macOS 14 or older: right-click the app and choose Open). The small Alnasl window is the program, as on Windows. A DGT board on USB is a port called /dev/cu.usbserial-... or /dev/cu.usbmodem...; the USB adapter of an RS232 board may need its maker's driver before it shows up (FTDI works as it is; Prolific, CH340 and CP210x may not). To update, stop Alnasl and put the new app in place of the old one."
              )}
            </dd>
            <dt>{gettext("Updating")}</dt>
            <dd>
              {gettext(
                "The box asks once every half hour whether a newer version is out, and says so at the top of the page. It downloads nothing until you say yes under Setup, Updates, where it also says how big the download is. It will not restart while a game is being played unless you insist: the moves played during the restart are not read. \"Later\" asks again tomorrow; \"Don't ask again\" stops the looking, and Setup switches it back on. On Linux the same thing by hand:"
              )}
              <code>sudo /opt/alnasl/update.sh</code>
            </dd>
            <dt>{gettext("Where your data is")}</dt>
            <dd>
              {gettext(
                "Not in the program's folder. Windows: %LOCALAPPDATA%\\AlnaslData (type that in Explorer's address bar). Linux, installed: /var/lib/alnasl. Mac: ~/Library/Application Support/AlnaslData (in Finder: Go, Go to Folder). It holds the database, the PGN of every game, the raw recordings, and the keys and codes you pasted. Updating and uninstalling leave it alone; installing again finds it. To move to another computer, copy that folder while Alnasl is stopped."
              )}
            </dd>
            <dt>{gettext("Which copy is which")}</dt>
            <dd id="help-copies">
              {gettext(
                "Setup, \"This copy of Alnasl\", says the version, how this copy was started and where its data folder is. The boards' table numbers are kept there, per board serial number, so they survive the next round, updates and reinstalls. A second copy started another way on the same computer (from source, installed, portable) has a data folder of its own: its own boards, numbers and tournaments."
              )}
            </dd>
            <dt>{gettext("Uninstalling")}</dt>
            <dd>
              {gettext(
                "Windows: Settings, Apps, Alnasl, Uninstall. Linux: sudo /opt/alnasl/uninstall.sh. Mac: stop Alnasl and drag it from Applications to the Bin. All three remove the program and keep the data; delete the data folder yourself if you mean to."
              )}
            </dd>
          </dl>

          <h2 id="help-look">{gettext("Colours")}</h2>
          <p>
            {gettext(
              "The site comes in the same themes as OpenResults: Paper, Night, Board, Slate and High contrast, and Match device, which follows the phone or computer. Choose with the half-moon at the bottom of the left rail, or under Setup (on a phone, the rail is not shown). The choice is kept in that browser only. High contrast is the one for a projector at the back of the hall."
            )}
          </p>

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
            <dt>{gettext("\"Code refused\" under Tournaments in Setup")}</dt>
            <dd>
              {gettext(
                "OpenPairings does not accept the connect code: it was withdrawn there, or it is not the whole line. The box has stopped asking, and the boards go on with the pairings it has. Make a new code in OpenPairings (Settings, Live boards), add it, and remove the old one."
              )}
            </dd>
            <dt>{gettext("\"No answer\" under Tournaments in Setup")}</dt>
            <dd>
              {gettext(
                "OpenPairings cannot be reached. Nothing is lost: the boards go on with the pairings the box has, the games are kept for it, and the box asks again by itself. A round paired meanwhile is started with \"Start round N\" and takes its names when the connection is back."
              )}
            </dd>
            <dt>{gettext("A tournament has no results page")}</dt>
            <dd>
              {gettext(
                "It is not published from OpenPairings, or no relay key is saved there (Settings, Live boards). Setup says which. Until then its moves go to OpenPairings only; the address and the key arrive by themselves once they are there."
              )}
            </dd>
            <dt>{gettext("\"More than one board answers on this port: it is a loop\"")}</dt>
            <dd>
              {gettext(
                "The port was added while one board was on it, or before this version, and several are on it now. Read as one board they all answer at once and nothing of it makes sense, so the box reads nothing. Press \"Read it as a loop\" on that row: each board gets its own row. A board that had a table number keeps it when the box can tell which one it is."
              )}
            </dd>
            <dt>{gettext("A board on a loop says \"No signal\" and the others do not")}</dt>
            <dd>
              {gettext(
                "That board does not answer: its cable in the chain is out, or it has no power. The boards before it in the chain go on. Nothing has to be done on the box when it is back."
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

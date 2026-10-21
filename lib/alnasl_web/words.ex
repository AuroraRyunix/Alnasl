defmodule AlnaslWeb.Words do
  @moduledoc """
  Where machine facts become sentences: why the server could not be reached,
  what is wrong with a starting position, what a line of the log says.

  One place, so that the same fact reads the same on every page and in both
  languages, and so that nothing the arbiter sees is an error code.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.{Log, Position}

  # --- the connection ----------------------------------------------------------

  @doc "Why the pairings could not be fetched."
  def fetch_error(:not_configured),
    do: gettext("Set the results site and the tournament first (Setup).")

  def fetch_error(:unreachable),
    do: gettext("The results site cannot be reached. Is the network up?")

  def fetch_error(:not_found),
    do: gettext("The results site does not know this tournament. Has it been published?")

  def fetch_error(:not_json), do: gettext("That address answers, but not as a results site.")

  def fetch_error({:http, status}),
    do: gettext("The results site answered with an error (%{status}).", status: status)

  def fetch_error(_other), do: gettext("The pairings could not be fetched.")

  @doc "One step of \"Test connection\", in words: `{tone, sentence}`."
  def test_step(:server, :ok), do: {"ok", gettext("The results site answers.")}

  def test_step(:server, {:error, {:unreachable, reason}}),
    do: {"bad", gettext("The results site cannot be reached: %{why}", why: unreachable(reason))}

  def test_step(:server, {:error, {:http, status}}),
    do:
      {"bad",
       gettext(
         "The results site answers with an error of its own (%{status}). Try again in a moment.",
         status: status
       )}

  def test_step(:tournament, {:ok, %{name: name, rounds: rounds, boards: boards}}) do
    {"ok",
     gettext(
       "The tournament is there: %{name}, %{rounds} round(s) published, %{boards} board(s) in the latest.",
       name: name || "?",
       rounds: rounds,
       boards: boards
     )}
  end

  def test_step(:tournament, {:error, :no_slug}),
    do: {"bad", gettext("No tournament is filled in.")}

  def test_step(:tournament, {:error, :not_found}),
    do:
      {"bad",
       gettext(
         "The results site does not know this tournament. Check the name in the link; it must have been published at least once."
       )}

  def test_step(:tournament, {:error, :not_json}),
    do: {"bad", gettext("That address answers, but not as a results site. Check the address.")}

  def test_step(:tournament, {:error, reason}), do: {"bad", fetch_error(reason)}

  def test_step(:key, :ok), do: {"ok", gettext("The relay key is accepted for this tournament.")}

  def test_step(:key, {:error, :no_slug}),
    do: {"bad", gettext("No tournament is filled in.")}

  def test_step(:key, {:error, :no_key}),
    do:
      {"bad",
       gettext(
         "No relay key is filled in. An admin of the results site makes one for the tournament."
       )}

  def test_step(:key, {:error, :key_refused}),
    do: {"bad", gettext("The results site does not accept this relay key. Was it copied whole?")}

  def test_step(:key, {:error, :key_other_tournament}),
    do: {"bad", gettext("This relay key belongs to another tournament.")}

  def test_step(:key, {:error, :key_revoked}),
    do: {"bad", gettext("This relay key has been revoked. Ask for a new one.")}

  def test_step(:key, {:error, :rate_limited}),
    do:
      {"warn",
       gettext(
         "The results site asks to slow down. The key is probably fine; try again in a minute."
       )}

  def test_step(:key, {:error, :paused}),
    do:
      {"warn",
       gettext(
         "The results site has paused all sending for the moment. The key could not be tested."
       )}

  def test_step(:key, {:error, :not_found}),
    do: {"bad", gettext("The results site does not take live boards for this tournament.")}

  def test_step(:key, {:error, {:refused, code}}),
    do: {"bad", gettext("The results site refuses: %{code}.", code: code)}

  def test_step(_step, :skipped), do: {nil, gettext("Not tested: the step before it failed.")}
  def test_step(_step, {:error, _other}), do: {"bad", gettext("This step failed.")}

  def step_name(:server), do: gettext("Results site")
  def step_name(:tournament), do: gettext("Tournament")
  def step_name(:key), do: gettext("Relay key")

  defp unreachable(:econnrefused), do: gettext("nothing is listening at that address.")
  defp unreachable(:nxdomain), do: gettext("that name does not exist. Check the address.")
  defp unreachable(:timeout), do: gettext("no answer in time. Is the network up?")
  defp unreachable(:ehostunreach), do: gettext("there is no route to it. Is the network up?")
  defp unreachable(:enetunreach), do: gettext("there is no network.")
  defp unreachable(:closed), do: gettext("the connection was closed.")

  defp unreachable({:tls_alert, _alert}),
    do: gettext("the secure connection failed. https or http?")

  defp unreachable(_other), do: gettext("no connection.")

  @doc "Why the outbox is not sending, from its last error."
  def link_error(nil), do: nil

  # With several tournaments, whose refusal it is.
  def link_error({:tournament, name, reason}) when is_binary(name),
    do: name <> ": " <> link_error(reason)

  def link_error({:tournament, _unnamed, reason}), do: link_error(reason)

  def link_error({:unreachable, reason}),
    do: gettext("The results site cannot be reached: %{why}", why: unreachable(reason))

  def link_error(:rate_limited),
    do: gettext("The results site asks to slow down. Sending goes on by itself.")

  def link_error({:http, 503, "publishing_paused"}),
    do:
      gettext(
        "The results site has paused all sending. It goes on by itself when that is lifted."
      )

  def link_error({:http, status, _code}),
    do: gettext("The results site answers with an error of its own (%{status}).", status: status)

  def link_error({401, _code}),
    do: gettext("The results site does not accept the relay key. Check it in Setup.")

  def link_error({403, "relay_key_revoked"}),
    do: gettext("The relay key has been revoked. Ask for a new one and put it in Setup.")

  def link_error({403, "relay_key_wrong_tournament"}),
    do: gettext("The relay key belongs to another tournament. Check Setup.")

  def link_error({403, code}),
    do: gettext("The results site refuses what Alnasl sends: %{code}.", code: code || "?")

  def link_error({404, _code}),
    do: gettext("The results site does not know this tournament. Has it been published?")

  def link_error({:crash, _message}),
    do: gettext("Sending failed inside Alnasl. It is tried again.")

  def link_error(_other), do: gettext("Sending failed. It is tried again.")

  @doc "Why the server refused one message."
  def entry_error("invalid_moves"), do: gettext("The results site calls a move in it illegal.")

  def entry_error("moves_conflict"),
    do:
      gettext("The results site held other moves for this game. The game was sent again in full.")

  def entry_error("invalid_request"), do: gettext("The results site could not read it.")

  def entry_error("invalid_fen"),
    do: gettext("The results site does not accept the starting position.")

  def entry_error("fen_mismatch"), do: gettext("The position did not match the moves.")
  def entry_error("ply_mismatch"), do: gettext("The move count did not match the moves.")

  def entry_error("older_than_stored"),
    do: gettext("The results site already had more moves than this.")

  def entry_error("discarded_by_arbiter"), do: gettext("Discarded: it could not be sent.")
  def entry_error(nil), do: nil
  def entry_error(code), do: gettext("Refused: %{code}.", code: code)

  # --- a board -----------------------------------------------------------------

  @doc "What the state of a board means for the arbiter: `{headline, explanation}`."
  def state_help(:out_of_sync, :ambiguous),
    do:
      {gettext("More than one sequence of moves fits the board"),
       gettext(
         "Moves went by unseen and the board cannot say which they were. Pick the right ones below; Alnasl has kept following the game underneath."
       )}

  def state_help(:out_of_sync, {:out_of_turn, _move} = named),
    do:
      {alarm(named),
       gettext(
         "The board shows a legal move by the side that is not to move. Nothing was added to the game. Put the piece back and the board carries on by itself. If a move was made before it that the board did not see, add that move below."
       )}

  def state_help(:out_of_sync, {:illegal, %{why: why}} = named),
    do:
      {alarm(named),
       why(why) <>
         " " <>
         gettext(
           "Nothing was added to the game. Put the piece back and the board carries on by itself. If a move was made before it that the board did not see, add that move below."
         )}

  def state_help(:out_of_sync, {:set_up_again, plies}),
    do:
      {gettext("The board is set up for a new game"),
       ngettext(
         "The pieces stand in the starting position, but this game already has a move. If a new game is starting on this board, start a new game below. If the pieces were knocked over, put the position back.",
         "The pieces stand in the starting position, but this game already has %{count} moves. If a new game is starting on this board, start a new game below. If the pieces were knocked over, put the position back.",
         plies
       )}

  def state_help(:out_of_sync, :piece_missing),
    do:
      {gettext("A piece is missing from the board"),
       gettext(
         "A piece has been off its square for a long time. If it is put back, the board carries on by itself."
       )}

  def state_help(:out_of_sync, :search_gave_up),
    do:
      {gettext("The board cannot be explained"),
       gettext(
         "The search for the moves that lead to this position took too long and was stopped. Use the tools below."
       )}

  def state_help(:out_of_sync, _other),
    do:
      {gettext("The board does not match the game"),
       gettext(
         "No legal moves lead from the last certain position to what the board reads now. Nothing is being sent for this board. If the pieces are put right it carries on by itself; otherwise use the tools below."
       )}

  def state_help(:no_signal, _detail),
    do:
      {gettext("The board does not answer"),
       gettext(
         "Check the cable and the power. The game is kept; when the board is back the moves made meanwhile are looked for."
       )}

  def state_help(:recovered, _detail),
    do:
      {gettext("Moves were reconstructed"),
       gettext(
         "The last moves were not seen one by one; they were worked out from the position. Orange: only one line of moves fits. Red: more than one did, and Alnasl took one - check those against a scoresheet."
       )}

  def state_help(:clock_alarm, side),
    do:
      {clock_alarm(side),
       gettext(
         "The pieces are being followed, but the clock times of the moves are the wrong way round. Stop the clock, set it down with White's display toward White (to the right of the board, lever up on White's side) and start it again. This goes away by itself once the clock is right."
       )}

  def state_help(:waiting_start, {:clock, check}),
    do: {gettext("The clock is not in its starting position"), clock_problem(check) <> "."}

  def state_help(:waiting_start, :not_start),
    do:
      {gettext("Waiting for the starting position"),
       gettext("The board does not show the starting position of this game.")}

  def state_help(:waiting_start, _detail),
    do:
      {gettext("Ready"),
       gettext("The starting position is on the board. The first move starts the game.")}

  def state_help(:settling, {:gesture, result}),
    do:
      {gettext("The kings are in the centre"),
       gettext("The players signal a result: %{result}. Confirm it below.", result: result)}

  def state_help(:settling, _detail),
    do: {gettext("A hand is over the board"), gettext("The position is not a finished move yet.")}

  def state_help(:finished, _detail),
    do: {gettext("The game is over"), gettext("The board is no longer followed.")}

  def state_help(:unlinked, _detail),
    do:
      {gettext("No board is feeding this game"),
       gettext("Link a board to it on the Boards page.")}

  def state_help(_state, _detail), do: {nil, nil}

  @doc """
  What a board plainly shows that is not a move of the game, in one line:
  "Black moved (Nc6), but it is White's turn", "A move that is not legal:
  white bishop c1-g5". `nil` for an alarm that has no such name.
  """
  def alarm({:out_of_turn, %{colour: :b, san: san}}),
    do: gettext("Black moved (%{move}), but it is White's turn", move: san)

  def alarm({:out_of_turn, %{san: san}}),
    do: gettext("White moved (%{move}), but it is Black's turn", move: san)

  def alarm({:illegal, %{piece: piece, from: from, to: to}}),
    do:
      gettext("A move that is not legal: %{piece} %{from}-%{to}",
        piece: piece(piece),
        from: Position.square_name(from),
        to: Position.square_name(to)
      )

  def alarm({:set_up_again, _plies}), do: gettext("The board is set up for a new game")

  def alarm(_other), do: nil

  @doc "Why a move is not legal, as a sentence."
  def why(:blocked), do: gettext("Something stands in its way.")
  def why(:own_piece), do: gettext("A piece of its own side stands there.")
  def why(:check), do: gettext("It leaves its own king in check.")
  def why("blocked"), do: why(:blocked)
  def why("own_piece"), do: why(:own_piece)
  def why("check"), do: why(:check)
  def why(_shape), do: gettext("That piece does not move like that.")

  @doc "A finding of the start-position check, in pieces and squares."
  def problem({:swapped, a, sq_a, b, sq_b}) do
    gettext("%{a} and %{b} are swapped (%{sq_a}, %{sq_b})",
      a: piece(a),
      b: piece(b),
      sq_a: Position.square_name(sq_a),
      sq_b: Position.square_name(sq_b)
    )
  end

  def problem({:wrong, square, expected, nil}),
    do:
      gettext("%{square}: %{piece} is missing",
        square: Position.square_name(square),
        piece: piece(expected)
      )

  def problem({:wrong, square, nil, seen}),
    do:
      gettext("%{square}: %{piece} should not be there",
        square: Position.square_name(square),
        piece: piece(seen)
      )

  def problem({:wrong, square, expected, seen}) do
    gettext("%{square}: %{seen} instead of %{expected}",
      square: Position.square_name(square),
      seen: piece(seen),
      expected: piece(expected)
    )
  end

  @doc """
  The clock's finding of the start-position check (`{:wrong, side}`), in
  words; `nil` when the clock is right or there is none.

  There is no "the other way round is fine" here and no control to swap the
  sides: the clock stands to the right of the board, and that is that.
  """
  def clock_problem({:wrong, :black}),
    do:
      gettext(
        "Clock not in starting position: Black's side would run first - the clock is turned or the lever is the wrong way"
      )

  def clock_problem({:wrong, :white}),
    do:
      gettext(
        "Clock not in starting position: White's side would run first - the clock is turned or the lever is the wrong way"
      )

  def clock_problem(_fine), do: nil

  @doc "The clock alarm - a clock running on the wrong side from the starting position - in words."
  def clock_alarm(:white),
    do: gettext("White's clock is running and Black has not moved")

  def clock_alarm(_black),
    do: gettext("Black's clock is running and White has not moved")

  @doc """
  A square whose sensor the tracker has stopped believing: the warning that
  stays for the rest of the game, since nobody mends a board mid-round.
  """
  def dead(square),
    do: gettext("Square %{square} seems dead", square: Position.square_name(square))

  @doc """
  A piece the board does not show, taken to stand where it stood
  (`{square, piece}`): the warning that stays for as long as that lasts.
  """
  def unseen({square, {:w, kind}, read}),
    do:
      gettext("White %{piece} read on %{read}, taken to stand on %{square}",
        piece: kind(kind),
        read: Position.square_name(read),
        square: Position.square_name(square)
      )

  def unseen({square, {_black, kind}, read}),
    do:
      gettext("Black %{piece} read on %{read}, taken to stand on %{square}",
        piece: kind(kind),
        read: Position.square_name(read),
        square: Position.square_name(square)
      )

  def unseen({square, {:w, kind}}),
    do:
      gettext("White %{piece} not seen on %{square}",
        piece: kind(kind),
        square: Position.square_name(square)
      )

  def unseen({square, {_black, kind}}),
    do:
      gettext("Black %{piece} not seen on %{square}",
        piece: kind(kind),
        square: Position.square_name(square)
      )

  def piece({:w, kind}), do: gettext("white %{piece}", piece: kind(kind))
  def piece({:b, kind}), do: gettext("black %{piece}", piece: kind(kind))

  defp kind(:k), do: gettext("king")
  defp kind(:q), do: gettext("queen")
  defp kind(:r), do: gettext("rook")
  defp kind(:b), do: gettext("bishop")
  defp kind(:n), do: gettext("knight")
  defp kind(:p), do: gettext("pawn")
  defp kind(text) when text in ~w(k q r b n p), do: kind(String.to_existing_atom(text))
  defp kind(_other), do: gettext("piece")

  @doc """
  How many moves of a game carry a mark, in words: "3 moves reconstructed",
  "1 move guessed".
  """
  def marks(:recovered, count),
    do: ngettext("%{count} move reconstructed", "%{count} moves reconstructed", count)

  def marks(:guessed, count),
    do: ngettext("%{count} move guessed", "%{count} moves guessed", count)

  @doc """
  A move that was read as another and rewritten, in a sentence: "3. d3 was
  read; the board now says it was 3. d4". `number` is the ply (1-based).
  """
  def read_as(number, read, now) do
    move = "#{div(number + 1, 2)}#{if rem(number, 2) == 1, do: ".", else: "..."}"

    gettext("%{move} %{read} was read; the board now says it was %{move} %{now}",
      move: move,
      read: read,
      now: now
    )
  end

  @doc "A flag on a move, as the small word shown beside it."
  def flag(:recovered), do: gettext("reconstructed")
  def flag(:guessed), do: gettext("guessed")
  def flag(:rewritten), do: gettext("rewritten")
  def flag(:alone), do: gettext("one line found")
  def flag(:long_gap), do: gettext("after a gap in contact")
  def flag(:assumed), do: gettext("queen assumed")
  def flag(:unseen), do: gettext("a piece not seen")
  def flag(:arbiter), do: gettext("by hand")
  def flag(:imported), do: gettext("from PGN")
  def flag(other), do: to_string(other)

  def driver("simulator"), do: gettext("Simulator")
  def driver("replay"), do: gettext("Replay of a capture")
  def driver("dgt_serial"), do: gettext("Electronic board, serial")
  def driver("dgt_bus"), do: gettext("Electronic board on a loop")
  def driver("remote"), do: gettext("Electronic board, through a bridge")
  def driver(other), do: other

  # --- the log -----------------------------------------------------------------

  @doc "A line of the log as a sentence."
  def log(%Log.Event{kind: kind} = event), do: log(kind, Log.data(event))

  defp log("board.added", d), do: gettext("Board \"%{name}\" added.", name: d["name"])
  defp log("board.removed", d), do: gettext("Board \"%{name}\" removed.", name: d["name"])
  defp log("board.connected", _d), do: gettext("The board answers.")
  defp log("board.disconnected", _d), do: gettext("The board stopped answering.")

  defp log("board.driver_failed", d),
    do: gettext("The board could not be opened: %{reason}", reason: d["reason"])

  defp log("board.linked", d),
    do: gettext("\"%{name}\" linked to this board of the round.", name: d["name"])

  defp log("board.unlinked", d), do: gettext("\"%{name}\" unlinked.", name: d["name"])

  defp log("board.moved", d),
    do: gettext("The game moved from \"%{from}\" to \"%{to}\".", from: d["from"], to: d["to"])

  defp log("board.flipped", %{"flipped" => true, "auto" => true}),
    do: gettext("The board is plugged in turned round; it is read the other way up.")

  defp log("board.flipped", %{"flipped" => false, "auto" => true}),
    do: gettext("The board is the right way round again.")

  defp log("board.flipped", _d), do: gettext("The board was turned round by hand.")

  defp log("board.out_of_sync", _d),
    do: gettext("Out of sync: the board does not match the game.")

  defp log("board.resumed", _d), do: gettext("Back in sync.")

  defp log("move.out_of_turn", %{"colour" => "b"} = d),
    do:
      gettext(
        "Out of turn: Black moved %{move} (%{from}-%{to}) with White to move. Not added to the game.",
        move: d["move"],
        from: d["from"],
        to: d["to"]
      )

  defp log("move.out_of_turn", d),
    do:
      gettext(
        "Out of turn: White moved %{move} (%{from}-%{to}) with Black to move. Not added to the game.",
        move: d["move"],
        from: d["from"],
        to: d["to"]
      )

  defp log("move.illegal", %{"colour" => "w"} = d),
    do:
      gettext("Not a legal move: white %{piece} %{from}-%{to}. %{why} Not added to the game.",
        piece: kind(d["piece"]),
        from: d["from"],
        to: d["to"],
        why: why(d["why"])
      )

  defp log("move.illegal", d),
    do:
      gettext("Not a legal move: black %{piece} %{from}-%{to}. %{why} Not added to the game.",
        piece: kind(d["piece"]),
        from: d["from"],
        to: d["to"],
        why: why(d["why"])
      )

  defp log("move.recovered", d),
    do: gettext("Reconstructed, not seen one by one (one line fits): %{moves}", moves: moves(d))

  defp log("move.rewritten", %{"read" => read, "now" => now, "ply" => ply} = d)
       when is_binary(read) and is_integer(ply) do
    number = "#{div(ply + 1, 2)}#{if rem(ply, 2) == 1, do: ".", else: "..."}"

    if d["sure"],
      do:
        gettext(
          "%{number} %{read} was read; the board now says it was %{number} %{now}. The game from there: %{moves}",
          number: number,
          read: read,
          now: now,
          moves: moves(d)
        ),
      else:
        gettext(
          "%{number} %{read} was read; Alnasl now takes it to have been %{number} %{now} - a guess. The game from there: %{moves}",
          number: number,
          read: read,
          now: now,
          moves: moves(d)
        )
  end

  defp log("move.rewritten", d),
    do: gettext("A move that was read wrong was put right: %{moves}", moves: moves(d))

  defp log("move.guessed", d),
    do:
      gettext("Guessed: more than one line of moves fits, this one was taken: %{moves}",
        moves: moves(d)
      )

  defp log("move.assumed", d),
    do: gettext("Promotion piece not seen, a queen assumed: %{moves}", moves: moves(d))

  defp log("square.dead", d),
    do:
      gettext(
        "Square %{square} has stopped reading what stands on it. It is not read any more: what the game puts there is taken to be there. Check the board after the game.",
        square: d["square"]
      )

  defp log("piece.unseen", %{"read" => read} = d) when is_binary(read),
    do:
      gettext(
        "A %{piece} reads on %{read} and stands on %{square}: set down between the two. The moves are followed with it on %{square}.",
        piece: kind(d["piece"]),
        read: read,
        square: d["square"]
      )

  defp log("piece.unseen", %{"colour" => "w"} = d),
    do:
      gettext(
        "White %{piece} is gone from %{square} and the game goes on: taken to stand there unseen.",
        piece: kind(d["piece"]),
        square: d["square"]
      )

  defp log("piece.unseen", d),
    do:
      gettext(
        "Black %{piece} is gone from %{square} and the game goes on: taken to stand there unseen.",
        piece: kind(d["piece"]),
        square: d["square"]
      )

  defp log("piece.accounted", _d),
    do: gettext("The piece that was not seen is accounted for.")

  defp log("move.corrected", %{"reason" => "takeback"}),
    do: gettext("A move was taken back on the board.")

  defp log("move.corrected", %{"reason" => "promotion"} = d),
    do: gettext("The promotion piece was put on the board: %{moves}", moves: moves(d))

  defp log("move.corrected", d),
    do: gettext("The last move was replaced: %{moves}", moves: moves(d))

  defp log("clock.move_missing", d),
    do:
      gettext("The clock was pressed %{presses} times for %{plies} moves: a move may be missing.",
        presses: d["presses"],
        plies: d["plies"]
      )

  defp log("clock.wrong_side", %{"side" => "white"}),
    do:
      gettext(
        "Clock alarm: White's clock is running from the starting position. The clock is turned round or was started the wrong way."
      )

  defp log("clock.wrong_side", _d),
    do:
      gettext(
        "Clock alarm: Black's clock is running from the starting position. The clock is turned round or was started the wrong way."
      )

  defp log("clock.side_ok", _d), do: gettext("The clock is the right way again.")

  defp log("result.suggested", %{"why" => "gesture"} = d),
    do: gettext("The kings are in the centre: %{result}?", result: d["result"])

  defp log("result.suggested", d),
    do: gettext("The position is decided: %{result}?", result: d["result"])

  defp log("result.set", %{"result" => "*"}),
    do: gettext("The game was closed without a result.")

  defp log("result.set", %{"by" => "board"} = d),
    do: gettext("Result %{result}, from the position.", result: d["result"])

  defp log("result.set", d),
    do: gettext("Result %{result}, set by the arbiter in Alnasl.", result: d["result"])

  defp log("result.reopened", _d), do: gettext("The game was reopened by the arbiter in Alnasl.")

  defp log("game.new", %{"by" => "pieces"} = d),
    do: gettext("The pieces are set up again: game %{n} on this board begins.", n: d["game"])

  defp log("game.new", %{"kind" => "replace"} = d),
    do:
      gettext(
        "Arbiter in Alnasl: a new game on this board, game %{n}. It is the game of the pairing: the one before it stays in Alnasl.",
        n: d["game"]
      )

  defp log("game.new", %{"kind" => "extra"} = d),
    do:
      gettext(
        "Arbiter in Alnasl: an extra game on this board, game %{n}. It stays in Alnasl.",
        n: d["game"]
      )

  defp log("game.new", d),
    do: gettext("Arbiter in Alnasl: a new game on this board, game %{n}.", n: d["game"])

  defp log("game.switched", d),
    do:
      gettext(
        "Game %{n} on this board is the one that leaves Alnasl now, in place of the game before it.",
        n: d["game"]
      )

  defp log("repair.undo", d),
    do: gettext("Arbiter in Alnasl: last move (%{move}) taken back.", move: d["move"] || "-")

  defp log("repair.append", d),
    do: gettext("Arbiter in Alnasl: moves typed in: %{moves}", moves: moves(d))

  defp log("repair.edit", d),
    do:
      gettext("Arbiter in Alnasl: move %{ply} changed to %{move}.",
        ply: d["ply"],
        move: d["move"]
      )

  defp log("repair.set_fen", _d), do: gettext("Arbiter in Alnasl: a position was set by hand.")

  defp log("repair.resync", %{"outcome" => "accepted"} = d),
    do:
      gettext("Arbiter in Alnasl: \"the board is right\" - found and added %{moves}",
        moves: moves(d)
      )

  defp log("repair.resync", %{"outcome" => "guessed"} = d),
    do:
      gettext(
        "Arbiter in Alnasl: \"the board is right\" - several lines fit, %{moves} was taken",
        moves: moves(d)
      )

  defp log("repair.resync", %{"outcome" => "rejected"} = d),
    do:
      gettext(
        "Arbiter in Alnasl: \"the board is right\" - only the moves just taken back fit (%{moves}); not put back.",
        moves: moves(d)
      )

  defp log("repair.resync", _d),
    do: gettext("Arbiter in Alnasl: \"the board is right\" - nothing was found.")

  defp log("repair.choose", d),
    do: gettext("Arbiter in Alnasl: said which moves were played: %{moves}", moves: moves(d))

  defp log("repair.paused", _d), do: gettext("Arbiter in Alnasl: sending paused for this board.")

  defp log("repair.resumed", _d),
    do: gettext("Arbiter in Alnasl: sending resumed for this board.")

  defp log("pgn.attached", d),
    do:
      gettext("Arbiter in Alnasl: a game of %{moves} moves attached from a PGN.",
        moves: d["moves"]
      )

  defp log("outbox.offline", _d),
    do: gettext("No connection to the results site. Moves are kept.")

  defp log("outbox.online", _d), do: gettext("The results site is back. Sending what was kept.")

  defp log("outbox.blocked", _d),
    do: gettext("The results site refuses what Alnasl sends. Check the relay key.")

  defp log("outbox.conflict", _d),
    do: gettext("The results site held other moves for this game; it was sent again in full.")

  defp log("outbox.discarded", d),
    do:
      gettext("%{n} moves that could not be sent were discarded.",
        n: d["count"] || d[:count] || 0
      )

  defp log("outbox.server_ahead", _d),
    do: gettext("The results site holds more moves for this game than Alnasl does.")

  defp log("destination.offline", d),
    do: gettext("No connection to %{name}. The games are kept for it.", name: destination(d))

  defp log("destination.online", d),
    do: gettext("%{name} is back. Sending what was kept.", name: destination(d))

  defp log("destination.blocked", d),
    do: gettext("%{name} refuses what Alnasl sends. See the Results page.", name: destination(d))

  defp log("destination.enabled", d),
    do: gettext("Arbiter in Alnasl: sending to %{name} switched on.", name: destination(d))

  defp log("destination.disabled", d),
    do: gettext("Arbiter in Alnasl: sending to %{name} switched off.", name: destination(d))

  defp log("table.set", d),
    do: gettext("\"%{name}\" is table %{table}.", name: d["name"], table: d["table"])

  defp log("table.cleared", d),
    do: gettext("\"%{name}\" no longer has a table number.", name: d["name"])

  defp log("table.moved", d),
    do:
      gettext("Table %{table} is now \"%{to}\"; \"%{from}\" lost that number.",
        table: d["table"],
        to: d["to"],
        from: d["from"]
      )

  defp log("table.remapped", d),
    do:
      gettext("\"%{name}\" (table %{table}) feeds this board for the round.",
        name: d["name"],
        table: d["table"]
      )

  defp log("table.swapped", d),
    do: gettext("\"%{a}\" and \"%{b}\" changed places for the round.", a: d["a"], b: d["b"])

  defp log("board.recognised", d),
    do:
      gettext(
        "Board %{serial} is back on another port (%{to}): recognised as \"%{name}\", it keeps its number.",
        serial: d["serial"],
        to: d["to"],
        name: d["name"]
      )

  defp log("loop.read", d),
    do:
      ngettext(
        "%{port} is a loop: %{count} board answers on it. Each has its own row now.",
        "%{port} is a loop: %{count} boards answer on it. Each has its own row now.",
        d["boards"] || 0,
        port: d["port"]
      )

  defp log("loop.joined", d),
    do:
      gettext("A board was plugged into the loop on %{port}: added as \"%{name}\".",
        port: d["port"],
        name: d["name"]
      )

  defp log("board.other_serial", d),
    do:
      gettext(
        "The board on this cable says it is serial %{seen}, not %{serial}. Left alone: a game is under way.",
        seen: d["seen"],
        serial: d["serial"]
      )

  defp log("board.replaced", d),
    do:
      gettext(
        "Another board (serial %{seen}) is on the cable of \"%{name}\": it was added as \"%{new}\", and \"%{name}\" waits for its own board.",
        seen: d["seen"],
        name: d["name"],
        new: d["new"]
      )

  defp log("bridge.joined", d),
    do: gettext("The bridge \"%{name}\" joined.", name: d["name"])

  defp log("bridge.removed", d),
    do: gettext("The bridge \"%{name}\" was removed; its boards with it.", name: d["name"])

  defp log("door.unlocked", d), do: gettext("The PIN was given from %{from}.", from: d["from"])

  defp log("bridge.moved", d),
    do:
      gettext("The bridge \"%{name}\" moved to another hall, its boards with it.",
        name: d["name"]
      )

  defp log("hall.created", d), do: gettext("A hall was made: %{name}.", name: d["name"])
  defp log("hall.deleted", d), do: gettext("A hall was deleted: %{name}.", name: d["name"])

  defp log("account.first", _d),
    do: gettext("The box's first account was made. Every page asks who is there from now on.")

  defp log("account.invited", d),
    do:
      gettext("Someone was invited to %{hall} as %{role}.",
        hall: d["hall"],
        role: role(d["role"])
      )

  defp log("account.joined", d),
    do:
      gettext("An invitation to %{hall} was taken up (%{role}).",
        hall: d["hall"],
        role: role(d["role"])
      )

  defp log("account.made", _d),
    do: gettext("An admin's account was made at the first 02cloud sign-in.")

  defp log("account.temporary_password", _d),
    do: gettext("An admin gave an account a temporary password.")

  defp log("account.refused", d),
    do: gettext("A wrong password was tried from %{from}.", from: d["from"])

  defp log("door.refused", d), do: gettext("A wrong PIN was tried from %{from}.", from: d["from"])

  defp log("door.throttled", d),
    do: gettext("%{from} tried the PIN too often and was made to wait.", from: d["from"])

  defp log("setup.saved", _d), do: gettext("Setup was changed.")

  defp log("link.added", %{"reason" => _} = d),
    do:
      gettext(
        "A connect code for %{server} was added. It could not be checked yet; Alnasl keeps asking.",
        server: d["server"]
      )

  defp log("link.added", d),
    do: gettext("A connect code for %{server} was added and accepted.", server: d["server"])

  defp log("link.connect_failed", d),
    do:
      gettext("Connecting an account on %{server} did not finish: it could not be asked.",
        server: d["server"]
      )

  defp log("link.removed", d),
    do: gettext("The connect code for %{server} was removed from Alnasl.", server: d["server"])

  defp log("link.ok", d), do: gettext("%{server} answers again.", server: d["server"])

  defp log("link.unreachable", d),
    do:
      gettext("%{server} does not answer. The boards go on with the pairings Alnasl has.",
        server: d["server"]
      )

  defp log("link.unauthorized", d),
    do:
      gettext(
        "%{server} refuses the connect code: wrong, or withdrawn there. Alnasl has stopped asking.",
        server: d["server"]
      )

  defp log("link.unsupported", d),
    do:
      gettext("%{server} speaks a version of the board link this Alnasl does not know.",
        server: d["server"]
      )

  defp log("tournament.added", d),
    do: gettext("A tournament arrived over the link: %{name}.", name: tournament(d))

  defp log("tournament.back", d),
    do: gettext("The pairing program lists %{name} again.", name: tournament(d))

  defp log("tournament.gone", d),
    do:
      gettext(
        "The pairing program no longer lists %{name}. Nothing is reported to it any more.",
        name: tournament(d)
      )

  defp log("tournament.elsewhere", d),
    do:
      gettext(
        "A connect code for %{server} reaches %{name}, which Alnasl already has through another code. No second copy was made.",
        server: d["server"],
        name: tournament(d)
      )

  defp log("tournament.code_replaced", d),
    do:
      gettext("%{name} is asked through the connect code for %{server} from now on.",
        name: tournament(d),
        server: d["server"]
      )

  defp log("tournament.merged", d),
    do:
      gettext(
        "%{name} was in Alnasl twice, through two connect codes. Made one: %{boards} board(s) and %{games} game(s) moved to the first.",
        name: tournament(d),
        boards: d["boards"] || 0,
        games: d["games"] || 0
      )

  defp log("tournament.merge_failed", d),
    do:
      gettext("Two copies of one tournament could not be made one: %{reason}",
        reason: d["reason"]
      )

  defp log("tournament.tables", d),
    do:
      gettext("Tables %{from}-%{to} play in %{name}.",
        from: d["from"],
        to: d["to"],
        name: tournament(d)
      )

  defp log("tournament.hall_removed", d),
    do:
      gettext("%{name} is no longer played in %{hall}.",
        name: tournament(d),
        hall: d["hall"] || ""
      )

  defp log("table.tournament", d),
    do: gettext("\"%{name}\" plays in %{tournament}.", name: d["name"], tournament: tournament(d))

  defp log("seating.joined", d),
    do:
      ngettext(
        "The board now plays in %{tournament}.",
        "All %{count} boards now play in %{tournament}.",
        d["count"] || 0,
        tournament: d["tournament"],
        count: d["count"] || 0
      )

  defp log("seating.undone", d),
    do: gettext("Undone: the boards left %{tournament}.", tournament: d["tournament"])

  defp log("table.game_carried", d),
    do:
      gettext("The game under way on \"%{name}\" (%{moves} moves) went with it to %{tournament}.",
        name: d["name"],
        moves: d["moves"],
        tournament: d["tournament"]
      )

  defp log("table.game_fresh", d),
    do:
      gettext(
        "The game under way on \"%{name}\" (%{moves} moves) was closed without a result; the board begins again.",
        name: d["name"],
        moves: d["moves"]
      )

  defp log("table.game_left", d),
    do:
      gettext("The game under way on \"%{name}\" (%{moves} moves) stayed where it was.",
        name: d["name"],
        moves: d["moves"]
      )

  defp log("round.started", d),
    do: gettext("Round %{round} started: %{name}.", round: d["round"], name: tournament(d))

  defp log("pairing.changed", _d),
    do:
      gettext(
        "The pairing of this board changed in OpenPairings after the game had begun. The game is kept; the arbiter decides."
      )

  defp log("pairing.gone", _d),
    do:
      gettext(
        "The pairing of this board is gone in OpenPairings: the round was paired again after the game had begun. The game is kept; the arbiter decides."
      )

  defp log("pairing.board_moved", d),
    do:
      gettext("OpenPairings moved this game from board %{from} to board %{to}; it went along.",
        from: d["from"],
        to: d["to"]
      )

  defp log("pairing.adopted", _d),
    do: gettext("Arbiter in Alnasl: the game is the new pairing's. The moves stand.")

  defp log("pairing.set_aside", _d),
    do:
      gettext(
        "Arbiter in Alnasl: the game is set aside and a new one begins for the pairing as it is now."
      )

  defp log("destination.forced", d),
    do:
      gettext(
        "Arbiter in Alnasl: %{games} game(s) sent to %{name} again, to replace what it holds.",
        games: d["games"],
        name: destination(d)
      )

  defp log("update.requested", %{"forced" => true} = d),
    do:
      gettext("Update to %{version} started by the arbiter, with games in progress.",
        version: d["version"]
      )

  defp log("update.requested", d),
    do: gettext("Update to %{version} started by the arbiter.", version: d["version"])

  defp log(kind, _d), do: kind

  @doc "The one sentence a \"new game\" asks to be confirmed with (`nil`: nothing to ask)."
  def new_game_confirm(:replace, finished?) do
    if finished?,
      do:
        gettext(
          "Start a new game on this board? It becomes the game of the pairing and is the one sent to the results site, OpenPairings and Lichess; this one is kept in Alnasl."
        ),
      else:
        gettext(
          "Close this game without a result and start a new one? The new game becomes the game of the pairing and is the one sent to the results site, OpenPairings and Lichess; this one is kept in Alnasl."
        )
  end

  def new_game_confirm(:extra, finished?) do
    if finished?,
      do: nil,
      else:
        gettext(
          "Close this game without a result and start an extra one? The extra game stays in Alnasl."
        )
  end

  def new_game_confirm(:replace_decided, _finished?),
    do:
      gettext(
        "This game has a result. Start a new game that replaces it as the game of the pairing? The result already sent is replaced by the new game; this one is kept in Alnasl."
      )

  def send_this_confirm,
    do:
      gettext(
        "Send this game instead? It becomes the game of the pairing and replaces what the results site, OpenPairings and Lichess hold for this board; the game that was sent is kept in Alnasl."
      )

  @doc "A size in bytes as megabytes, the way a download is spoken of: \"41 MB\", \"0.4 MB\"."
  def megabytes(bytes) when is_integer(bytes) do
    mb = bytes / 1_048_576
    if mb >= 10, do: "#{round(mb)} MB", else: "#{Float.round(mb, 1)} MB"
  end

  @doc "A destination's name, as people call it."
  def destination(%{"destination" => id}), do: destination(id)
  def destination("openresults"), do: gettext("the results site")
  def destination("lichess"), do: "Lichess"
  def destination("openpairings"), do: "OpenPairings"
  def destination(other) when is_binary(other), do: other
  def destination(_none), do: gettext("a destination")

  defp tournament(%{"tournament" => name}) when is_binary(name) and name != "", do: name
  defp tournament(_unnamed), do: gettext("the hall's own tournament")

  defp moves(%{"moves" => moves}) when is_list(moves), do: Enum.join(moves, " ")
  defp moves(_other), do: ""

  @doc "The kinds the log can be filtered on."
  def log_kinds do
    [
      {gettext("Everything"), ""},
      {gettext("Boards"), "board."},
      {gettext("Moves"), "move."},
      {gettext("Clocks"), "clock."},
      {gettext("Results"), "result."},
      {gettext("Repairs"), "repair."},
      {gettext("Connection"), "outbox."},
      {gettext("Other destinations"), "destination."},
      {gettext("Table numbers"), "table."},
      {gettext("Pairing program"), "link."},
      {gettext("Tournaments"), "tournament."},
      {gettext("Pairings"), "pairing."}
    ]
  end

  @doc "`\"1.2 MB\"`."
  def size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  def size(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} kB"
  def size(bytes), do: "#{bytes} B"

  @doc "A time of day in the box's own time zone (UTC when the system offers nothing else)."
  def time(%DateTime{} = at), do: Calendar.strftime(local(at), "%H:%M:%S")
  def time(_none), do: "-"

  def datetime(%DateTime{} = at), do: Calendar.strftime(local(at), "%Y-%m-%d %H:%M")

  def datetime(seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix!() |> datetime()

  def datetime(_none), do: "-"

  # The box's wall clock: the offset the operating system reports.
  defp local(%DateTime{} = at) do
    {{y, mo, d}, {h, mi, s}} =
      :calendar.universal_time_to_local_time(
        {{at.year, at.month, at.day}, {at.hour, at.minute, at.second}}
      )

    %{at | year: y, month: mo, day: d, hour: h, minute: mi, second: s}
  end

  @doc "How this copy was started (`Alnasl.BoxInfo.kind/0`)."
  def install_kind(:installed), do: gettext("Installed (Windows installer)")
  def install_kind(:service), do: gettext("Installed as a service (Linux)")
  def install_kind(:mac_app), do: gettext("The Mac app (Alnasl.app)")
  def install_kind(:portable), do: gettext("Portable copy (a release folder)")
  def install_kind(:source), do: gettext("From source (a checkout)")

  @doc "A role in a hall, in a word."
  def role("owner"), do: gettext("owner")
  def role("arbiter"), do: gettext("arbiter")
  def role("viewer"), do: gettext("viewer")
  def role(_none), do: ""

  @doc "What a role may do, in a sentence."
  def role_means("owner"),
    do: gettext("Adds and removes bridges, invites people, and everything an arbiter does.")

  def role_means("arbiter"),
    do: gettext("Games, corrections, rounds, and the links to OpenPairings and the results site.")

  def role_means("viewer"), do: gettext("Follows the games and changes nothing.")
  def role_means(_none), do: ""
end

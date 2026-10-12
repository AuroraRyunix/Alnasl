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
    do: gettext("Set the results server and the tournament first (Setup).")

  def fetch_error(:unreachable),
    do: gettext("The results server cannot be reached. Is the network up?")

  def fetch_error(:not_found),
    do: gettext("The results server does not know this tournament. Has it been published?")

  def fetch_error(:not_json), do: gettext("That address answers, but not as a results server.")

  def fetch_error({:http, status}),
    do: gettext("The results server answered with an error (%{status}).", status: status)

  def fetch_error(_other), do: gettext("The pairings could not be fetched.")

  @doc "One step of \"Test connection\", in words: `{tone, sentence}`."
  def test_step(:server, :ok), do: {"ok", gettext("The server answers.")}

  def test_step(:server, {:error, {:unreachable, reason}}),
    do: {"bad", gettext("The server cannot be reached: %{why}", why: unreachable(reason))}

  def test_step(:server, {:error, {:http, status}}),
    do:
      {"bad",
       gettext("The server answers with an error of its own (%{status}). Try again in a moment.",
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
         "The server does not know this tournament. Check the name in the link; it must have been published at least once."
       )}

  def test_step(:tournament, {:error, :not_json}),
    do: {"bad", gettext("That address answers, but not as a results server. Check the address.")}

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
    do: {"bad", gettext("The server does not accept this relay key. Was it copied whole?")}

  def test_step(:key, {:error, :key_other_tournament}),
    do: {"bad", gettext("This relay key belongs to another tournament.")}

  def test_step(:key, {:error, :key_revoked}),
    do: {"bad", gettext("This relay key has been revoked. Ask for a new one.")}

  def test_step(:key, {:error, :rate_limited}),
    do:
      {"warn",
       gettext("The server asks to slow down. The key is probably fine; try again in a minute.")}

  def test_step(:key, {:error, :paused}),
    do:
      {"warn",
       gettext("The server has paused all sending for the moment. The key could not be tested.")}

  def test_step(:key, {:error, :not_found}),
    do: {"bad", gettext("The server does not take live boards for this tournament.")}

  def test_step(:key, {:error, {:refused, code}}),
    do: {"bad", gettext("The server refuses: %{code}.", code: code)}

  def test_step(_step, :skipped), do: {nil, gettext("Not tested: the step before it failed.")}
  def test_step(_step, {:error, _other}), do: {"bad", gettext("This step failed.")}

  def step_name(:server), do: gettext("Server")
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
    do: gettext("The server cannot be reached: %{why}", why: unreachable(reason))

  def link_error(:rate_limited),
    do: gettext("The server asks to slow down. Sending goes on by itself.")

  def link_error({:http, 503, "publishing_paused"}),
    do: gettext("The server has paused all sending. It goes on by itself when that is lifted.")

  def link_error({:http, status, _code}),
    do: gettext("The server answers with an error of its own (%{status}).", status: status)

  def link_error({401, _code}),
    do: gettext("The server does not accept the relay key. Check it in Setup.")

  def link_error({403, "relay_key_revoked"}),
    do: gettext("The relay key has been revoked. Ask for a new one and put it in Setup.")

  def link_error({403, "relay_key_wrong_tournament"}),
    do: gettext("The relay key belongs to another tournament. Check Setup.")

  def link_error({403, code}),
    do: gettext("The server refuses this box: %{code}.", code: code || "?")

  def link_error({404, _code}),
    do: gettext("The server does not know this tournament. Has it been published?")

  def link_error({:crash, _message}),
    do: gettext("Sending failed inside the box. It is tried again.")

  def link_error(_other), do: gettext("Sending failed. It is tried again.")

  @doc "Why the server refused one message."
  def entry_error("invalid_moves"), do: gettext("The server calls a move in it illegal.")

  def entry_error("moves_conflict"),
    do: gettext("The server held other moves for this game. The game was sent again in full.")

  def entry_error("invalid_request"), do: gettext("The server could not read it.")
  def entry_error("invalid_fen"), do: gettext("The server does not accept the starting position.")
  def entry_error("fen_mismatch"), do: gettext("The position did not match the moves.")
  def entry_error("ply_mismatch"), do: gettext("The move count did not match the moves.")

  def entry_error("older_than_stored"),
    do: gettext("The server already had more moves than this.")

  def entry_error(nil), do: nil
  def entry_error(code), do: gettext("Refused: %{code}.", code: code)

  # --- a board -----------------------------------------------------------------

  @doc "What the state of a board means for the arbiter: `{headline, explanation}`."
  def state_help(:out_of_sync, :ambiguous),
    do:
      {gettext("More than one sequence of moves fits the board"),
       gettext(
         "Moves went by unseen and the board cannot say which they were. Pick the right ones below; the box has kept following the game underneath."
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
         "The last moves were not seen one by one; they were worked out from the position. Orange: only one line of moves fits. Red: more than one did, and the box took one - check those against a scoresheet."
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
  def flag(:long_gap), do: gettext("3+ at once")
  def flag(:assumed), do: gettext("queen assumed")
  def flag(:unseen), do: gettext("a piece not seen")
  def flag(:arbiter), do: gettext("by hand")
  def flag(:imported), do: gettext("from PGN")
  def flag(other), do: to_string(other)

  def driver("simulator"), do: gettext("Simulator")
  def driver("replay"), do: gettext("Replay of a capture")
  def driver("dgt_serial"), do: gettext("DGT board, serial")
  def driver("dgt_bus"), do: gettext("DGT board on a loop (not verified)")
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
          "%{number} %{read} was read; the box now takes it to have been %{number} %{now} - a guess. The game from there: %{moves}",
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
    do: gettext("Result %{result}, set by the arbiter at the box.", result: d["result"])

  defp log("result.reopened", _d), do: gettext("The game was reopened by the arbiter at the box.")

  defp log("game.new", %{"by" => "pieces"} = d),
    do: gettext("The pieces are set up again: game %{n} on this board begins.", n: d["game"])

  defp log("game.new", d),
    do: gettext("Arbiter at the box: a new game on this board, game %{n}.", n: d["game"])

  defp log("repair.undo", d),
    do: gettext("Arbiter at the box: last move (%{move}) taken back.", move: d["move"] || "-")

  defp log("repair.append", d),
    do: gettext("Arbiter at the box: moves typed in: %{moves}", moves: moves(d))

  defp log("repair.edit", d),
    do:
      gettext("Arbiter at the box: move %{ply} changed to %{move}.",
        ply: d["ply"],
        move: d["move"]
      )

  defp log("repair.set_fen", _d), do: gettext("Arbiter at the box: a position was set by hand.")

  defp log("repair.resync", %{"outcome" => "accepted"} = d),
    do:
      gettext("Arbiter at the box: \"the board is right\" - found and added %{moves}",
        moves: moves(d)
      )

  defp log("repair.resync", %{"outcome" => "guessed"} = d),
    do:
      gettext(
        "Arbiter at the box: \"the board is right\" - several lines fit, %{moves} was taken",
        moves: moves(d)
      )

  defp log("repair.resync", %{"outcome" => "rejected"} = d),
    do:
      gettext(
        "Arbiter at the box: \"the board is right\" - only the moves just taken back fit (%{moves}); not put back.",
        moves: moves(d)
      )

  defp log("repair.resync", _d),
    do: gettext("Arbiter at the box: \"the board is right\" - nothing was found.")

  defp log("repair.choose", d),
    do: gettext("Arbiter at the box: said which moves were played: %{moves}", moves: moves(d))

  defp log("repair.paused", _d), do: gettext("Arbiter at the box: sending paused for this board.")

  defp log("repair.resumed", _d),
    do: gettext("Arbiter at the box: sending resumed for this board.")

  defp log("pgn.attached", d),
    do:
      gettext("Arbiter at the box: a game of %{moves} moves attached from a PGN.",
        moves: d["moves"]
      )

  defp log("outbox.offline", _d),
    do: gettext("No connection to the results server. Moves are kept.")

  defp log("outbox.online", _d), do: gettext("The results server is back. Sending what was kept.")

  defp log("outbox.blocked", _d),
    do: gettext("The results server refuses this box. Check the relay key.")

  defp log("outbox.conflict", _d),
    do: gettext("The server held other moves for this game; it was sent again in full.")

  defp log("outbox.server_ahead", _d),
    do: gettext("The server holds more moves for this game than the box does.")

  defp log("destination.offline", d),
    do: gettext("No connection to %{name}. The games are kept for it.", name: destination(d))

  defp log("destination.online", d),
    do: gettext("%{name} is back. Sending what was kept.", name: destination(d))

  defp log("destination.blocked", d),
    do: gettext("%{name} refuses what the box sends. See the Outbox page.", name: destination(d))

  defp log("destination.enabled", d),
    do: gettext("Arbiter at the box: sending to %{name} switched on.", name: destination(d))

  defp log("destination.disabled", d),
    do: gettext("Arbiter at the box: sending to %{name} switched off.", name: destination(d))

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

  defp log("door.unlocked", d), do: gettext("The PIN was given from %{from}.", from: d["from"])
  defp log("door.refused", d), do: gettext("A wrong PIN was tried from %{from}.", from: d["from"])
  defp log("setup.saved", _d), do: gettext("Setup was changed.")

  defp log("link.added", %{"reason" => _} = d),
    do:
      gettext(
        "A connect code for %{server} was added. It could not be checked yet; the box keeps asking.",
        server: d["server"]
      )

  defp log("link.added", d),
    do: gettext("A connect code for %{server} was added and accepted.", server: d["server"])

  defp log("link.removed", d),
    do: gettext("The connect code for %{server} was taken off the box.", server: d["server"])

  defp log("link.ok", d), do: gettext("%{server} answers again.", server: d["server"])

  defp log("link.unreachable", d),
    do:
      gettext("%{server} does not answer. The boards go on with the pairings the box has.",
        server: d["server"]
      )

  defp log("link.unauthorized", d),
    do:
      gettext(
        "%{server} refuses the connect code: wrong, or withdrawn there. The box has stopped asking.",
        server: d["server"]
      )

  defp log("link.unsupported", d),
    do:
      gettext("%{server} speaks a version of the board link this box does not know.",
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

  defp log("tournament.tables", d),
    do:
      gettext("Tables %{from}-%{to} play in %{name}.",
        from: d["from"],
        to: d["to"],
        name: tournament(d)
      )

  defp log("table.tournament", d),
    do: gettext("\"%{name}\" plays in %{tournament}.", name: d["name"], tournament: tournament(d))

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
    do: gettext("Arbiter at the box: the game is the new pairing's. The moves stand.")

  defp log("pairing.set_aside", _d),
    do:
      gettext(
        "Arbiter at the box: the game is set aside and a new one begins for the pairing as it is now."
      )

  defp log("destination.forced", d),
    do:
      gettext(
        "Arbiter at the box: %{games} game(s) sent to %{name} again, to replace what it holds.",
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

  @doc "A size in bytes as megabytes, the way a download is spoken of: \"41 MB\", \"0.4 MB\"."
  def megabytes(bytes) when is_integer(bytes) do
    mb = bytes / 1_048_576
    if mb >= 10, do: "#{round(mb)} MB", else: "#{Float.round(mb, 1)} MB"
  end

  @doc "A destination's name, as people call it."
  def destination(%{"destination" => id}), do: destination(id)
  def destination("openresults"), do: gettext("the results server")
  def destination("lichess"), do: "Lichess"
  def destination("openpairings"), do: "OpenPairings"
  def destination(other) when is_binary(other), do: other
  def destination(_none), do: gettext("a destination")

  defp tournament(%{"tournament" => name}) when is_binary(name) and name != "", do: name
  defp tournament(_unnamed), do: gettext("this box's own tournament")

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
end

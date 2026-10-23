# How Alnasl works

Five parts, in the order a move passes through them: a **driver** reads a
board, the **recorder** writes down what it read, the **tracker** works out
the moves, the **outbox** gets them to the server (and the other
**destinations** get them elsewhere), and the **round model** says which
board is which game - of which tournament, as the **link with the pairing
program** tells it (section 6a). This document is about the reasoning; the
moduledocs have the details.

```
driver ──whole positions, clock──▶ board process ──▶ recorder (raw, per board)
                                        │
                                        ▼
                               session = tracker + clock          (pure, no I/O)
                                        │ moves, corrections, status
                                        ▼
                          game saved (SQLite) ─▶ PGN rewritten ─▶ outbox row
                                                                      │
                                                                      ▼ in order, when it can
                                                                 OpenResults
```

## 1. Positions, not moves

A driver delivers **the whole board** every time anything on it changes: 64
squares, each a piece or empty (`Alnasl.Position`, a8 first). Not moves and
not changes. An electronic board in update mode sends single-square changes; the
driver applies them to its own picture and passes on the picture, and every
few seconds asks the board for a full dump again - so a lost byte heals, and
nothing above the driver can drift from the board.

What a move is, is decided in one place, from positions, by legality alone.

## 2. The tracker: position → moves

`Alnasl.Tracker` is a pure state machine. It never looks at a clock: every
call is given the time, and returns the new state and events. A test plays a
five-hour game in a millisecond; the board's process runs the same code in
real time (and a simulated board at 20x brings its own time along, so the
tracker's patience scales with it).

It holds:

- the **certain** position and move list - only what legal moves explain;
- `phys`, what the sensors should read for that position (the same board,
  except where a pawn was left standing on its promotion square);
- `raw`, the last board reported, and since when it has read like that;
  `before`, the board it read before that.

For every board reported, the first of these that fits:

| # | The board is... | Then |
|---|---|---|
| 1 | the certain one | in sync |
| 2 | one legal move away | that move - once it has stood for `settle_ms` (250), or at once on **its own clock press** (the press that stops the mover's clock; the press of the move before, told late by the clock, confirms nothing) |
| 3 | an earlier certain position (1-2 plies back) | a **takeback**: a correction, after `takeback_settle_ms` (1500) |
| 4 | one move away from the position *before* the last move | the last move is **replaced**: a rook that rested on a square on its way, a hand that let go and took hold again |
| 5 | two or more legal moves away | the **reconstruction** (§3): the moves are found, taken and marked |
| 6 | what was one legal move in the reading before, with one or two *other* pieces now in the air | that move, at once: **the next hand is on the board** |
| 7 | none of these | nothing. A hand, half a capture, a knocked piece. Status "Settling" |

Only when 7 persists - `transient_ms` (8 s), or `lifted_ms` (60 s) when the
board is just the certain one with a piece or two missing - does the status
become **out of sync**. The certain position is frozen, the arbiter is told,
nothing more is sent for that board, and the tracker keeps watching: the
moment a board arrives that 1-6 explain, it carries on by itself.

Before the first move, 7 is "Waiting for the starting position" and never
an alarm: pieces are being set up. One exception: a board that *stood* in
the starting position, has left it by something that is not a move, and
over which the clock is then pressed. The game has begun and the box did
not see how; that is out of sync like any other.

### The cases that need more than one rule

- **A capture in two steps**, in either order, passes through boards with a
  piece or two missing. None is a legal move's result; rule 7 holds them.
- **Castling as two piece moves.** King first: the king two squares from home
  is not a legal move by itself; rule 7, then rule 2 when the rook lands.
  Rook first is the awkward one, because the rook move *is* legal: a rook
  move that could be the first half of a legal castle is held for
  `castle_hold_ms` (2.5 s) instead of 250 ms, and rule 6 does not apply to
  it while the king is the piece in the air. If the king follows later
  still, rule 4 replaces the rook move by the castle.
- **En passant** in either order: the intermediate boards are not legal.
- **Promotion.** The piece is read from the board: pawn off the seventh,
  whatever stands on the eighth a moment later. When the pawn itself is
  left on the last rank (no spare queen at hand), the move is accepted after
  `promotion_hold_ms` (4 s) as the default piece (a queen, configurable) and
  flagged `assumed`; `phys` remembers that this "queen" reads as a pawn, so
  it can move on as one. A queen put there later changes nothing; another
  piece rewrites the promotion and replays the moves after it. A "queen"
  that then moves as only another piece can is rewritten into that piece -
  every assumed promotion of the last 60 plies is asked, latest first, so
  the first of two pawns left for knights is found out when it jumps. See
  "A promotion taken at once" below for the hard version.
- **A repeated position is not a takeback** when legal moves explain it. A
  queen checking from f1 and f2 in turn returns the board to where it was
  two plies ago; rule 5 is asked before rule 3 for takebacks of more than
  one ply.
- **The next hand before the move has landed.** Rule 6 needs the move to
  have been on the board alone for one reading; in a hall the next player
  sometimes has a piece up while the last one is still in the air. The
  board is then one legal move on, but for one or two pieces of the side
  that moves next, missing from squares the move does not touch
  (`move_and_lift/1`). Believed after `settle_ms` or on a press, and only
  when a reading shows the moved piece gone from its square while those
  pieces were still on theirs - pieces that vanish in the same reading as
  the move are moves nobody saw, not a hand. And not when the missing
  piece stood beside where the move lands and came there in the last few
  moves: that is as likely the move's capture, read one square off.
- **A knocked piece put back under the next hand.** A piece knocked onto a
  square it could legally go to stands there like a move and, without
  takebacks (the fast-play preset), is one. When it goes back while the
  next hand is already over the board, no position the game holds leads
  on. On a press, or once the board has stood `deep_settle_ms`, the last
  ply is dropped and the board searched from before it, by the squares
  that changed, for a line of at most three moves that does not make the
  dropped move again (`undone/2`). Marked red: a move that was seen is
  being unsaid.
- **A slider resting on its way out of check.** A bishop going f5-e6-d7
  against a check from a4 rests on e6, where it blocks nothing. The board
  then makes sense with no move at all if the bishop's earlier move went to
  e6 and was misread as f5 - and the misread rule used to say exactly
  that, 250 ms in. A rewrite that adds no move and puts back a rook,
  bishop or queen of the side to move, while that side is in check, now
  waits for the press, or for `deep_settle_ms`: a slide stops for well
  under a second, a straightened piece is followed by the clock. Waiting
  for every piece of the side to move, check or not, was tried first; it
  cost more misreads read wrong than it saved.
- **A capture taken back, and the hand straight back for another.** 1...Rxg8
  taken back, and the same rook lifted for 1...Rxh7 with the h7 pawn
  already off: for a moment the board is 2. hxg8=R, the rook just taken
  back on its square and the piece that took it gone. A move that puts
  back on the last ply's square exactly the piece that ply captured, after
  the board was seen back where it was before that ply, is held for
  `takeback_settle_ms`, or until the press (`echo?/2`). A real recapture
  with a piece of the same kind waits the same way.
- **A move taken back while the game goes on.** A move stands, is taken
  back, and before the takeback has stood its `takeback_settle_ms` the
  player makes another move and the opponent's hand is already up - two
  hall habits at once. The board is then explained from after the move
  taken back by some longer line, which used to go in behind the move
  that was taken back, that move unmarked. Now, when the board was seen
  back where it stood before the last move, the search from before it
  (`undone/2`) is asked as well, on the press or once the board has
  stood `deep_settle_ms`, and wins if it needs fewer moves in all
  (`undo_instead/3`), searching as deep as the line it has to beat; a
  piece still in the air over a move from there is
  waited for, as any hand is. Red: a move that was seen is being unsaid.
  Over 10,000 games of the four hall faults with the benign ones, this
  and the next hand together took the unmarked wrong games from 114 to 0.
  `undone/2` also compares moves by their squares now, not their
  notation: Black's Rf3 is not White's Rf3 made again.
- **A guess revised is still a guess.** Rule 4 rewrites the last move
  into the one move from the position before it that the board now
  shows. When the last move was a red guess, the move it becomes is red
  too: what put the guess in doubt is the board that made it a guess. The
  case that found it: a knight lifted beside a square that kept reading
  the knight that had left it, guessed onto that square, then "revised"
  into the other knight - unmarked, and wrong.
- **The result.** Mate, stalemate and bare kings are read from the position;
  the kings set on the four centre squares is the players' signal (ASSUMED
  convention: both on light squares 1-0, both on dark 0-1, one on each a
  draw). All of them are *suggestions*. The game is finished when the
  arbiter says so, and only then is `status: finished` sent - unless Setup
  says mate and stalemate may go by themselves.

### A piece not seen

A real game on board 06310: the knight that had just gone to f3 was lifted
off and stood beside the board while five moves were played, then came down
on e5. Rule 7 held every one of those boards ("a piece in a hand"), and when
the knight landed the game was six plies on - out of sync.

So, between rules 6 and 7:

- **When.** The board was the expected one with exactly one piece gone and
  nothing else different (`absent`); that square has stayed empty since;
  and now the board is one legal move by *another* piece away from the
  certain position, counting the absent piece as still standing there. The
  move must stand for `unseen_hold_ms` (2 s), or be pressed on the clock,
  or be followed by the next hand (rule 6, same supposition). Two moves
  found by the search on the same supposition count too, flagged
  `recovered`.
- **Then.** The move is accepted as a plain move. The piece stays in the
  position; `phys` has its square empty, and the tracker's `unseen` list
  names it. The board compares equal again, the status is Live, and the
  site shows a warning for as long as it lasts. Plies accepted meanwhile
  carry the flag `unseen` (stored, not shown beside each move).
- **How it ends.** The piece is read on its square again (it was there all
  along). Or a piece of that kind and colour appears on a square the unseen
  one can legally move to, on its side's turn: that is its move - the move
  generator is asked for moves *from* the unseen square too, and a move
  from an empty `phys` square puts the position's piece on the target. Or a
  piece of the other colour lands on the square by a legal capture.
- **What it does not explain.** Anything that is not legal with the piece
  on its square: a piece moved onto or through it, the piece appearing on
  the wrong side's turn or on a square it cannot reach. That is rule 7 and,
  in time, the alarm. The piece is never dropped from the game by the box:
  if it was in fact captured unseen, the arbiter says so.
- **Limits.** One piece at a time (a second piece gone is more likely an
  exchange that went by unseen, which the search has). A king only once
  the clock has been pressed over the other piece's move, or the board has
  stood like that for as long as the alarm waits (`transient_ms`): nobody
  parks a king beside the board, but a sensor that stops hearing a king
  beside its neighbours does (see "A piece heard as another"), and a
  king in a hand for eight seconds while another piece moved is the less
  likely story. Never during half a castle. No limit in plies: a warning
  that stays is honest, an alarm after N moves would be arbitrary.

What keeps an ordinary move from being read as this: a piece in the air
during its own move is followed by *its own* landing, which rule 2 takes
first. A capture with the captured piece off first leaves the capturer's
landing on that square - rule 2 again. A capturer that rests on the way
(queen to g6, then on to f7, with the f7 pawn already off) is accepted as
"Qg6, pawn not seen" if it rests longer than the hold, and put right by
rule 4 when it lands. Castling with the king in the air while the rook
goes across cannot be it: never a king. A takeback does not put a piece
out of sight again - rule 3 skips an earlier position whose unseen piece
has been seen since. And two pieces of opposite colours gone at once are
no longer searched as an unseen exchange when one of them was already gone
by itself: that is a piece out of sight and a hand.

Not covered: a takeback of the very move that began it, while the piece
is still away (the board then matches nothing the tracker remembers, and
is the alarm after `transient_ms`).

### A square that is not read

A sensor dies. The square reads empty whatever stands on it (`off`), or
goes on reading the piece that stood there when it broke (`stuck`). Either
way the first move to or from that square leaves a board that no move
explains, and before this every game on such a board stopped there for
good: no hand ever puts a broken sensor right, so rule 7 waited, the alarm
came, and every board after it was the alarm again. One dead square cost
the rest of the game.

- **Found out, stuck.** A piece appears on a square it can reach in one
  legal move from square S, while S still reads it: two of a piece where
  the game has one, and nothing lifted. A hand cannot do that; a spare
  piece on the table could, which is why it must stand `unseen_hold_ms`,
  or be pressed on the clock, like a piece out of sight. Exactly one such
  move, or nothing: two knights that can both reach d7 leave the box no
  wiser about which sensor died, and that stays the alarm.
- **Found out, off.** Harder, because a piece going onto a square that
  reads empty looks exactly like a hand holding it. A square is first
  only suspected: a piece taken to stand on it unseen ("A piece not seen")
  moved off it, and it went on reading nothing - which a pocket does too.
  It is found out when, later, a piece vanishes in the one way that is a
  legal move onto the suspected square, and the clock is pressed for it.
  A pawn promoting onto it goes in as a queen marked assumed, like any
  promotion onto a square nothing is read on: the flag used to be lost
  on this path, and an underpromotion there was a wrong move nobody
  marked (2 games in 10,000). On time alone it is not: a piece parked beside the board vanishes too,
  and an earlier version that believed the hold declared live squares
  dead in the bench's "piece not seen" suites. A square that breaks while empty and is first used by
  a piece arriving is not caught: that piece becomes a piece out of sight
  where it stood, and what follows is what the box makes of that.
- **Then.** The square goes on the tracker's `dead` list for the rest of
  the game (and survives "set position", which is the same board). What it
  reads is replaced by what the game has there (`sensed/2`) before anything
  else looks at the board, so it no longer differs from anything. A move
  may start or end on it: the one-move comparison leaves dead squares out,
  and the move generator is asked for moves from them. A move onto it
  shows only as a piece gone, so it must stand `unseen_hold_ms` or be
  pressed - and when it was the hold and not a press, the move is marked
  guessed (red), because a hand that holds a piece two seconds over a
  square it could go to reads exactly the same. A pawn promoting on it promotes to the usual piece, marked
  assumed: what it became reads as nothing at all.
- **Found out, off, at the first move onto it.** A square that broke
  while empty has no suspicion to go on, but sometimes it has this: the
  clock is pressed, the press count says a move is owed, and all the
  board shows is one piece of the side to move gone - with exactly one
  empty square it could legally go to. A hand does not press the clock
  with the piece in it, and a piece knocked over by the late press of the
  move before is caught by the count. That is the move, and the square is
  dead (`onto_unread`). Not a pawn promoting there: four pieces, one
  square, nothing read.
- **Said once.** `{:dead, squares}` when the list grows; the site puts
  "Square b8 seems dead" beside the game's state and on the Round tile,
  and the log says what that means. Not an alarm per move: the warning
  stays, the game goes on, and the board is looked at after the game.
- **Not covered.** A square that reads a piece where the game never had
  one (a phantom, rather than a piece that stayed) is an unexplained board
  until somebody looks. The reconstruction (rule 5) does not search
  through dead squares: several moves at once across one is the alarm.
  And a repetition across a square that reads empty can read as the
  earlier position it repeats: in one bench game (a perpetual check with
  the king going to and fro over the dead square b5) the last moves were
  read as a revision and the game ended four plies short with nothing
  marked. It happens with the detection off just the same.

The simulator has the fault (`dead_square: {ply, :off | :stuck}`, a square
the game uses at least twice from then on), and the bench three suites
for it. Three passes, 69 games each pass, before (the detection switched
off, `dead_squares: false`) and after. The three "piece not seen" suites
are identical (207 exact each), which is the check that matters: they are
the ones a suspicious tracker would ruin.

| suite | | exact | rec ok | rec WRONG | guess ok | guess WRONG | flagged | alarm | silent | rec plies | guess plies | alarms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| dead square, reads empty | before | 3 | 21 | 6 | 4 | 103 | 0 | 68 | 2 | 216/503 | 456/696 | 1832 |
| | after | 55 | 14 | 4 | 3 | 81 | 0 | 48 | 2 | 172/405 | 350/529 | 1474 |
| stuck square | before | 9 | 0 | 4 | 0 | 17 | 4 | 173 | 0 | 40/73 | 139/169 | 2792 |
| | after | 195 | 0 | 0 | 0 | 1 | 2 | 9 | 0 | 0/0 | 13/16 | 117 |
| stuck + benign 5% | before | 9 | 0 | 2 | 0 | 21 | 2 | 173 | 0 | 21/38 | 129/154 | 2766 |
| | after | 159 | 0 | 0 | 21 | 14 | 2 | 11 | 0 | 1/2 | 28/57 | 210 |

Since then (one pass, 69 games): the first move onto a square that broke
while empty is taken when only one square was possible, which takes the
suite from 14 exact to 21 (27 guessed wrong instead of 32, 13 alarms
instead of 15), and nothing else in the bench moves.

**Why the rest stays where it is.** In every one of the 48 games still
not exact, the first move to touch the dead square is a piece arriving
on it. Its board is one piece gone; a hand reads the same, a pocket
reads the same, and the clock says a move happened but not where. With
two or more empty squares the piece could have gone to, each is a game
that fits every reading so far. What separates them comes later and
piecemeal: the piece leaving that square (from where?), other pieces
crossing it (they vanish too), squares later read with a piece on them
(not the dead one). Turning that into an answer means carrying a move
whose destination is unknown for an unknown number of plies, with the
side to move and every later move's legality depending on it - a search
over hypotheses through a square that is not read, which the
reconstruction deliberately does not do (see "What keeps it bounded").
Guessing one is what the tracker already does when the piece is next
seen, and marks red. A guess that is right a third of the time is not
made better by being made earlier; it would only be made more often.
What would help is cheap and physical: the square named after the game,
and the board looked at.

The stuck square is solved but for nine games, nearly all two knights that
could both have made the move. The square that reads empty is halved, not
solved: most of what is left is a square that broke while empty, and a
piece arriving on it, which nothing here can tell from a pocket. The two
silent games are the repetition above, before and after alike. In the
benign mix the clock misses presses, so moves onto the dead square stand
on the hold and come out red - 21 of them right, 14 not.

### A promotion taken at once

The hard one. The pawn reaches the last rank and the player has no spare
queen at hand, so the pawn stays there (or the new piece goes down and is
taken before the board settles), and the opponent captures it on the
next move. What the board shows: a pawn on the eighth rank, then a
different piece on that square. What the promoted piece was is not on the
board at any moment long enough to read.

- **Both moves are found.** The promotion is accepted as the default
  piece, flagged `assumed`, the capture after it as a plain capture. The
  game is right but for the letter after `=`, and says which letter it is
  not sure of. Never a silent wrong piece: the flag goes out with the game.
- **A piece read for a moment counts.** When the paths that explain a
  board differ only in the promoted piece, the readings since the pawn
  left the seventh are asked: a knight seen on the square for 100 ms,
  pawn gone from below, is the knight (`unread_promotions`). The bench's
  "piece read <250 ms" suite gets every game right with nothing marked
  red or assumed.
- **Later play rewrites it.** A pawn left standing in for a "queen" that
  then moves like a knight is a knight: up to 60 plies back, a promotion
  still marked `assumed` whose stand-in pawn is still standing (or was
  taken) is tried as each other piece, and if exactly one replays the
  game to this board, that is the promotion (`promotion_retry`), rewritten
  and the moves after it replayed. Several: one taken, still marked.
- **The stand-in can be out of sight.** A pawn standing in for its queen
  may go unread like any piece; it is supposed under the game's piece, not
  the pawn's (`standing?/2`).
- **What it cannot do.** A rook, bishop or knight taken at once, or never
  moved again, never says what it was. It stays a queen, marked assumed,
  for the arbiter: the bench's "pawn left" suites end with 6 of 69 games
  marked like this, every one an underpromotion, every one marked.

The simulator does it on purpose (`promotion_capture: :pawn_left |
:quick`, `promote_as: :cycle`): the game is cut after its first
promotion that can be taken, and the capture is played. `leave_pawn` now
applies to every promotion, not only to a queen, and draws its dice on
the side (`aside/3`) so that the suites that do not use it see the same
random stream as before. That is also why four benign suites now show
one assumed game each: the same underpromotion (a8=N, pawn left, the
knight never moves again), which the fault used to skip.

### A piece heard as another

A DGT board tells a piece by the frequency its coil answers at. Two
pieces close together disturb each other (ASSUMED: the mechanism and the
pairs are inferred from what boards do, not from documentation): a piece
can read as nothing for a moment or for as long as the two stand there
(masking), or read as another piece of its colour whose code sits next to
its own (misidentification: in the DGT order P, R, N, B, K, Q a bishop
reads as a knight or a king, a rook as a pawn or a knight). The
simulator has both (`mask`, `mistype`), brief (100-700 ms) or lasting
until the piece is touched.

- **A wrong kind on the right colour is the board, never the game.** No
  move turns a piece into another of its colour on the same square, but
  a promotion's. So a square that holds the right colour and the wrong
  kind (`retyped`) is taken as if it read the game's piece, and whatever
  else the board shows is judged as usual: a move made beside it is a
  plain move, unmarked. A pawn on the last rank standing in for its piece
  is left out: there a piece appearing is the promotion being put right.
- **A piece that lands heard wrong** is the move its squares say (from
  and to, colour right, kind wrong), if exactly one legal move fits - but
  only after `unseen_hold_ms` or a press, because a king that has landed
  on g8 with its rook still in the air reads exactly like a rook heard as
  a king. A square read as a king, or a pawn on its last rank, is never
  this.
- **A piece not heard** is a piece out of sight ("A piece not seen"),
  including beside a piece heard wrong, and including a king, on the
  conditions given there.
- **Said, not alarmed.** A piece heard as another for `unseen_hold_ms`
  goes on the `confused` list; the board's page and the Round tile say
  "White bishop on e4 reads as a knight" for as long as it lasts.
- **A hand beside it is a hand.** A piece heard as another while the
  rest of the board agreed with the game (`misheard`) is put back as the
  game has it before the board is judged a hand, for as long as it reads
  the same (`unheard/1`). Otherwise a capture half made beside it - the
  taken piece off, the taker in the air - was three changes, not two, and
  250 ms in the search found an exchange on the misheard square that ends
  with exactly the kind it reads as: a white pawn read as a rook, and
  34...Qxb3 35.Rxb3. Over 10,000 games each, that was 19 of the 21 wrong
  games in the two "reads as another" suites (the other two are the
  promotion below), and all 21 now come out exact. Only pieces heard wrong *while
  everything else agreed*: a piece of another kind that turns up along
  with moves nobody saw is more likely one of those moves.
- **A promotion keeps the piece it was pressed with.** The revision rule
  rewrites the last move when the board shows another legal move from the
  same position, which is right for a piece set down and moved on before
  the press, and was wrong for a promoted bishop heard as a knight four
  seconds after the clock was pressed for it: `a1=B+` became `a1=N`,
  unmarked. Once the clock has been pressed for a promotion (`reheard?/2`),
  the same promotion to another piece is the board mishearing, like any
  other piece. Without a clock there is nothing to tell the two apart.
- **When it matters.** The piece doing what only the piece it is heard as
  could (a "knight" jumping from a bishop's square) is a board nothing
  explains, and the alarm as for any such board. Nothing is ever moved
  on the strength of the wrong kind.

| suite (69 games, 1 pass) | | exact | other right | assumed | alarm | silent | alarms |
|---|---|---|---|---|---|---|---|
| reads as another, 5% | rule off | 20 | 2 | 0 | 46 (+1 marked wrong) | 0 | 702 |
| | on | 69 | 0 | 0 | 0 | 0 | 0 |
| reads as another, 15% | rule off | 6 | 4 | 0 | 59 | 0 | 938 |
| | on | 69 | 0 | 0 | 0 | 0 | 0 |
| both 10% + benign 5% | rule off | 4 | 4 | 0 | 61 | 0 | 919 |
| | on | 68 | 0 | 1 | 0 | 0 | 5 |
| both 10%, no clock | rule off | 7 | 4 | 0 | 52 | **6** | 750 |
| | on | 69 | 0 | 0 | 0 | 0 | 0 |
| reads empty, 5% / 15% | either | 69 | 0 | 0 | 0 | 0 | 0 / 1 |

"Rule off" is `crosstalk: false`, which is what 0.6.0 did with a wrong
kind: an unexplained board, and in time the alarm - or, six times without
a clock, a wrong move nobody marked, because a "knight" on a bishop's
square made some other line fit. Masking is the king rule in "A piece not
seen" and needs nothing new. The one assumed game is the underpromotion
above.

### After the arbiter changes the game

Undo and "change a move" make the game disagree with the board on purpose.
The board is then left alone until it next changes - re-reading it at once
would put the undone move straight back.

## 3. The reconstruction

A board that has stopped following its game is worse than a board that
follows it with a caveat. So when the board is a position the game as it
stands does not lead to by rules 1-4 and 6, the tracker does not stop: it
looks for the moves in between (`reconstruct/4`), takes what it finds, and
**marks every move it did not see**:

- **reconstructed** (`recovered` in the data; orange, a diamond): exactly
  one line of legal moves leads from the game to the board, and a search of
  every legal move agrees it is the only one;
- **guessed** (red, a question mark): more than one line did, and one was
  taken - or one was found by a search that cannot vouch for it being the
  only one (deeper than the blind search reaches, or resting on a piece
  taken to be unseen).

No line at all, within the budget: rule 7 and, in time, the alarm, as
before. The marks are on the move in the list, counted on the Round tile
and the Boards list, and written in the log. Nothing found this way is
silent, which is what makes searching deeper than two plies defensible:
the old stance ("two, because at four, 11 of 207 illegal moves were read
as games never played") was about wrong games nobody was told about.

### Where it looks

`Alnasl.Tracker.Search` walks sequences of legal moves, depth-first with
iterative deepening, and returns every sequence of the first length that
has one - **the shortest explanation wins**. It is asked, in this order:

1. **Guided by what was seen**, up to `search_depth` plies (8; 2-12 in
   Setup). The tracker keeps the readings since the game last matched the
   board (`trail`). A move made while the board was being read changed both
   its squares in some reading, so only moves that start and end on a
   square that read differently at some moment are tried: a handful a ply
   instead of thirty. This is the search that follows a game that got
   ahead of the box move by move - six plies in the recording that began
   all this - and it costs milliseconds.
2. **By evidence** - any move of a piece that was seen to *leave* its
   square (or that has already moved earlier in the line) - for what fell
   between two readings: a capture and its recapture on one square, a pawn
   that went two squares and was taken in passing. Two plies at once; up to
   `blind_depth` (4) once the board has stood for `deep_settle_ms` (5 s).
   What the guided search finds is checked against this one wherever it
   reaches, and one line found by it is the one line the readings allow.
   **This is the widest search of a board the box was connected to.** A
   piece that stood on its square in every reading did not move, however
   much a move of it would help (see "No phantoms").
3. **Blind** - every legal move - only across a hole in what the box
   knows: the driver said the board was gone (`Tracker.deaf/1`: a
   disconnection, or three polls in a row missed on a loop). Whatever is
   found across a hole is a guess, marked red and `long_gap`, and held to
   the clock where a clock was heard.
4. **With the absent piece taken to be unseen** (§2), two plies. Guessed.
5. **From before the last reconstructed moves**, when the board has stood
   unexplained for `transient_ms` and the alarm is next: those moves
   explained the board then, and do not explain this one, so the question
   is asked again from before them. The game is corrected, not extended.

Before the first move, a board that is not the starting position is
pieces being set up, and is not read as an opening: two plies (a board
plugged in late), no more, until the clock has been pressed or the arbiter
says "the board is right".

### No phantoms

A real board, connected throughout: 1. e4, twenty-four minutes of
nothing, 1...e5 - and then Black's knight to c6, a second black move in a
row. The blind search made that legal by sending White's bishop to a6 and
back: `2. Ba6 Nc6 3. Bf1`, marked as a guess. The bishop stood on f1 in
every reading.

Three things came of it.

- **Evidence.** The rule above: connected, a line may only move pieces the
  readings saw leave their squares. It is a rule about the *from* square
  on purpose - a move's destination can go unread (taken there a moment
  later), its origin cannot stay as it was. It is also why the simulator's
  "missed ply" rows hardly move: a ply the box did not read still leaves
  its origin square empty in the next reading, which is what a real board
  that failed to report gives too. What the rule forbids is exactly the
  move that left no trace at all.
- **Never out and back.** A piece from A to B and, with its side's next
  move, from B to A, taking nothing, is two tempi spent on nothing. It was
  ranked last; it is now not a line at all (`Search`, "Never out and
  back"): no walk returns one, not for the tracker, not for "the board is
  right", not on the choice screen.
- **`long_gap` means a hole.** It used to be put on any three moves found
  at once, and exempted nothing - but the name promised a reason, and a
  long think is not one. A serial board pushes every change and is read
  whole every few seconds; a loop is polled all the time. Quiet is a
  player thinking. `long_gap` is now only on moves found while the box was
  `deaf?`, which only a driver's "disconnected" (or three missed polls in a
  row) sets, and which ends when the board is explained again or comes
  back as it was. The same flag is what lets the blind search run, lets
  the press count be ignored (a board that was not heard, its clock was
  not either), and lets the choice screen offer lines without evidence.

### What the board plainly shows

When nothing explains the board, it may still say one thing clearly, and
then the alarm has a name (`named/1`), raised once that has stood for
`unseen_hold_ms` (2 s) rather than after eight seconds of "unexplained":

- **A move out of turn** - `{:out_of_turn, move}`: the board is the game
  plus one legal move by the side that is not to move. "Black moved (Nc6),
  but it is White's turn."
- **A move that is not legal** - `{:illegal, %{piece, from, to, why}}`: one
  piece went from one square to another and that is not a move it has:
  something stands in its way, that piece does not move like that, a piece
  of its own side stands there, or it leaves its own king in check. "A
  move that is not legal: white bishop c1-g5."

Neither adds anything to the game and neither is given a mark: nothing was
played. Both are gone the moment the piece is back, like any alarm. The
board's page offers "A move is missing before this", which goes to where
moves are typed, for the arbiter who knows the board missed one. There is
no "accept as played": an illegal move is taken back.

### A move misread

The first game on a real board with the reconstruction in it: White played
3. d4 and set the pawn down between d3 and d4, and the board read d3. Then
3...e5 4. dxe5, which from d3 a pawn cannot do. A search that only adds
moves got the pawn to d4 by moving it again and spent the tempo on a
bishop: `4. d4 Ba3 5. dxe5 Bf8`. Ten moves, seven presses of the clock, and
a bishop that never left f8.

So the reconstruction also asks whether a move it *has* is wrong
(`rewrites/1`), and keeps the question small:

- one of the last 6 plies (a piece left crooked for two moves each, and the
  "move" that was somebody straightening it), not entered by the arbiter,
  not a castle;
- replaced by another legal move of the **same piece** to a square **next
  to** the one read: one short or one long on its line, or beside it. A
  piece set down between two squares is the physical cause, and it covers
  the pawn read on the third rank that went to the fourth and the capture
  read as landing next door;
- the moves read after it played again, each from and to the squares it
  was read on. If one no longer can be, this is not what happened. One is
  left out: a "move" from the square the piece was read on to the square
  it is now taken to have been on - somebody straightened it, on his own
  time, and it was read as a move;
- and then **nothing more, or one move**. Two would be rope enough to
  explain any hand over the board.

Two ways the board can agree with the rewritten game. The piece is no
longer where it was read - it moved on (the pawn took on e5), was taken
where it really stood, was straightened - and the board is simply the
rewritten game's. Or it still reads there, and another move is legal only
with it on the square beside (a pawn that jumps over the square a bishop
reads on): then the piece is carried the way an unseen piece is, with the
square it reads on (`ghost`): "White bishop read on d3, taken to stand on
c4", until it is read where it stands, moves, or is taken. The multi-ply
search does not know about a piece carried so; while one is, only single
moves are followed.

The rewritten move is marked `rewritten` and keeps what it was read as
(`read`, shown beside it and said in the log: "3. d3 was read; the board
now says it was 3. d4"); the game is sent again whole. Orange when it is
the only rewrite of its cost and the game then has as many moves as the
clock was pressed for; red otherwise - without a clock, always. The move
as it was read stays an option on the choice screen.

What it is not allowed to explain, each found by a row of the fault
matrix going wrong:

- a hand: the board is the game, or one plain move on, with one piece
  missing (a knocked-over queen beside a bishop that went to f4 reads like
  "the queen was on f4 all along, and the bishop took her");
- a move read since that would have *taken* the rewritten piece without
  anybody seeing a capture - not until the board has stood for
  `deep_settle_ms` (a king put on a bishop's square while the two are
  swapped back);
- a move legal only with a piece beside where it still reads, until it has
  stood for `unseen_hold_ms` (a queen resting on her way with her king in
  check is not proof that the checking piece is elsewhere);
- a castle.

What it costs: a player who makes an illegal move with a piece that moved
a moment ago can be read as "the move before was one square off". In the
fault matrix that is 13 of 207 illegal-move games, marked orange. The
board cannot tell the two apart; a misread is the likelier of them.

### Ghosts, borrowed from the decoder

The probabilistic decoder (branch `decoder`, `docs/plan-decoder.md`
there) was measured against the tracker and lost nearly everywhere. The
one idea worth keeping was its **ghost**: a reading on a square taken as
possibly a piece that really stands next door, kept as an explanation
instead of being argued away by inventing moves. The tracker already
carried a ghost once a rewrite found one (`unseen` with `ghost`); what it
lacked was the use of one afterwards. Two things now follow from it, and
nothing else of the decoder came along - no beam, no sensor model, no
probabilities.

- **A ghost straightened onto a third square.** A bishop read on d3, put
  right as c4 because a pawn then jumped over d3 (e2 would have done as
  well, and lost on its name), carried as "read on d3, standing on c4".
  Then somebody straightens it - onto e2. The rewrite used to refuse to
  look at all while a piece was carried, so the game kept c4 and the board
  went its own way. Now a carried ghost does not stop `rewrites/1`, and
  the move it belongs to is asked about again around the square it was
  *read* on (`shown_at/2`), not around the first guess. The reading is
  the evidence; the guess was only a guess. It is still a rewrite, marked
  like one, and `read` is still what the board first said.
- **A straightening that reads as a move, and then a move that reads as
  a takeback.** A rook read on h6 that stood on h5 is nudged home on its
  own side's time: h6-h5 is legal, and is accepted as that side's move.
  Then the player really plays Rh6, and the board is exactly what it was
  before the "move" - a takeback, by rule 3, and a whole move lost. The
  press tells them apart: a move taken back is never pressed for, and a
  move made always is. So when the clock was pressed after the last move
  was read, and that makes the presses as many as the moves, the takeback
  is first offered to the rewrite: the earlier move to h5, the
  straightening dropped (`straight/4`), and Rh6 as the new move
  (`straightened/2`). A piece seen straightened since is not taken to be
  crooked still. No clock, a clock not heard, or the debt of forgotten
  presses standing in for the missing one: a takeback, as before.

Measured with `mix alnasl.bench`, the same seeds before and after, all
suites. Every suite not shown is identical to the game in every column
(verdicts, marked plies, alarms, named alarms, searches that gave up).

| suite | | exact | rec ok | rec WRONG | guess ok | guess WRONG | alarm | misread | silent | wrong marked plies | alarms |
|---|---|---|---|---|---|---|---|---|---|---|---|
| between, clock, 1 pass | before | 25 | 25 | 3 | 4 | 6 | 1 | 5 | 0 | 13/112 + 32/58 | 39 |
| | after | 25 | 25 | 2 | 7 | 4 | 1 | 5 | 0 | 0/95 + 7/36 | 20 |
| between, no clock, 1 pass | before | 25 | 0 | 0 | 29 | 9 | 1 | 5 | 0 | 11/18 + 37/155 | 42 |
| | after | 25 | 0 | 0 | 30 | 8 | 1 | 5 | 0 | 11/18 + 32/150 | 42 |
| between, clock, 3 passes | before | 77 | 80 | 5 | 18 | 9 | 2 | 16 | 0 | 24/288 + 35/92 | 48 |
| | after | 77 | 80 | 4 | 21 | 8 | 2 | 15 | 0 | 11/271 + 10/72 | 29 |
| between, no clock, 3 passes | before | 77 | 0 | 0 | 98 | 14 | 2 | 16 | 0 | 22/32 + 40/351 | 51 |
| | after | 77 | 0 | 0 | 99 | 13 | 2 | 16 | 0 | 22/32 + 35/346 | 51 |

What it does not touch: a piece that moves on legally from the square it
was misread on (the `misread` column) - no reading tells that game from
the one played, ghost or no ghost; and a tie between two neighbours that
both make the next move legal, which is still settled by name and marked
red. One game in the three-pass run moved from `misread` to `guess WRONG`
at the same, undetectable, first difference: the straightening was found
later on and the rest of the game came out right, where before the game
ran two plies out of step from there, unmarked.

A note on the decoder's own figures, for whoever reads them next: its
bench has no "reconstructed" verdict, so a game it gets right through a
rewrite is `exact`, where the tracker's is `rec ok` or `guess ok`. Its
25 → 40 "exact" on this suite compares with the tracker's 54 games right,
not 25.

### Which line, when there are several

Across kinds first (`reconstruct/4`, `usable/3`):

- **Fewest changes to the game.** A new move is one, a move rewritten is
  one: one rewritten and one added beats four made up. Equal, the line
  that changes no history.
- **Not more moves than the clock was pressed for** (`fits?/2`). A line
  that would put the game further ahead of the clock than it has ever been
  (`debt`: the players' own forgotten presses, measured when a press
  arrives and when a move is accepted) by more than two - the press of
  the move on the board, which a clock tells a second late, and one lost
  with its move - is the box making up moves. It is not taken at all:
  the alarm, and "the board is right" for the arbiter who wants it
  anyway. A board that was not heard for a while (`Tracker.deaf/1`: the
  cable was out) is not measured against a clock that was not heard
  either, and a clock switched off says nothing.
- **No piece going out and straight back.** Not ranked: not a line (see
  "No phantoms").

Then, among lines of one kind, `rank/3`, in this order:

1. **The clock.** More presses than moves means the board has run further
   ahead than the shortest line says (one press of slack: the lever that
   starts the clock is a press, and "Move missing?" waits for two as well).
   Longer lines are then looked for and go first. A press tells late, never
   early, so fewer presses than moves prove nothing - which is why only the
   count is used and not "whose clock runs": at the moment a move has just
   landed, the clock still shows the side that made it. The count itself
   reads the times as well as the lever (see "Presses the clock hides").
2. **The order of the readings.** Each move of a line is first shown by
   some reading (both its squares as the move leaves them); a move first
   shown before the move the line plays ahead of it is out of order. Moves
   played one by one in front of the board score 0 in the order they were
   played, and the same moves in another order score more. This is what
   picks `Nc6 Be3 e6 Qc1 Bb4 Ne5` out of nine legal orders of those six
   moves. Moves nobody read are all first shown by the same reading, and
   their order stays a guess.
3. The line that assumes least about a promotion; a queen before any
   other piece nobody saw.
4. The moves' names, so the same board always gives the same game.

### Presses the clock hides

The clock is counted by the side that runs: a press is the running side
changing. Two presses between two readings leave the same side running,
and that count misses both - which is exactly what a stretch of missed
plies does to it. Three plies by nobody seen (White, Black, White) count
as one press; four, as none. The tracker then held the line it found
against a clock that "said" one or no move had been made, decided the box
was making moves up (`fits?/2`), and raised the alarm.

The times say what the lever does not (`Alnasl.Clock.hidden_presses/2`).
A side whose clock is not running holds its time to the millisecond, so
when the same side runs in two readings and the other side's time has
moved, the other side ran in between: two presses. And a side that comes
back running with more time than it had when it stopped was paid an
increment, which only a press earns: one change of side was then three.
Both are floors - four presses look like two - which is all the count
needs, since it only ever asks whether a line has too many moves. A clock
that stood still in between breaks the chain (time corrections are made
with the clock stopped), and an hourglass clock, on which the waiting side
gains what the running side loses, is recognised at its first such reading
and its times are not used for presses after it. In the 15,000 readings of
the real board's clock from 2026-10-11/12 the waiting side's time never
moved, so nothing in those games changes.

Presses found this way are presses for everything else too: the board is
looked at again on them as on a press the lever showed (`Session`). They
used only to be counted, so a board that needed a press to be believed -
a knocked pawn put back while the next moves were already being made -
waited for the next reading, which in a scramble is the next move.

A press with nothing changed on the board since the last press - the lever
knocked back and pressed again, a hand on the wrong side - is counted but
kept apart (`idle`): `pressed_for/3` does not look for a longer line on its
account. Except while the board is not heard: then nothing changing says
nothing, and every press is a move. Without this, the bench's "lever
knocked back" fault at bullet speed turned 25 of 69 games into longer,
wrong, red lines.

The other way round: once the clock has counted more moves than the game
holds - two more, since the press for the move on the board may come in
before that move is taken - the board is not going backwards
(`pressed_past?/1`). A position that came round again is then not a
takeback, the last move is not revised into another, and a board that is
"in hand" over an earlier position is not waited on as a takeback in the
making. All three used to turn a repetition played while the readings
were missed into a takeback of moves that were never taken back, without
a mark. Now such a game goes on, and the presses it is short of raise
"Move missing?". Not while the board is not heard: a deaf board's presses
are its moves, but its count says nothing about direction.

Measured with `mix alnasl.bench --passes 3`, the same seeds before and
after. Every suite not shown is identical in every column; "missed" is the
one where the clock goes quiet with the board.

| suite | | exact | rec ok | rec WRONG | guess ok | guess WRONG | flagged | alarm | wrong marked plies | alarms |
|---|---|---|---|---|---|---|---|---|---|---|
| missed 25%, up to 3 plies in a row | before | 0 | 37 | 2 | 41 | 18 | 0 | 109 | 31/2827 + 51/552 | 1845 |
| | after | 0 | 43 | 7 | 66 | 80 | 1 | 10 | 153/4367 + 323/1324 | 310 |

What it buys: 99 of the 109 games that stopped now keep up, 31 of them
right, and the stream of alarms drops from 1845 to 310. What it costs is
the other 68: they go on as a game that was not played, marked. Three or
more unseen plies are where reading positions stops being enough (see
"What the search cannot see") - the order of two moves of one side around
a move of the other, a king that went b1-c2 or b2-c2 - and the box used to
refuse to guess there only because the clock had been misread as saying
nothing happened. The orange ones are the price that is not marked
honestly: 5 more games end on a reconstructed move that is wrong (the
shortest explanation again, now allowed past the clock), 153 orange plies
wrong in 4,367 against 31 in 2,827. That is the next thing to look at.

**What the press times cannot do: order moves nobody saw.** The hope was
that the moment of each press would say which of `1.d4 Nf6 2.c4` and
`1.c4 Nf6 2.d4` happened. It cannot. A press reports late, never early, so
all it proves is that by the time it arrived *some* move of that side was
on the board - never which. Where readings were made between the moves,
the readings themselves already order them (rule 2 above), more sharply
than a press a second late could; where no reading was made, no press
says anything about which piece moved first. The only thing the clock
adds is how many moves were made, and that is what this section is about.
A check of every line's moves against the arrival time of its presses
was considered and not built, for want of a single case it would decide
that the order of the readings does not.

### What it does not believe

- **A hand.** A board with only a piece or two missing is not searched:
  the only legal explanation is a capture by a piece that then went home.
  (After `lifted_ms`, before the alarm, the guided search is asked once.)
  One exception, as before: two pieces gone, one of each colour, neither
  able to take the other - an unseen capture and recapture.
- **A hand beside an unseen move.** A queen lifted off d3 beside a rook
  that went to e3 unseen reads exactly like "the rook went to e3, the queen
  came there by way of e4 and was taken": five legal plies. So a line that
  takes a piece is not believed while the same board *with one missing
  piece put back* is explained by fewer moves or none - until the board has
  stood for `deep_settle_ms`.
- **The moves the arbiter has just taken back.** Undo remembers them for
  the position it leaves (`rejected`), and no search from there returns
  exactly them: "the board is right" after an Undo used to find the one
  line there was - the moves just undone - and put them back without a
  word. Any move accepted ends that, and so does the game going on over
  them.

### The arbiter's part

A tap on a red move, or "Check them", asks which line it was
(`AlnaslWeb.Choice`): the position before and after, and one question at a
time - the first move on which the remaining lines differ, each option on
a small board with its squares marked, the line as it stands first. Moves
every remaining line has are not asked about. The last answer leaves one
line; using it, or "Keep it as it stands" at any point, rewrites the game
from there (`Tracker.choose/4`), marks those moves as the arbiter's and
sends the game again. The alternatives are not stored: they are searched
for again from the game itself (`Tracker.alternatives/2`), so a red move
can be settled after a restart too.

### What goes out

Reconstructed and guessed moves are sent like any others. Both
destinations take the whole game every time, so a correction replaces
what they hold. The mark stays on the box: the results server's ingest
takes `moves` as a list of SAN and has no place for it (anything else in
a move is `invalid_moves`), and a PGN comment on Lichess would be shown
to every spectator as part of the game.

### What keeps it bounded

It walks pseudo-legal moves and checks legality only on branches that are
still alive. A branch dies when:

- the target has more pieces of a colour than the branch (pieces do not
  come back), or fewer than the remaining plies of the other side can take;
- a side needs more **arrivals** - squares where the target has one of its
  pieces and the branch does not - than it has plies left (two for the ply
  it castles);
- in the last two plies, where each side has one move left, that move must
  start on a square that still differs from the target.

A board with only a piece or two missing is not searched at all: the only
legal explanation is a capture by a piece that then went home, and believing
that costs more than waiting for the hand to come back. One exception: two
pieces gone, one of each colour, where the one cannot take the other. That
is not a capture half made; it is what a capture and its recapture by a
piece of the same kind leave behind when neither was seen (hxg6 hxg6: a
pawn on g6 as before, both h-pawns gone). It is searched once it has stood
for `settle_ms` - a third move on top of it would be out of reach.

Measured on a desktop, positions k plies apart in the bundled games
(a Pi is several times slower):

| plies | guided: mean / worst | blind: mean / worst |
|---|---|---|
| 2 | 0.1 ms / 1 ms | 0.05 ms / 0.3 ms |
| 4 | 0.2 ms / 0.6 ms | 20 ms / 260 ms |
| 5 | 1 ms / 4 ms | 200-370 ms / over 1 s |
| 6 | 4 ms / 23 ms | over 1 s |
| 8 | 90-145 ms / 0.7-2 s | - |
| 10 | over the budget, 4 times in 10 | - |

Hence 8 and 4. A search is cut off at `max_nodes` (4 000) or `max_ms`
(500 - the worst single search in the fault matrix, with every core
busy), gives up and says so; the same question is not asked twice of the same board. The
arbiter's "the board is right" searches 6 plies blind with a hundred
times the nodes and ten times the time, because somebody asked and is
waiting.

### What the search cannot see

Reading a game from positions has a hard limit, and it is better stated than
discovered.

**Two unseen plies are safe.** If White and Black each made one move unseen,
every pair that gives this board is found; if there is one, it is the truth;
if there are several, one is taken and marked as a guess. The classic: a pawn that
advanced one square or two and was then captured (plainly, or en passant)
leaves the same board. So does a pawn promoting and being taken at once -
to what did it promote? Over 207 games with 10% of plies unseen, this
happened in 3-6.

**Three or more unseen plies are not.** Two things go wrong:

- *Order.* Unseen `1.d4 Nf6 2.c4` and `1.c4 Nf6 2.d4` are the same board.
  One is taken, marked as a guess, and it is the wrong one about as often
  as not: nothing was read that could say. (When the moves *were* read
  one by one, the readings say - see "Which line".)
- *The shortest explanation is not the true one.* A rook that went a1-b1,
  then b1-c1 with a black move between, reads as Ra1-c1 and one black move:
  two plies explain what three made. The tracker accepts the two, marked
  reconstructed - orange, and wrong. It is then one ply out in whose turn
  it is, and the next move usually exposes it; the clock's press count
  catches it when the presses were heard, and nothing does when the cable
  was out. This is the one way an orange move is wrong: 3 games in 207
  with the board unplugged for three plies, 6 in 207 with a quarter of all
  plies unseen.
  The same goes for a position repeated during the gap, which reads as a
  takeback.

The same reasoning is why an **illegal move** is not always an alarm: a
piece set down on a square it could have reached in two legal hops, with
the opponent's knight imagined out and back, *is* explained by four legal
moves. In the fault matrix, of 207 games with an illegal move at ply 12
and played on, 185 end in the alarm and 22 as a game that was not played,
its moves marked from the illegal one on (21 red, 1 orange). None
unmarked.

## 3a. Fast play

Blitz, bullet, and the last minute of any game. What changes is not the
chess but the timing, and three things in the tracker exist because of it:

- **Nothing stands still.** A move is on the board for a few hundred
  milliseconds before the next hand arrives. Rule 6 takes that hand as
  the notice the move is made; without it, a move that never stood for
  `settle_ms` was only ever found afterwards by the search, two at a time,
  flagged *recovered* - or not at all.
- **The clock is late.** A clock reports about once a second (the real
  board's recording: gaps of 0.9-1.3 s), so a press reaches the box up to
  a second after the lever went down - often with the next piece already
  on its square. A press therefore confirms the move on the board only
  when it is that move's own press.
- **`settle_ms` is 250**, not the 400 it was: long enough for a piece that
  touches down on its way (the real board's knight rested 224 ms on d4),
  short enough for a time scramble.

`Alnasl.Tracker.preset(:bullet)` - "Bullet / fast play" on the Setup page -
sets `settle_ms` to 150 and switches takebacks off (at that speed a board
that reads as it did two plies ago is a piece going to and fro). It
applies at once, also to games under way, as does every change of the
tracker's settings.

`Alnasl.Simulator.Script.profile(:bullet)` is the test for it: a minute
each and no increment, a move every 0.3-2 s, 30% of moves slammed (seen in
one reading, never in the air, captures never in two steps), pieces knocked
over and set back on the opponent's time, 6% of plies not seen at all, the
clock's reading 0.1-0.9 s late and 10% of presses never reported. Over 690
such games (69 games, ten passes): with the preset 680 whole, 6 stopped on
a true ambiguity, 3 in an alarm, 1 wrong and flagged, **0 silent**; with
the defaults 656 whole, 25 in an alarm, 2 flagged and 1 wrong without a
flag at the place (four plies that read as one legal capture; the alarm
came two moves later). At bullet speed with no faults at all, 690 of 690
whole with either.

What a simulator cannot say is how a real board's scan behaves under a
slammed piece. Every real board is recorded, always, bytes and all
(`<data>/captures/board-<id>/`), so that the answer can be replayed:
`mix alnasl.replay <file> --timeline`.

A chess clock helps, and is used: a press confirms a move at once, and
**presses are counted against moves** - two presses more than moves seen
raises "Move missing?" on the tile long before the position betrays it.

The clock's **sides are fixed**. It stands to the right of the board,
White's display toward White: the cable reaches nowhere else, and the board
maker's own software assumes the same. So the box never guesses which side is whose and
offers nothing to swap them with. That makes a clock the wrong way round a
fact that can be stated instead of a setting that can be wrong:

- before the first move, a clock that stands still with its lever up on
  Black's side - or runs there - fails the **starting-position check**,
  beside the pieces;
- Black's time **started** over a starting position is an alarm of its own
  ("Clock wrong way"): not out of sync, the moves go on being followed. It
  clears by itself when the clock is put right, and after moves have been
  made at the first press that leaves the side to move running.

`Alnasl.Clock` and `Alnasl.Session` have the exact rules;
`docs/real-board-2026-10-12.md` has the bits they rest on.

## 4. The outbox

`Alnasl.Outbox`. The guarantee: **a move the site shows is a move that is
saved, and a move that is saved is a move that is queued.**

1. The game is updated in SQLite (WAL, `synchronous = FULL`: the commit is
   on the disk before it counts).
2. A row is added to the `outbox` table, numbered per game, in the same
   breath. Its body is the request the server will get.
3. A sender takes the oldest pending row, posts it, and marks it when the
   server has answered. Never a newer row before an older one.

Each body is **the whole game so far** - the server's rule
(`docs/live-boards-api.md` in OpenResults). The server decides by ply count:
fewer than it holds is ignored, equal refreshes the clocks, more must extend
what it holds. So a row sent twice (the box died between the answer and the
note of it) changes nothing, and a late row cannot undo a newer one.

A **correction** - a takeback, a replaced move, anything the arbiter did -
is sent with `replace: true`: this is the game now, whatever you hold.

| The server says | The outbox |
|---|---|
| 200 | marks the row sent |
| 409 `moves_conflict` | the server holds other moves for this board. The board is the authority: the row is set aside and the game queued again in full, `replace: true` |
| 422 | this message is wrong and stays wrong: set aside, shown to the arbiter, the queue moves on |
| 401, 403, 404 | the key or the tournament is wrong. Nothing a retry fixes and no reason to throw moves away: the queue **waits**, says why in words, tries again every 30 s and when Setup changes |
| 429, 5xx, nothing | the same row again, after a pause that doubles up to a minute (`Retry-After` is obeyed) |

One economy: a pending row is skipped when the next pending row of the same
game has the same number of plies (a clock refresh a newer one makes
pointless). A row that adds a ply is never skipped, so the server hears
every move with the clock that belonged to it.

What the arbiter sees is what is true: connected or not, the last success,
how many rows wait (counted from the table, not remembered), the last error
as a sentence.

### More than one destination

`Alnasl.Destination` is a behaviour: `configured?/0`, `pending_count/0`,
`deliver/0`, the settings that should wake it, how long to gather before
sending. Each destination has a sender of its own
(`Alnasl.Destination.Sender`, the process that used to be the outbox's):
its own pause that doubles up to a minute, its own thirty seconds when a
credential is refused, its own last success and last error. One task at a
time per destination, so a destination is never sent to twice at once.

What "its place in the queue" is, depends on what the destination takes:

| Destination | It takes | So its place is |
|---|---|---|
| `OpenResults` | every change, as a message of its own | the `outbox` row it has got to - section 4 above, per tournament |
| `LichessBroadcast` | the game as it is now, as PGN | per game, `games.seq` at the last push Lichess answered for (`destination_cursors.acked_seq`) |
| `OpenPairings` | the game as it is now, as the board link's report | the same, for the last report the pairing program answered for |

A game goes to the places of **its own tournament**. An outbox row carries
its tournament and is posted to that tournament's results page with that
tournament's relay key; each tournament's rows are sent oldest first, and a
tournament whose key is refused, or which has no results page, holds up
nobody else's. A Lichess push carries the games of one tournament's round
to that tournament's Lichess round. What the sender says when several
tournaments are in play is the worst of how they went, with the
tournament's name in front.

`games.seq` goes up by one for every change queued, in the same transaction
as the outbox row. So "the game is ahead of what this destination has
acknowledged" is a fact in the database before anything is sent, for every
destination at once - and it stays a fact through a restart, an outage, or
the destination being switched off for an afternoon.

For Lichess the order within a game cannot go wrong, because nothing old is
ever sent: the PGN is made at the moment of sending, and the count that is
acknowledged is the one read just before. A move that arrives while the
request is out leaves the game ahead again, and it goes with the next push.

A push carries every changed game of the round. The sender waits two
seconds after being woken before it sends, so a recovery of four moves, or
six boards moving in the same second, is one request; and a change that
leaves the PGN as it was (the clock refresh between moves) is recognised by
a hash of what was last sent and not sent at all. A correction is not a
special case: the PGN says something else from some move on.

`Alnasl.Destination.LichessApi` holds every address, header and expected
answer of Lichess's API, with what is documented and what is assumed.

Pull mode needs nothing here: OpenResults serves a round as one PGN
(`/t/:slug/live/:round/pgn`) and Lichess can follow that address.

## 5. The capture format

`Alnasl.Recorder`. Everything every driver delivers, as delivered, one JSON
object a line:

```
{"t":1791700000123,"k":"cfg","driver":"dgt_serial","port":"/dev/ttyUSB0","flipped":false,"round":4,"board":7,"start_fen":null}
{"t":1791700000456,"k":"pos","b":"rnbqkbnrpppppppp................................PPPPPPPPRNBQKBNR"}
{"t":1791700003210,"k":"clk","w":5400000,"b":5400000,"r":"white"}
{"t":1791700003300,"k":"rx","h":"8e00053400"}
{"t":1791700003301,"k":"tx","h":"42"}
{"t":1791700009000,"k":"st","v":"disconnected"}
{"t":1791700012000,"k":"note","text":"knocked over on purpose"}
```

| `k` | |
|---|---|
| `cfg` | how the board was set up when the lines after it were written: driver, port, whether it is turned round, the game it was linked to, a starting position |
| `pos` | the board as the driver reported it - **before** the box turns a turned board - 64 characters a8..h1, FEN letters, `.` for empty |
| `clk` | a clock reading: milliseconds, `white`, `black` or `none` running (or `off`: the clock was switched off), and the side its lever is set for when the driver can tell |
| `rx`, `tx` | raw serial bytes, hex (real boards only) |
| `st` | `connected` / `disconnected` |
| `note` | something a person typed |
| `a` (on any line) | the address of the board on its loop, in a capture made by `mix alnasl.loop --watch` |

`t` is wall-clock milliseconds. Files are
`<data>/captures/board-<id>/<start>.jsonl`, closed at 8 MB; when all
captures together pass the cap from Setup, the oldest go.

A capture is read back as the timed events a driver delivers, which is what
the `Replay` driver plays, what "Replay through the tracker" on the
Recordings page judges, and what `mix alnasl.replay` prints. A file with
`rx` lines and no `pos` lines - or a log from `tools/serial_proxy.py` - is
decoded with the board protocol on the way in, so a recording of a real
board made *before* the driver is right can test the driver once it is.

`test/fixtures/captures/opera-with-hands.jsonl` is one, checked in: a game
with lifts, knocks, swaps, slides and seven takebacks, and a test that it
still comes out whole.

## 6. The round

- A game is `(tournament, round, board, game number)`. A box serves several
  tournaments (section 6a); a box that serves one has "its own", and the
  addresses and files it always had.
- The pairings come from the pairing program (section 6a) and are kept on
  the box, so it knows them offline. For the box's own tournament they
  come from the arbiter: names said on a board's page, or a PGN. The box
  does not read them from the results server any more - that link is one
  way.
- A physical board has an **identity**: the serial number it reports. The
  row of the `boards` table is that board, wherever it is plugged in
  (`Alnasl.Tables`). A board added on a port that then reports a serial the
  box knows - on a row with a number, not connected just now - is the same
  board elsewhere: the known row takes the port, the new row goes. Two
  connected boards with one serial are not merged; they are reported.
- A row that has a serial **keeps it**. When the board on its port reports
  another one, the board's process does not rename the row; it tells
  `Alnasl.Finder`, and `Tables.recognise/4` moves rows to where their boards
  are: two known boards exchange ports (a whole hall does, when the ports
  enumerate in another order after a restart); an unknown board on a known
  row's port gets a row of its own, unless a game is under way there - a
  serial misread on a noisy line must not take a board out of a round.
- A board has a **table number** (`table_no`): the sticker. It is set once
  and belongs to the identity.
- The arbiter **links** a physical board to "board N of round R"
  (`round`, `board_no`). The game is `(R, N)`, whichever physical board
  feeds it. Setting a table number links the board to the board of that
  number; linking it elsewhere afterwards is a remap for the round.
- **Touching is identifying.** A board reports the whole position whenever
  a piece is lifted, so the board that just reported a change is the board
  somebody just touched. `Alnasl.Finder` remembers each board's last touch
  and announces it; the numbering run ("the next board touched is table
  N") lives in that process, on the box, so that any browser - a phone that
  lost its connection, the kiosk screen - sees the same run.
- A board linked to a game another board had **takes it over**: a board
  carried to another table, a broken one swapped for a spare. The game goes
  on from the moves it has.
- A board **turned round** is noticed by itself while no move has been made
  (the starting position reads upside down) and read the other way up; it
  can also be turned by hand.
- The **start-position check** compares what the board reads with where the
  game starts and says what is wrong in pieces and squares - and, when a
  clock is attached, whether it is set so that the side to move runs first.
- A **late** board is caught up by the search if it is a few moves in, by
  the arbiter if not.
- A game from a **set position** (resumed, adjourned) gets a FEN before its
  first move; the server is told `start_fen`.
- The **next round** moves every linked board to the board of its table
  number in that round (a board without a table number keeps the board
  number it had): a remap is for a round. The games of the round before
  stay as they are.
- **More than one game on a board.** The game of a board is
  `(R, N, game_no)`, and the highest number is the one being played. A
  new one begins when the arbiter says "New game on this board" (the game
  there is closed without a result if it had none), or by itself when the
  starting position is back on the board over a game that is finished or
  more than two moves old - two moves in, the same board is a takeback.
  By itself only where Setup allows: by default on a board no pairing
  names, because friends playing game after game want it and a paired
  round has one game a board (a board set up early for the next round is
  not a second game of this one). The new game gets a fresh tracker, a
  line in the recording (`cfg` with `game`), its own PGN file, and reads
  nothing until the starting position has stood on the board: the pieces
  of the game before are not its first moves.
- **One game of a board leaves the box.** The results server knows a
  game by round and board (`round` + `board` in the ingest, nothing else),
  Lichess by its headers, and the pairing program by the pairing (one
  report per `game`, whole, replacing the last: the contract has no room
  for a second game of the same pairing). A second game sent to any of
  them would overwrite the first. So a game begun with "New game on this
  board" is marked `local` and `Outbox.enqueue/3`, the Lichess push and
  the report to the pairing program skip it: such games are on the board's
  page with their PGN, in the round's PGN, and in the recordings. (The
  mark is a column and not "game number above 1" because of the one case
  where the later game is the one that counts: a game set aside when its
  pairing changed, section 6a.)
- **Starting a round** is `Alnasl.Boards.start_round/2` - that
  tournament's boards moved to the round, each to the board its table
  stands for - so that something other than the Round page can ask for it.
  The pairing program does (section 6a).
- **Ready or not** (`Alnasl.Tables.checks/1`): duplicate table numbers,
  two boards on one board of the round, one serial seen twice, a numbered
  board that does not answer, a wrong starting position, a connected board
  without a number, a gap below the highest electronic board.

## 6a. Several tournaments, and the pairing program

`docs/board-link-api.md` in OpenPairings is the contract; `Alnasl.OpenPairings`
is the box's half of it. The decisions that are the box's own:

**Tournaments are rows.** One is always there - the box's own, for a box
without a pairing program and for a board nobody gave to another - and each
tournament a connect code reaches is another. A row holds what used to be
five settings (results page, slug, relay key, Lichess round, round in
play) and the document the pairing program last gave. The migration makes
the box's own tournament out of the old settings, and the old snapshot
into its document: a box upgraded mid-weekend carries on with the names it
had.

**The code is a secret and is treated like the relay key.** It is stored
as given (it must be sent with every request; the pairing program keeps
only a hash and cannot show it again), never logged, never put back in the
form, and shown as a hint. What is before the `#` is used as written:
`http://127.0.0.1:<port>` is a desktop copy on the same computer and
needs no internet and no certificate.

**The box polls; nothing is pushed.** `GET /link` with the `ETag` of the
last answer, at the pace the pairing program asks for (5 s). A `304` is
the usual answer and costs nothing. A listing that changed names the
versions; a tournament whose version the box does not hold is fetched. No
answer: the pause doubles to a minute and the boards go on with what the
box has. `401`: the box stops asking - a withdrawn code asked for every
five seconds from the hall's address gets the address throttled - and
says so; trying again is the arbiter's button.

**Tables are the box's.** The pairing program knows boards of a round;
the box knows tables. A tournament is given a range of tables, and the
board a table stands for is its number counted from the range's first:
tables 5-8, table 5 is board 1 (`Alnasl.Tables.home_board/2`). So the
arbiter numbers the hall once, 1 to N, and says where each tournament
begins.

**A paired round is on.** The pairing program has no "start": it says
which round is current. When that number changes the box starts that
round for that tournament's boards (`Alnasl.OpenPairings.Sync`), and for
no others - the other tournaments' boards are other rows with another
`tournament_id`, and `start_round/2` does not look at them. The arbiter
can switch that off per tournament, or look at another round by hand; the
box does not pull him back, it follows when the number moves again. And
the box does not walk its boards *back* by itself while a game of the round
on them is being played: in a round robin "current" is the first round
with a result missing, so a result of round 2 cleared to be corrected
during round 3 makes the number say 2 for a minute (a Swiss says the round
paired last, whatever is open before it; an OpenPairings older than that
rule said 2 there as well). The Round page then says where the
pairing program is, with the button; the boards stay with their games.

**A pairing that changes under a game.** The cases the contract lists
look alike in the document and are not alike in the hall, so the box
decides only the ones that are safe:

| | the box |
|---|---|
| nothing played on the board | takes the new pairing, silently |
| the same game, another board number | moves the game and the physical board with it; the board that waited there takes the number left behind |
| moves played, and other players, other colours, or no such game | keeps the game untouched, flags it, stops reporting it to the pairing program, and asks |

The arbiter's two answers: *these moves are that game* (a colour switch
entered because the players sat down wrong, a corrected name: the moves
stand, the names change, every destination is told again in full), or
*set it aside, begin again* (the round was paired again while this board
had begun: the old game is kept on the box, closed without a result, and a
new game on the board is the one that leaves the box). Until he answers,
the results site and Lichess go on getting the moves under the names the
game had - a live board that goes dark is worse than one with yesterday's
name on it. The flag clears by itself when the pairing is put back.

**What goes back.** Per game, whole, with a `seq` that only grows
(`game row * 2^32 + its change counter`: a game begun again for the same
pairing outranks the one set aside). The result is the one *the board
saw*: the arbiter's on the box when the game is closed, else what the
position shows. It is never entered there. A `stale` answer - another box
reported the game, or this one was wiped - is listed, and overruled
(`replace: true`) only when the arbiter says so. The twenty-second clock
refresh is not sent: the contract asks for reports on a move, a state
change or a clock correction, and the pairing program shows no running
clock.

**One tournament, one row, however many codes.** Two codes can reach one
tournament: a group's and the tournament's own, a desktop copy's code for
this computer and the one for the hall's network. Two rows meant two
reports of every game, two sets of tiles and two places a board could be
put. The contract gives no identity but the address and the id there
(`Alnasl.OpenPairings.Duplicates`), so the box takes the same tournament to
be

| | |
|---|---|
| the same address (scheme, host, port; `localhost` is `127.0.0.1`) and the same id | at listing time |
| the same id, the other row still listed, and the listing's version the one that row holds | at listing time: the version hashes the whole document |
| the same id and a game id in common | when the document arrives: game ids are random and live as long as the pairing |

A second code that reaches a tournament the box has makes no row: the
link writes it down (`links.elsewhere`) and Setup says "This code reaches
X, which this box already has through Y". The first row stays, because
the boards and games are on it. "Use this code" moves the row to the new
link - the same row, so nothing is carried and nothing lost - and the old
link goes when it reaches nothing else; the usual reason is a code
withdrawn and made again. A row the old code stops listing while another
code the box has lists it moves to that code by itself instead of being
marked gone. Rows that exist already (a box from before the rule) are
merged at start-up, before the first poll: the later into the first;
boards, games and the outbox move; a game whose place the first row has
filled with a game that began becomes the next game on that board and
stays on the box, because two games cannot both be the one of a pairing;
an empty game whose place is taken is dropped. The log says what moved.

**A team event.** The document gives each board its match (`number`,
`board` within it, `team_a`, `team_b`) and each player a team; boards keep
their number through the round (`(match - 1) * boards per match + board`
in OpenPairings), and that number stays the key everywhere: the results
site keys a live game by round and that board, so its ingest needs no
notion of a match (it draws matches from its own published snapshot), and
the pairing program keys a report by game id. What changes is what the
arbiter reads and the PGN:

- the Round page groups the tiles by match in board order, names each
  player's team, and adds the match's score *as the boards saw it* - games
  the box saw finish with a result, labelled as such, because the score
  that counts is the arbiter's;
- with `keep_matches` (on by default) a tournament's tables are counted
  match by match: table k is board `((k-1) mod n) + 1` of match
  `div(k-1, n) + 1`, looked up in the round, so a match sits side by side
  even if a round were numbered otherwise. With OpenPairings' numbering it
  gives the same numbers as the plain count; it is the box not depending
  on that. A place no pairing names stands for the number it would have;
- "Ready for round N?" names a missing board by its match and says when
  only part of a match is on electronic boards;
- the PGN (the box's own, the one OpenPairings stores beside a report,
  Lichess's) carries `WhiteTeam`/`BlackTeam` and `Round` as `3.6`. That
  `Round` is what OpenPairings' and OpenResults' PGN exports write for a
  game with moves; neither of them writes team tags, Lichess builds its
  team table from them.

## 7. The processes

```
Alnasl.Supervisor
├─ Repo, PubSub
├─ Recorder                    one writer for all capture files
├─ BoardSupervisor
│   └─ BoardServer (per board) driver + session + persistence; ticks every 100 ms
│       └─ its driver          Simulator / Replay player, DgtSerial, or an attachment to...
├─ BusSupervisor
│   └─ DgtBus (per port)       a loop: one question at a time, to each board in turn; gone when its last board is
├─ Finder                      who was touched last; the numbering run
├─ Outbox                      the results server's sender; each batch runs in a task so it can always answer
├─ LichessBroadcast.Sender     the same process, for Lichess
├─ OpenPairings.Sender         the same process, for the pairing program
├─ OpenPairings.Poller         asks each connect code what it reaches, at its pace
└─ Endpoint                    the management site
```

A board process that crashes is restarted and picks its game up from the
database; a driver that dies is restarted by its board after three seconds;
neither can take the outbox or another board with it. A bus that dies takes
the drivers of its boards with it, and the first of them to come back
starts it again.

## 8. A loop

Several electronic boards on one serial line. `docs/real-loop-2026-10-12.md` is
what a real one sent; this is what the box does with it.

**Who is on a line** (`Arkab.Dgt.Loop`) is asked whenever a port is opened
by somebody who does not know: when a port is added, and each time the
single-board driver opens one. The bus-mode byte, then a ping to
everybody; each board answers with its address after a wait of its own
choosing, is told to sit out the next ping, and the ping is repeated until
two rounds bring nobody new. One board or none: the port is a single
board's, and that driver goes on as it always did. Two or more: a loop.

**Why the single-board driver asks first.** A single-board command on a
loop is answered by every board at once. What arrives is no answer, now
and then looks like one, and on the day it was tried one such command in
the wrong moment made a board restart itself. So on a line where more than
one board answered the ping, nothing else is sent: the row says "it is a
loop", holds no port, and looks again every ten seconds.

**Rows** (`Alnasl.Loops`). The arbiter never sees a bus address as
something to fill in. Each board that answers gets a row with the address
it answered with; which row is decided in this order: the row that has
that address on that port; a row with that address on another port, not
connected (the loop moved to another adapter); a row that learned the
address when its board was alone on a port; a new row. A board with
firmware 1.x then reports its serial number - its address is its serial
number - and the usual recognition (`Alnasl.Tables.recognise/4`) hands the
place to the row the box already has for that serial. A newer board's
address says nothing of its serial number, so its identity on a loop is
`{:address, n}` ("no. 12799 on the loop") until a row knows both.

**The questions** (`Arkab.Driver.DgtBus`), one at a time, no pause
between an answer and the next question:

| Question | When | Costs |
|---|---|---|
| what changed? | every turn | 16 ms when nothing did |
| your whole board | every 3 s (0.5 s per board on a loop of more than six), and after every missed answer | 80 ms |
| your clock | every second (0.25 s per board on a loop of more than four), and at once when the board wrote down a lever | 31 ms |
| sit out the next ping + a ping to everybody | every 10 s | 16 ms a board; nobody is waited for |

A board met for the first time, or back, is asked what changed (its whole
memory since it was switched on: thrown away), its version, its whole
board. A board that misses five answers in a row is reported gone and
asked every two seconds, so that the others do not wait for it.

The whole board is asked for although the changes should suffice, because
the changes were not seen live on a real loop and a dump cannot be misread:
where the two disagree the dump wins.

**A board nobody told the box about** answers the ten-second ping - the
others were told to sit it out - and gets a row. Its answer may fall on
another board's and spoil one poll; the next thing that board is asked is
its whole board.

**The capture** of a board on a loop holds the questions that had
something for an answer. Sixty times "nothing changed" a second are not
written down.

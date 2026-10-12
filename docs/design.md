# How Alnasl works

Five parts, in the order a move passes through them: a **driver** reads a
board, the **recorder** writes down what it read, the **tracker** works out
the moves, the **outbox** gets them to the server (and the other
**destinations** get them elsewhere), and the **round model** says which
board is which game. This document is about the reasoning; the
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
not changes. A DGT board in update mode sends single-square changes; the
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
  piece rewrites the promotion and replays the moves after it.
- **A repeated position is not a takeback** when legal moves explain it. A
  queen checking from f1 and f2 in turn returns the board to where it was
  two plies ago; rule 5 is asked before rule 3 for takebacks of more than
  one ply.
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
  exchange that went by unseen, which the search has). Never a king. No
  limit in plies: a warning that stays is honest, an alarm after N moves
  would be arbitrary.

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
2. **Blind** - every legal move - for what nobody read anything of: a
   cable out, a ply that fell between two scans. Two plies at once; up to
   `blind_depth` (4) once the board has stood for `deep_settle_ms` (5 s).
   What the guided search finds is checked against this one wherever it
   reaches: a pawn that went two squares and was taken in passing while
   nobody read the board never stood on its square, and only the blind
   search knows there were two ways.
3. **With the absent piece taken to be unseen** (§2), two plies. Guessed.
4. **From before the last reconstructed moves**, when the board has stood
   unexplained for `transient_ms` and the alarm is next: those moves
   explained the board then, and do not explain this one, so the question
   is asked again from before them. The game is corrected, not extended.

Before the first move, a board that is not the starting position is
pieces being set up, and is not read as an opening: two plies (a board
plugged in late), no more, until the clock has been pressed or the arbiter
says "the board is right".

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
- **No piece going out and straight back** (`null_trip?/1`): one side
  moving a piece from A to B and, with its next move, back to A, taking
  nothing. Never taken while another line exists; alone, only when the
  clock says the moves were made; without a clock, not at all.

Then, among lines of one kind, `rank/3`, in this order:

1. **The clock.** More presses than moves means the board has run further
   ahead than the shortest line says (one press of slack: the lever that
   starts the clock is a press, and "Move missing?" waits for two as well).
   Longer lines are then looked for and go first. A press tells late, never
   early, so fewer presses than moves prove nothing - which is why only the
   count is used and not "whose clock runs": at the moment a move has just
   landed, the clock still shows the side that made it.
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
- **The clock is late.** A DGT clock reports about once a second (the real
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
White's display toward White: the cable reaches nowhere else, and DGT's own
software assumes the same. So the box never guesses which side is whose and
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
| `OpenResults` | every change, as a message of its own | the `outbox` row it has got to - section 4 above, unchanged |
| `LichessBroadcast` | the game as it is now, as PGN | per game, `games.seq` at the last push Lichess answered for (`destination_cursors.acked_seq`) |

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
| `a` (on any line) | the bus address, in a capture of a loop made by `mix alnasl.dgt --bus` |

`t` is wall-clock milliseconds. Files are
`<data>/captures/board-<id>/<start>.jsonl`, closed at 8 MB; when all
captures together pass the cap from Setup, the oldest go.

A capture is read back as the timed events a driver delivers, which is what
the `Replay` driver plays, what "Replay through the tracker" on the
Recordings page judges, and what `mix alnasl.replay` prints. A file with
`rx` lines and no `pos` lines - or a log from `tools/serial_proxy.py` - is
decoded with the DGT protocol on the way in, so a recording of a real
board made *before* the driver is right can test the driver once it is.

`test/fixtures/captures/opera-with-hands.jsonl` is one, checked in: a game
with lifts, knocks, swaps, slides and seven takebacks, and a test that it
still comes out whole.

## 6. The round

- The pairings are read from the server's public snapshot and kept on the
  box, so it knows them offline.
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
- **Only game 1 of a board leaves the box.** The results server knows a
  game by round and board (`round` + `board` in the ingest, nothing else)
  and Lichess by its headers; a second game sent there would overwrite the
  first. So `Outbox.enqueue/3` and the Lichess push skip `game_no > 1`:
  those games are on the board's page with their PGN, in the round's PGN,
  and in the recordings.
- **Starting a round** is `Alnasl.Boards.start_round/1` - pairings fetched,
  boards moved - so that something other than the Round page can ask for
  it.
- **Ready or not** (`Alnasl.Tables.checks/1`): duplicate table numbers,
  two boards on one board of the round, one serial seen twice, a numbered
  board that does not answer, a wrong starting position, a connected board
  without a number, a gap below the highest electronic board.

## 7. The processes

```
Alnasl.Supervisor
├─ Repo, PubSub
├─ Recorder                    one writer for all capture files
├─ BoardSupervisor
│   └─ BoardServer (per board) driver + session + persistence; ticks every 100 ms
│       └─ its driver          Simulator / Replay player, DgtSerial, or an attachment to...
├─ BusSupervisor
│   └─ DgtBus (per port)       the polling scheduler for a loop
├─ Finder                      who was touched last; the numbering run
├─ Outbox                      the results server's sender; each batch runs in a task so it can always answer
├─ LichessBroadcast.Sender     the same process, for Lichess
└─ Endpoint                    the management site
```

A board process that crashes is restarted and picks its game up from the
database; a driver that dies is restarted by its board after three seconds;
neither can take the outbox or another board with it.

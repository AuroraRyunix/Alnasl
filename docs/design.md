# How Alnasl works

Five parts, in the order a move passes through them: a **driver** reads a
board, the **recorder** writes down what it read, the **tracker** works out
the moves, the **outbox** gets them to the server, and the **round model**
says which board is which game. This document is about the reasoning; the
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
- `raw`, the last board reported, and since when it has read like that.

For every board reported, the first of these that fits:

| # | The board is... | Then |
|---|---|---|
| 1 | the certain one | in sync |
| 2 | one legal move away | that move - once it has stood for `settle_ms` (400), or at once on a **clock press** |
| 3 | an earlier certain position (1-2 plies back) | a **takeback**: a correction, after `takeback_settle_ms` (1500) |
| 4 | one move away from the position *before* the last move | the last move is **replaced**: a rook that rested on a square on its way, a hand that let go and took hold again |
| 5 | two or more legal moves away | the **recovery search** (§3) |
| 6 | none of these | nothing. A hand, half a capture, a knocked piece. Status "Settling" |

Only when 6 persists - `transient_ms` (8 s), or `lifted_ms` (60 s) when the
board is just the certain one with a piece or two missing - does the status
become **out of sync**. The certain position is frozen, the arbiter is told,
nothing more is sent for that board, and the tracker keeps watching: the
moment a board arrives that 1-5 explain, it carries on by itself.

### The cases that need more than one rule

- **A capture in two steps**, in either order, passes through boards with a
  piece or two missing. None is a legal move's result; rule 6 holds them.
- **Castling as two piece moves.** King first: the king two squares from home
  is not a legal move by itself; rule 6, then rule 2 when the rook lands.
  Rook first is the awkward one, because the rook move *is* legal: a rook
  move that could be the first half of a legal castle is held for
  `castle_hold_ms` (2.5 s) instead of 400 ms. If the king follows later
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

### After the arbiter changes the game

Undo and "change a move" make the game disagree with the board on purpose.
The board is then left alone until it next changes - re-reading it at once
would put the undone move straight back.

## 3. The recovery search

`Alnasl.Tracker.Search`: which sequences of legal moves turn the certain
position into the board we see?

Depth-first, iterative deepening: every sequence of 2 plies, then 3, up to
`search_depth` (4). It stops at the first depth with an answer and returns
every answer of that length - **the shortest explanation wins**.

- exactly one → accepted, every ply flagged `recovered` (three or more at
  once also `long_gap`, logged as a warning, and only after the board has
  stood for `deep_settle_ms`, 5 s, or the next move confirms it);
- several → kept as **candidates**. Nothing is emitted. Each board that
  follows is tried against every candidate, and those that cannot explain
  it fall away; one left is accepted. If they are still several after
  `transient_ms`, the status is out of sync with reason *ambiguous* - and
  the candidates go on following the game, so when the arbiter picks one,
  the moves since are already there;
- none → rule 6.

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
that costs more than waiting for the hand to come back.

Measured: the worst case over 400 scrambled positions (nothing explains
them, so every depth is exhausted) is about 0.1 s and 3259 nodes at depth 4
on a desktop; a Pi is several times slower. There is a node budget
(`max_nodes`, 200 000) after which the search gives up and says so. The
arbiter's "Resync from here" searches to depth 6 with ten times the budget.

### What the search cannot see

Reading a game from positions has a hard limit, and it is better stated than
discovered.

**Two unseen plies are safe.** If White and Black each made one move unseen,
every pair that gives this board is found; if there is one, it is the truth;
if there are several, the tracker stops and asks. The classic: a pawn that
advanced one square or two and was then captured (plainly, or en passant)
leaves the same board. So does a pawn promoting and being taken at once -
to what did it promote? Over 207 games with 10% of plies unseen, this
happened in 3-6.

**Three or more unseen plies are not.** Two things go wrong:

- *Order.* Unseen `1.d4 Nf6 2.c4` and `1.c4 Nf6 2.d4` are the same board.
  The tracker stops and asks (about half of all 3-ply gaps).
- *The shortest explanation is not the true one.* A rook that went a1-b1,
  then b1-c1 with a black move between, reads as Ra1-c1 and one black move:
  two plies explain what three made. The tracker accepts the two, flagged
  `recovered`. It is then one ply out in whose turn it is, and the next
  move usually exposes it (out of sync); in constructed cases it does not.
  The same goes for a position repeated during the gap, which reads as a
  takeback.

The same reasoning is why an **illegal move** is not always an alarm: a
piece set down on a square it could have reached in two legal hops, with
the opponent's knight imagined out and back, *is* explained by four legal
moves. In the fault matrix 11 of 207 illegal moves were read that way
(flagged `recovered`); the other 196 raised the alarm. Lower `search_depth`
to 2 in Setup and this cannot happen - at the price of every 3-ply gap
becoming an alarm.

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
- The arbiter **links** a physical board to "board N of round R". The game
  is `(R, N)`, whichever physical board feeds it.
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
- The **next round** moves every linked board to the same number of that
  round. The games of the round before stay as they are.

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
├─ Outbox                      the sender; each batch runs in a task so it can always answer
└─ Endpoint                    the management site
```

A board process that crashes is restarted and picks its game up from the
database; a driver that dies is restarted by its board after three seconds;
neither can take the outbox or another board with it.

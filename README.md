# Alnasl

**Live chess boards, from the hall to the web.**

Alnasl reads electronic chess boards in the playing hall and sends every move,
with the clock times, to the live results site as it is played. It runs on a
small box beside the boards - a Raspberry Pi with a screen, keyboard and mouse
for the arbiter - and keeps working when the hall's internet does not.

> Status: **first build. Everything runs on simulated boards, and one real
> board has been read.** The tracker, the outbox and the management site are
> written and tested without hardware. The DGT serial driver met a real
> board and clock on 2026-10-12: handshake, position, piece movements and the
> clock are confirmed ([docs/real-board-2026-10-12.md](docs/real-board-2026-10-12.md));
> a whole game on it has not been played yet, and the wire format of a DGT
> *loop* is still assumed, not verified. See
> [What is not done](#what-is-not-done) and [docs/tomorrow.md](docs/tomorrow.md).

## The name

Alnasl is γ² Sagittarii, "the arrowhead" - the point of the archer's arrow.
Its sibling [Ainalrami](https://github.com/AuroraRyunix/Ainalrami), the pairing
engine, is ν¹ Sagittarii, "the eye of the archer". The eye decides who plays
whom; the arrow carries the games out of the hall.

## Where it fits

```
[DGT boards] --serial--> Alnasl (in the hall)
                            |  moves, clocks - live, buffered when offline
                            v
                       OpenResults  <-- snapshot --  OpenPairings
                     (live boards,                 (pairings: which board
                      hall screens)                  is which game)
```

- **OpenPairings** pairs the tournament and owns the results.
- **OpenResults** shows the games live. Alnasl reads the round's pairings from
  its public snapshot (`GET /api/tournaments/:slug`) and writes to its
  live-boards API (`POST /api/tournaments/:slug/live`, with a relay key).
- **Alnasl** does only the part in the hall: talk to the boards, turn what
  they report into legal moves, and get those moves to OpenResults.

Alnasl is a separate program on purpose. A board that hangs, a loose cable or
a hall without a network must never be able to touch the pairing program.

## Try it now, without any hardware

```
mix deps.get
mix alnasl.demo
```

then open **http://localhost:4040**. Eight simulated boards replay classic
games, with hands: pieces lifted and put back, captures in two steps, a
takeback now and then. One board is made to go wrong on purpose (an illegal
move, played on), so there is an "Out of sync" board to open and repair.
`mix help alnasl.demo` has the options (`--boards 12`, `--speed 30`,
`--faults rough`, `--port`).

No results server is set up in the demo: the badge at the top right says
"Not set up" and the Outbox page shows everything being kept, which is what
a hall without internet looks like.

### What you need

- Elixir 1.17 or newer with Erlang/OTP 26 or newer (written on Elixir 1.20).
- Nothing else for the demo. The first `mix alnasl.demo` downloads `esbuild`
  (the JavaScript bundler Phoenix uses) once.
- For real boards: a C compiler and `make` (the serial library is C). See
  [Serial ports](#serial-ports).

## The management site

Local, in a browser: full-screen in a kiosk browser on the box, or from the
arbiter's laptop on the hall's network. English and Dutch, and the same
five colour themes as OpenResults (paper, night, board, slate, high contrast)
plus "match device", chosen per device (rail, or Setup on a phone).

| Page | What it is for |
|---|---|
| **Round** | The screen during play. A tile per board: players, the position the box is sure of, clocks, last move, and the state as a shape and a word - Live, Waiting for start, Settling, Recovered a move, Out of sync, No signal, Clock wrong way, Finished. Before the first move a tile also says, in words, when the clock is not set for White. A tile is the way to the board's own page. Fetch the pairings, start the next round |
| **A board** | The position large, the move list, and - when board and game have parted ways - what the board reads beside what is certain. The repair tools: resync from the board (search deeper, or pick from the candidates), type moves, undo, change a move, set the result, start from a FEN, pause and resume sending, turn the board round |
| **Boards** | What is plugged in. Add a DGT board or a simulator; connect and disconnect; each board's live picture, signal quality, serial number and firmware; the start-position check, pieces and clock ("black queen and black king are swapped (d8, e8)", "Clock not in starting position: Black's side would run first - the clock is turned or the lever is the wrong way"); each board's **table number** and its board of the round; "Which board is this?"; "Ready for round N?" with the reasons when it is not (the clock among them); the address and QR code for a phone; a printable sheet of labels. See [Which board is which](#which-board-is-which) |
| **Number / Find** | Two phone-sized pages under Boards: number the boards of a hall by touching them in order (a piece lifted or put down counts, a clock lever does not), and find out which board the one in front of you is |
| **Outbox** | The connections, honestly: for the results server and for every other destination, connected or not, last success, how much is waiting and why it is not going, in words; each with its own switch and its own "Send now". What waits, what the server refused, what went out |
| **PGN** | Read PGN files or pasted moves (checked for legality). Play a game on a simulator board; attach a game that was not captured to its board, after asking; compare a scoresheet with the captured game (the first difference). Export a game or the whole round |
| **Recordings** | The raw captures per board. Replay one through the tracker as a dry run (what it makes of it, where it lost the thread); export it as a test fixture; download it |
| **Log** | What happened, in sentences, with filters: board connected, moves recovered, out of sync, repaired by the arbiter, offline, back |
| **Setup** | Results server, tournament (its short name, or paste the link), relay key (never shown again once saved), "Test connection" that really asks the server and explains failures; a Lichess broadcast round and its token, with a test of its own; the box's name, language, round; a PIN for other machines and the address they open; the tracker's timings, with "Bullet / fast play" for games of a few minutes or less |
| **Help** | The cycle on one page: before the round, during, after, and when something is wrong |

A banner on every page says so when the results server cannot be reached.

## Which board is which

Twelve boards look alike, and so do twelve cables. Alnasl keeps three things
apart, and the Boards page shows all three:

1. **Which board it is.** A DGT board reports its serial number (it is also
   on a label under the board); that is its identity. Not the USB port: pull
   the cable, use another port, restart the box, and it is still the same
   board with the same number. When a known board turns up on another port -
   you add it there - the box recognises the serial and puts it back in its
   old row, with its number, its game and its captures. A board the box has
   never seen says "New board" and asks for a number. The same holds when
   the ports come up in another order after a restart, or two cables are
   swapped at the hub: the rows change ports, not identities - table 7 stays
   the board that carries the sticker. And when a board the box does not
   know sits on a known board's cable, it gets a row of its own and the
   known board waits for its own to turn up; except mid-game, where nothing
   is touched and the mismatch is listed. (A board on a loop
   that reports no serial is known by its bus address; a simulator by its
   slot.)
2. **Its table number.** The sticker on the board: "this is table 7". Set
   once for a hall. *Labels* prints a sheet of them, with the serial under
   the number, so a sticker that has come off goes back on the right board.
3. **Its board of the round.** Normally the table number. For one round the
   arbiter can say otherwise ("table 7 plays board 3 today"), swap two, or
   put everything back; the next round starts from the table numbers again.
   On the Round page the board number is the big figure and "table 7 ·
   serial 06310" the small print.

Giving the numbers:

- **Number by touching** - press Start, lift a piece on table 1's board,
  then on table 2's, and so on. Each board gets the next number the moment
  it feels the piece go. Undo, Skip, Stop.
- **Number all in connection order** - one click.
- **By hand** - type it in the Table column.

And finding a board: **Which board is this?** lights up the row of the board
you touch; **Show me** on a row tells you the serial to look for and says
whether the board you then touch is the right one. Alnasl does not make a
board beep or blink: no DGT command for that is sent, because none was
verified.

**Ready for round N?** is one list before the round: two boards with the
same number, a board of the round without a board, a board without a number,
the same serial seen twice (the same board on two ports, two adapters on one
loop), a board that does not answer, a starting position that is wrong
(colours swapped, king and queen), a clock that is not in its starting
position ("Clock not in starting position: Black's side would run first..."
- only for a board that has a clock), a board plugged in turned round
(noticed and read the other way up - mentioned, not held against you).

### With your phone

The numbering is meant to be done walking: the two pages are built for a
phone held in one hand.

1. Start the box with `ALNASL_LISTEN=lan` and **set a PIN in Setup** -
   before the hall fills up. Without one, anybody on the hall's network who
   finds the address can renumber your boards.
2. Boards (or Setup) on the box shows "Open this site on your phone": the
   box's address as text, and as a QR code drawn on the box itself. Point
   the camera at it, give the PIN once.
3. Boards > *Number by touching* > Start. The next table number fills the
   screen. Lift a piece: the phone flashes the number and the board's
   serial, buzzes, and beeps (the beep has a switch).
4. Undo, Skip and Stop are at the bottom, under the thumb.

The run is kept on the box, not in the page. A phone that drops off the
Wi-Fi between two tables comes back to the run where it stands; the same
page on the box's own screen shows the same thing at the same moment. It
ends by itself when every board has a number, or after fifteen minutes
without a touch - so it is not still handing out numbers when the round has
started and forty hands are on the boards.

## Where the games go

The results server is one destination. There can be more, and they do not
wait for each other: each has its own queue, its own pause after a failure,
its own line on the Outbox page (connected or not, last success, how many
wait, the last error in words), its own switch and its own "Send now".

| Destination | What it gets | Its place in the queue |
|---|---|---|
| **Results server** (OpenResults) | every change as a message of its own: the whole game so far, with the clock | the row of the outbox it has got to |
| **Lichess broadcast** | the PGN of each game of one round as it stands, whenever it changed | per game, the game's change counter at the last push Lichess answered for |

### Broadcasting on Lichess

Two ways. They can run side by side.

**Push - the box sends to Lichess.**

1. On Lichess, make a broadcast (lichess.org/broadcast/new) and a round in
   it. Leave the round's source empty: the games are pushed.
2. Make a personal access token (lichess.org/account/oauth/token) with the
   permission to create and update studies and broadcasts (`study:write`).
   It must belong to the broadcast's owner or a contributor.
3. On the box: Setup > *Lichess broadcast*. Paste the link to the round (or
   its id), the token, the round of the tournament it stands for; tick
   "Send the games"; Save. *Test* asks Lichess who the token belongs to,
   whether it may write studies and whether the round is there - and says in
   words what is not right. It sends no game.
4. From then on every move, correction and result goes to Lichess as the
   game's whole PGN: White, Black, titles, ratings and FIDE ids as the
   pairing program knows them, Round, Board, Result, and the clock after
   each move as `{[%clk h:mm:ss]}`. A burst of moves is one request (at most
   one every two seconds, with every changed game of the round in it); a
   `429` is obeyed for as long as Lichess asks. Offline, the games wait and
   go out as they stand when the line is back.

The token is stored on the box as given (it has to be sent) and is never
shown again in full. A new round on Lichess has a new id: change it in
Setup when the round changes.

What of this is documented by Lichess and what is assumed is listed at the
top of `lib/alnasl/destination/lichess_api.ex`. It has been run against a
stand-in for Lichess, not yet against lichess.org.

**Pull - Lichess fetches from the results site.** OpenResults serves a whole
round as one PGN:

    https://<results site>/t/<tournament>/live/<round>/pgn

Give that address to the Lichess round as its source and Lichess reads it
every few seconds. Alnasl needs nothing for this - no token, no setting; it
only has to reach the results site as it always does. Spectators on Lichess
see what the results site shows, its broadcast delay included. The same
address works for any tool that follows a PGN on the web.

## Running it

### On a PC (development)

```
mix deps.get
mix phx.server        # http://localhost:4040, data in ./data
```

`mix test` runs everything (about a minute). `mix alnasl.bench` prints the
tracker's fault matrix. `mix alnasl.demo --faults bullet --speed 1` is a
hall playing bullet.

### On the box (Raspberry Pi, Linux)

```
sudo apt install elixir erlang build-essential   # or asdf/mise for a newer Elixir
git clone https://github.com/AuroraRyunix/Alnasl && cd Alnasl
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod ALNASL_LISTEN=lan mix phx.server
```

No environment variable is required. In `prod` the data goes to `~/.alnasl`
and the cookie secret is made on first start and kept there.

The kiosk: start a browser full-screen on the box's own address, e.g.

```
chromium-browser --kiosk --app=http://localhost:4040
```

A systemd unit and a ready-made image are not part of this build.

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4040` | The port of the management site |
| `ALNASL_LISTEN` | (local only) | `lan` to let other machines in the hall reach the site - the arbiter's laptop, and the phone the boards are numbered with. Set a PIN in Setup when you do |
| `ALNASL_DATA` | `./data` (dev), `~/.alnasl` (prod) | Where everything is kept |
| `ALNASL_UART` | on for Linux/macOS, off for Windows | `1` / `0`: build the serial library or not |

Everything else is set on the Setup page and stored in the database.

### Where the data lives

One directory (`ALNASL_DATA`):

```
alnasl.db                      settings, boards, games, the outbox, the log (SQLite, WAL, fsync on commit)
captures/board-<id>/*.jsonl    everything every board delivered, raw: always on, nothing to switch (rotated at 8 MB, capped in Setup)
pgn/round-<r>/board-<n>.pgn    every game as PGN with clock times, rewritten on every move
fixtures/*.jsonl               captures exported as test fixtures
secret_key_base                prod only
```

A real board is recorded from the moment it is connected, linked to a
round or not: every byte in both directions (`rx`/`tx`), every position
and clock reading made of them, with wall-clock milliseconds. The file is
`<ALNASL_DATA>/captures/board-<id>/<UTC date>-<time>.jsonl` - `./data/...`
from `mix phx.server`, `~/.alnasl/...` on the box. The Recordings page
lists, replays and downloads them; at a desk it is

```
mix alnasl.replay data/captures/board-3/20261012-101500.jsonl --timeline
mix alnasl.replay data/captures/board-3/20261012-101500.jsonl --settle 150 --depth 3
```

which plays the file through a fresh tracker (with other settings, if you
want to know what they would have made of it) and saves nothing.

### Serial ports

A DGT board is a serial port to the system: `/dev/ttyUSB0` or `/dev/ttyACM0`
on Linux (the user needs to be in the `dialout` group), `COM3` and the like
on Windows (Device Manager, *Ports (COM & LPT)*). 9600 baud, 8N1.

The serial library (`circuits_uart`) is C code built with `make`:

- **Linux / the Pi**: built by default. Needs `build-essential`.
- **Windows**: it builds with mingw-w64 (`gcc` and `make` on the PATH) -
  but **not from a folder with a space in its path**, and this checkout
  often lives in one. So on Windows it is off unless asked for, and the
  build output is sent somewhere without a space:

  ```
  set ALNASL_UART=1
  set MIX_DEPS_PATH=C:\alnasl-build\deps
  set MIX_BUILD_ROOT=C:\alnasl-build\_build
  mix deps.get
  mix alnasl.dgt --list
  ```

  (PowerShell: `$env:ALNASL_UART = "1"` and so on.) Verified on this
  project's Windows 11 machine: with those three variables the library
  builds and loads; without them the build stops in `make` on the space.

Without the library everything works except opening a real port: the Boards
page says so, and simulator boards are unaffected.

## How it works, in short

[docs/design.md](docs/design.md) is the long version.

- **A driver delivers whole positions**, not moves: 64 squares, each a piece
  or empty, every time anything changes. `Simulator` (PGN games played by an
  invisible hand, with faults), `Replay` (a capture file), `DgtSerial` (one
  DGT board), `DgtBus` (a loop of them).
- **The tracker turns positions into moves.** It keeps the last *certain*
  position. A board one legal move away is that move, once it has stood
  still for a moment (or at once on a clock press). A board that is not is
  searched for: the shortest sequence of legal moves that explains it. One
  answer is accepted and flagged; several are kept as candidates; none is a
  hand over the board - and only if it stays unexplained does the board go
  "Out of sync", raised to the arbiter, and it comes back by itself the
  moment the pieces make sense again.
- **The outbox sends, and never loses.** Every change is written to SQLite
  first, numbered per game, then sent in order with the relay key. Each
  message is the whole game so far, which is the server's own rule and what
  makes a retry harmless. Offline for hours is normal.
- **More than one destination.** The results server is one; a Lichess
  broadcast is another (`Alnasl.Destination`). Each keeps its own place in
  the queue and its own sender, so one being down never holds up another.
- **Everything is recorded raw**, per board, so a game can be rebuilt and a
  failure in a hall replayed at a desk.
- **A result is never final without the arbiter.** Mate on the board, or
  the kings set in the centre, is a suggestion.

## What is proven, and how

By `mix test` (283 tests), three tools, and one evening with a real board:

**The tracker**, against 69 games (59 classics before 1930, 7 constructed
for underpromotion and en passant, 3 more; 4599 plies) played through the
simulator under each fault mix, three passes each (`mix alnasl.bench
--passes 3`, 207 games a row):

| fault mix | exact | stopped, asked | wrong but flagged | **wrong, silent** |
|---|---|---|---|---|
| clean; hover, lift, knock, swap, missing clock presses, pawn left for a queen, takebacks, slides - each alone at 20-30%, and all together | 207 of 207, every row; **no alarm ever raised** | 0 | 0 | **0** |
| one ply at a time unseen (10%), alone and with the others | 198-204 | 3-9 | 0 | **0** |
| unplugged for 2 plies, twice | 204 | 3 | 0 | **0** |
| up to 3 plies in a row unseen (25%) | 15 | 192 | 0 | **0** |
| unplugged for 3 plies | 0 | 204 | 3 | **0** |
| unplugged for 8 plies (beyond the search) | 0 | 207 | 0 | **0** |
| an illegal move at ply 12, played on | - | 207 | 0 | **0** |
| bullet speed (a move every 0.3-2 s, the clock a second late), no faults; defaults, and "Bullet / fast play" | 207 of 207, both | 0 | 0 | **0** |
| bullet with slammed and knocked-over pieces, 6% of plies unseen, 10% of presses unreported; "Bullet / fast play" | 204 | 3 | 0 | **0** |

The box works out up to **two** unseen plies by itself (`search_depth`, 2;
Setup can raise it). That is why three unseen plies are now always an alarm
and an illegal move always is: searching four plies deep, 11 of 207 illegal
moves were "recovered" into games that were never played.

"Stopped, asked" is the tracker raising the board to the arbiter with what it
emitted until then correct - mostly a genuine ambiguity (a pawn that went one
square or two and was then taken leaves the same board), with the true
continuation among the candidates it keeps following. "Wrong but flagged" is
where three or more unseen plies had a shorter legal explanation than the
truth; the moves are marked *recovered*. That is the limit of reading a game
from positions, and `docs/design.md` says exactly where it lies. The tests
assert the last column and the first row.

The search for unseen moves is bounded: worst case over 400 scrambled
positions at depth 4 is about 0.1 s on a desktop (mean 15 ms, 3259 nodes);
inside the fault matrix, at the default depth of 2, the worst single search
was 6 ms.

**The outbox**, against a server that speaks the real contract in tests:
order across outages, a restart mid-queue, 500 / 503 / 429, duplicates,
late messages, corrections, a conflicting game on the server, a refused key.

**End to end against the real OpenResults** (`mix alnasl.e2e`, run on
2026-10-11 against a scratch copy of OpenResults at commit `a7b070b`, its
own port and database): three simulated boards with rough hands, a relay
key made with `OpenResults.RelayKeys.create/3`; the server was killed
mid-round for 35 seconds and started again. The queue grew to 163, drained
in order, and the server's own PGN of each game
(`/t/live-demo/live/1/<board>/pgn`) was identical move for move to the game
played - 74, 40 and 45 plies - with the results set on the box (0-1, 0-1,
1-0). That run also found two faults since fixed: the status line could read
"0 waiting" while the sender was busy, and each request opened a connection
pool of its own.

**The DGT serial driver, against a real board** (serial 06310, firmware
1.9, with a DGT clock; recorded 2026-10-12, decoded message by message in
[docs/real-board-2026-10-12.md](docs/real-board-2026-10-12.md)). Confirmed
by that recording, and pinned by tests that push its bytes through the
driver (`test/alnasl/real_board_test.exs`, fixtures `real-06310-*.jsonl`):

- the line and the framing, with messages arriving in pieces of at most 16
  bytes;
- the handshake: serial number, firmware version, the 64-square dump;
- a piece code and the order of the squares - one black knight, on d6, as
  the user saw it - and field updates as it was lifted and put down;
- the clock message: the times, running or not, which side runs, the lever,
  "no clock" when it is switched off; a press with its 30-second increment,
  a pause, a resume;
- which side of the clock is White's. It is fixed: the clock stands to the
  right of the board, and there is no setting to swap it;
- that a clock turned round and started on the wrong side is seen as
  exactly that. The recording ends with one.

Two things the recording corrected: the lever is up on the side whose time
*runs* (the code had it the other way, in a fallback that was never
reached), and a "no clock" message was dropped when a recording was
replayed from its bytes.

The same driver is also run, byte for byte, against an emulated board built
from the protocol description - which proves driver and emulator agree
with each other, and is how the clock check and the clock alarm are tested
with the pieces in the starting position.

**The site**: LiveView tests of every page's main actions; an accessibility
pass that computes the contrast of every text pairing of the colour tokens
(all above 4.5:1, in every theme) and checks structure, labels
and names on every page in both languages.

## What is not done

- **No game has been played on a real board.** One board has been read
  (see above), with one knight on it: eleven of the twelve piece codes, a
  capture, castling, a promotion and a whole game through the tracker with
  real hands are still to come. The clock's battery-low bit and the flag
  bits beside the hours were never set; a board lying the other way round
  was not tried. Next session: [docs/tomorrow.md](docs/tomorrow.md).
- **The bus (loop) wire format is assumed.** `lib/alnasl/dgt/bus.ex` holds
  every byte of it, each marked `ASSUMED`, with a TODO list. The polling
  scheduler and the per-address board model are built and tested against an
  emulator that makes the same assumptions. The Boards page says "not
  verified" beside every bus board.
- **The result gesture** (kings in the centre: both on light squares = 1-0,
  both on dark = 0-1, one on each = draw) is how DGT LiveChess is understood
  to work, not something read in a specification. It is only ever a
  suggestion.
- **No DGT clock commands** are sent (nothing is written to the clock's
  display); the clock is only read. What the clock says about itself when it
  is switched on (`0A 10 01 2A 00 00 00`) is recognised and not decoded.
  Because nothing is written to it, "Show me" cannot make a board or its
  clock beep: you are told the serial to look for.
- **Lichess has not been met.** The push destination follows Lichess's API
  documentation; the answers it expects are marked `ASSUMED` where the
  documentation leaves room (`lib/alnasl/destination/lichess_api.ex`). Its
  tests run against a stand-in that makes the same assumptions.
- **A board that moves to a port the box has no board on is recognised
  when it is added there**, not by itself: Alnasl does not open serial ports
  nobody told it to open. (Boards that change places among the ports it
  already reads are sorted out without anybody.)
- **The phone pages were not held in a hand.** They are laid out for 375 px
  and tested for what they contain and do; the buzz and the beep are browser
  features a test cannot feel (iOS Safari has no vibration at all).
- **The clock alarm knows one thing**: a clock *started* on the wrong side
  with the pieces in the starting position. A clock swapped or re-set
  wrongly in the middle of a game is not looked for.
- **Chess960** is not supported (neither is it by the server's checker).
- **Three or more moves unseen in a row** are an alarm, not a guess, at the
  default search depth of 2; raised in Setup they can be reconstructed
  wrongly in constructed cases (flagged, never silent).
- **Bullet on a real board has not been played.** The fast-play rules and
  numbers come from the simulator (`docs/design.md`, "Fast play"). How a
  real board's scan reads a slammed or toppled piece is not known; the
  recording of the session will say.
- **No visual check in a browser by a person** was part of this build; two
  screenshots were taken headless. Colour-blind safety rests on shapes and
  words, which the tests check exist and differ, not on anybody looking.
- **No installer, no systemd unit, no Pi image.** `mix phx.server` it is.
- **One loop per port is modelled; several ports work** (each port is its
  own bus), but more than one has only been run against the emulator.
- **Bluetooth DGT, Millennium, Chessnut**: not started. A driver is one
  module behind `Alnasl.Driver`.

## Stack

Elixir, Phoenix 1.8 LiveView, SQLite (`ecto_sqlite3`), `Req` for HTTP,
`circuits_uart` for serial ports, `eqrcode` (MIT) for the QR code of the
box's address. No Tailwind and no component library: the
stylesheet is hand-written (`assets/css/app.css`), bundled by esbuild.

## License

Apache License 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Alnasl is not affiliated with or endorsed by DGT (Digital Game Technology).
"DGT" is their trademark, used here only to say which boards Alnasl talks to.

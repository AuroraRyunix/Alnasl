# Alnasl

**Live chess boards, from the hall to the web.**

Alnasl reads electronic chess boards in the playing hall and sends every move,
with the clock times, to the live results site as it is played. It runs on a
small box beside the boards - a Raspberry Pi with a screen, keyboard and mouse
for the arbiter - and keeps working when the hall's internet does not.

> Status: **first build. Everything runs - on simulated boards.** The tracker,
> the outbox, the management site and the drivers are written and tested
> without hardware; the DGT serial driver has not met a real board yet, and
> the wire format of a DGT *loop* is assumed, not verified. See
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
arbiter's laptop on the hall's network. English and Dutch, light and dark.

| Page | What it is for |
|---|---|
| **Round** | The screen during play. A tile per board: players, the position the box is sure of, clocks, last move, and the state as a shape and a word - Live, Waiting for start, Settling, Recovered a move, Out of sync, No signal, Finished. A tile is the way to the board's own page. Fetch the pairings, start the next round |
| **A board** | The position large, the move list, and - when board and game have parted ways - what the board reads beside what is certain. The repair tools: resync from the board (search deeper, or pick from the candidates), type moves, undo, change a move, set the result, start from a FEN, pause and resume sending, turn the board round |
| **Boards** | What is plugged in. Add a DGT board or a simulator; connect and disconnect; each board's live picture, signal quality, serial number and firmware; the start-position check ("black queen and black king are swapped (d8, e8)"); link a board to its board number, or a whole row in order |
| **Outbox** | The connection, honestly: connected or not, last success, how much is waiting and why it is not going, in words. What waits, what the server refused, what went out. "Send now" |
| **PGN** | Read PGN files or pasted moves (checked for legality). Play a game on a simulator board; attach a game that was not captured to its board, after asking; compare a scoresheet with the captured game (the first difference). Export a game or the whole round |
| **Recordings** | The raw captures per board. Replay one through the tracker as a dry run (what it makes of it, where it lost the thread); export it as a test fixture; download it |
| **Log** | What happened, in sentences, with filters: board connected, moves recovered, out of sync, repaired by the arbiter, offline, back |
| **Setup** | Results server, tournament (its short name, or paste the link), relay key (never shown again once saved), "Test connection" that really asks the server and explains failures; the box's name, language, round; a PIN for other machines; the tracker's timings |
| **Help** | The cycle on one page: before the round, during, after, and when something is wrong |

A banner on every page says so when the results server cannot be reached.

## Running it

### On a PC (development)

```
mix deps.get
mix phx.server        # http://localhost:4040, data in ./data
```

`mix test` runs everything (about a minute). `mix alnasl.bench` prints the
tracker's fault matrix.

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
| `ALNASL_LISTEN` | (local only) | `lan` to let other machines in the hall reach the site. Set a PIN in Setup when you do |
| `ALNASL_DATA` | `./data` (dev), `~/.alnasl` (prod) | Where everything is kept |
| `ALNASL_UART` | on for Linux/macOS, off for Windows | `1` / `0`: build the serial library or not |

Everything else is set on the Setup page and stored in the database.

### Where the data lives

One directory (`ALNASL_DATA`):

```
alnasl.db                      settings, boards, games, the outbox, the log (SQLite, WAL, fsync on commit)
captures/board-<id>/*.jsonl    everything every board delivered, raw (rotated at 8 MB, capped in Setup)
pgn/round-<r>/board-<n>.pgn    every game as PGN with clock times, rewritten on every move
fixtures/*.jsonl               captures exported as test fixtures
secret_key_base                prod only
```

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
- **Everything is recorded raw**, per board, so a game can be rebuilt and a
  failure in a hall replayed at a desk.
- **A result is never final without the arbiter.** Mate on the board, or
  the kings set in the centre, is a suggestion.

## What is proven, and how

Without hardware, by `mix test` (189 tests) and three tools:

**The tracker**, against 69 games (59 classics before 1930, 7 constructed
for underpromotion and en passant, 3 more; 4599 plies) played through the
simulator under each fault mix, three passes each (`mix alnasl.bench
--passes 3`, 207 games a row):

| fault mix | exact | stopped, asked | wrong but flagged | **wrong, silent** |
|---|---|---|---|---|
| clean; hover, lift, knock, swap, missing clock presses, pawn left for a queen, takebacks, slides - each alone at 20-30%, and all together | 207 of 207, every row; **no alarm ever raised** | 0 | 0 | **0** |
| one ply at a time unseen (10%), alone and with the others | 201-204 | 3-6 | 0 | **0** |
| unplugged for 2 plies, twice | 204 | 3 | 0 | **0** |
| up to 3 plies in a row unseen (25%) | 47 | 159 | 1 | **0** |
| unplugged for 3 plies | 110 | 94 | 3 | **0** |
| unplugged for 8 plies (beyond the search) | 3 (games that short) | 204 | 0 | **0** |
| an illegal move at ply 12, played on | - | 196 | 11 | **0** |

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
inside the fault matrix the worst single search was 0.27 s.

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

**The DGT serial driver**, byte for byte against an emulated board built
from the same protocol description: it proves driver and protocol module
agree with each other, and nothing about a real board.

**The site**: LiveView tests of every page's main actions; an accessibility
pass that computes the contrast of every text pairing of the colour tokens
(lowest: 5.66:1; all above 4.5:1, both themes) and checks structure, labels
and names on every page in both languages.

## What is not done

- **No real board has been read.** The DGT serial driver follows DGT's
  published protocol as written from memory of that description. Its framing
  and piece codes are tested with hand-built bytes; the clock message's
  status bits and which side of the clock is White are marked `ASSUMED` in
  `lib/alnasl/dgt/protocol.ex`. First session: [docs/tomorrow.md](docs/tomorrow.md).
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
  display); the clock is only read.
- **Chess960** is not supported (neither is it by the server's checker).
- **Three or more moves unseen in a row** can be reconstructed wrongly in
  constructed cases (flagged, never silent) - see the table above.
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
`circuits_uart` for serial ports. No Tailwind and no component library: the
stylesheet is hand-written (`assets/css/app.css`), bundled by esbuild.

## License

Apache License 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Alnasl is not affiliated with or endorsed by DGT (Digital Game Technology).
"DGT" is their trademark, used here only to say which boards Alnasl talks to.

# The sessions with real boards

Everything above the serial driver is proven on simulated boards. This is
the checklist for the days the driver meets real ones. The aim of a session
is **recordings**, not a working round: with the files listed at the end,
the drivers can be confirmed or corrected at a desk.

Work through it in order. Each step says what should happen, and what it
means when it does not.

## Where it stands

**Step 1 was half done on 2026-10-12** - one board (serial 06310, firmware
1.9), one black knight, a clock. `docs/real-board-2026-10-12.md` has
every byte. Confirmed:

- the port, the framing, the handshake (serial number, version, dump);
- the piece code of a black knight and the order of the squares (the knight
  was on d6 and the box said d6), field updates as it was lifted and put
  down on e4, d4, c2, d2;
- the clock: times, running or not, which side, the lever, the 30-second
  increment at a press, pause and resume, switched off ("no clock") and on;
- left is White - and that is now fixed, not an option: the clock stands to
  the right of the board. A clock turned round is reported as set up
  wrongly. This went into the starting-position check and a clock alarm.

**What remains**, in this order:

1. **A real game on one board** - the rest of step 1 below: all the pieces
   in the starting position (eleven piece codes have not been seen), moves
   with real hands, a capture both ways, castling both ways, a promotion,
   a knock, a slide, an unplug. And the **result gesture** (kings in the
   centre), which is still only how LiveChess is understood to work.
2. **The clock in a game**: start it on White's side, press after every
   move; then once on purpose with the clock turned round, to see the
   starting-position check and the alarm on the real thing (they are
   tested against the recording's clock bytes, with emulated pieces).
3. **The loop, with somebody at the boards** - step 3. On 2026-10-12 two
   boards on one cable were found, named and read
   (`docs/real-loop-2026-10-12.md`): the frames, the discovery, the
   versions, the positions, the pace. Nobody was at the boards and no
   clock was attached, so what remains is a move as it is played, a clock,
   and more than two boards.

Smaller things a session can settle in passing: a board lying the other
way round (does it read mirrored, and does the box turn it?); the clock's
battery-low bit; which side runs when a paused clock whose lever was tipped
by hand is started again; and the port held by another program - the
`:eacces` seen on 2026-10-12 left no line in a capture, so write down what
the Boards page says while it happens.

## 0. Before the boards are unpacked (5 minutes)

On this Windows PC the serial library only builds from a path without a
space. Open a terminal in the Alnasl folder and set, **in that terminal**:

PowerShell:

```
$env:ALNASL_UART = "1"
$env:MIX_DEPS_PATH = "C:\alnasl-build\deps"
$env:MIX_BUILD_ROOT = "C:\alnasl-build\_build"
mix deps.get
mix alnasl.dgt --list
```

Git Bash:

```
export ALNASL_UART=1 MIX_DEPS_PATH=C:/alnasl-build/deps MIX_BUILD_ROOT=C:/alnasl-build/_build
mix deps.get
mix alnasl.dgt --list
```

The first run compiles everything again into `C:\alnasl-build` (two or three
minutes). `--list` prints the serial ports, or "No serial ports found" when
nothing is plugged in - either means the library works. "The serial library
is not built" means the three variables are not set in this terminal.

Keep using this terminal for every command below.

On the Pi none of this is needed: `mix deps.get` builds the library.

## 1. One board, on its own cable

(The first second of this - the handshake - and the clock were recorded on
2026-10-12. The moves were not: there was one knight on the board.)

Plug in ONE board (not the loop), with its clock - **to the right of the
board, White's display toward White, the lever up on White's side** -
pieces in the starting position. Close any other program that has the port
open: only one can.

```
mix alnasl.dgt --list
mix alnasl.dgt --port COM3 --seconds 180 --out captures/single-1.jsonl
```

(`COM3` is whatever `--list` showed; on Linux `/dev/ttyUSB0` or
`/dev/ttyACM0`.)

**What should scroll past in the first second:**

```
0.0   tx    40          reset
0.0   tx    45          serial number, please
0.0   tx    4d          version, please
0.0   tx    42          the whole board, please
0.0   tx    4b          tell me every change
0.1   rx    91 00 08 ...                 <- serial number
0.1   info  %{serial: "..."}
0.1   rx    93 00 05 01 09               <- version
0.1   rx    86 00 43 08 09 0a 0c 0b ...  <- the board: 67 bytes
0.1   connected
0.1   position  rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR
```

| If you see | It means |
|---|---|
| `tx` lines and never an `rx` | wrong port, wrong cable, the board has no power. (Not "still in bus mode": a board answers single-board commands in bus mode too, as 2026-10-12 showed) |
| `info %{error: ":eacces"}` every 3 s | another program has the port (LiveChess, a terminal, a second `mix alnasl.dgt`). Close it; the driver gets in by itself |
| `rx` bytes but no `position` | the framing in Arkab's `lib/arkab/dgt/protocol.ex` does not match. **Keep the capture**: it holds the bytes |
| a position, but mirrored (White's pieces on rank 8) | the board is the other way round. Fine: the box turns it by itself. Note it down |
| a position with wrong pieces | the piece codes differ. Keep the capture |

Then, typing a note **before** each action (type the note, press Enter, then
do it):

| Note to type | Do |
|---|---|
| `e2e4` | 1.e4, normally |
| `e7e5` | 1...e5 |
| `lift g1 putback` | lift the g1 knight, hold it 3 seconds, put it back |
| `g1f3 slow` | Nf3, holding the knight in the air for 3 seconds first |
| `capture off first` | play to a capture (1...d5 2.exd5): take the pawn off, then move |
| `capture lift first` | another capture, lifting the capturing piece first |
| `castle king first` | play to castling; king, then rook |
| `castle rook first` | (other colour, or a second run) rook, then king |
| `knock` | knock a piece over and set it back |
| `slide` | a rook or bishop slid along the board without lifting |
| `clock start` | start the clock |
| `clock press` | make a move and press the clock; three times |
| `clock press no move` | press the clock twice without moving |
| `clock pause lever` | pause the clock, tip the lever over, start it again: which side runs? |
| `promote` | play (or set up) a pawn to the last rank; once with a queen put on, once leaving the pawn |
| `kings centre` | both kings on e4 and d5 (the "1-0" signal) |
| `unplug` | pull the cable for 10 seconds, plug it back |

Stop with Ctrl+C (or let the 180 seconds run out).

**Check it at once:**

```
mix alnasl.replay captures/single-1.jsonl
```

It prints the moves the tracker found, every out-of-sync and every
correction with its time, and your notes with theirs. Compare: do the moves
match what you played? Did a lifted piece produce a move (it must not)?

For the clock, look at the `clock` lines the live output printed while you
pressed: do white and black have the right times, and does `running` name
the side whose clock is really running? On 2026-10-12 they did. If the two
are swapped now, the clock is standing the wrong way round - there is
nothing to flip in the box, on purpose; turn the clock. A clock standing
still prints `(lever: black first)` when it is set the wrong way.

## 2. The same board, through the whole application

```
mix phx.server
```

Open http://localhost:4040, **Boards** → Add a board → "Electronic board on its own
serial port" → the port → Add. It should show the position, serial number
and firmware, and "Start position: Right - pieces and clock". Tip the
clock's lever to Black's side: it must change to "Clock wrong" with the
sentence "Clock not in starting position: Black's side would run first - the
clock is turned or the lever is the wrong way", and back by itself when the
lever is put right. Start the clock on Black's side with the pieces set up:
the tile on **Round** must go to "Clock wrong way" at once, and back when
the clock is corrected. Link it to a board number, open
**Round**, play a few moves, lift a piece, knock one over. This is the same
driver as step 1 with the site on top; if step 1 worked, this is the
pleasant part. Its capture is in `data/captures/board-<id>/`.

Without a results server set up, the Outbox simply keeps everything. That
is fine for today.

## 3. A loop

Two or more boards on the bus cable, one port. Close the board maker's own software first:
it holds the port.

### 3a. Who is there

```
mix alnasl.loop --port COM5 --discover
```

A line per board: the number it answers to, its firmware, its serial
number when it says it, and what stands on it. Compare with the labels
under the boards and with the pieces. **Write down the serial number on
the label of every board whose line says "serial not said on a loop"**:
that is the newer generation, and how its number on the loop relates to
its serial number is not known.

| What you see | What it means |
|---|---|
| a line per board | as on 2026-10-12 |
| fewer lines than boards | a board without power, a cable out - or two boards that answer to the same number. Take boards off one by one and run it again; note which two never show up together |
| nobody answered | wrong port, or the loop cable is not on this adapter |

### 3b. A move and a clock, live

This is what the first session could not do. Put a clock on one board.

```
mix alnasl.loop --port COM5 --watch --seconds 90 --out captures/loop-live.jsonl
```

While it runs: 1. e4 e5 on one board, any two moves on the other, and
press the clock's lever after each move on its board. Wanted:

- a `position` line within a blink of each piece put down. If positions
  come only every three seconds, the boards do not report changes as they
  happen and the whole-board question is doing the work: correct, slow,
  and exactly what needs to be known;
- `clock` lines with the times the display shows, and the side that runs;
- the last lines: how many questions each board answered and missed.

Then pull one board's cable out of the chain for ten seconds and put it
back: `disconnected`, then `connected` and its position again.

### 3c. Through the site

Start the site (`mix phx.server`, same terminal), Boards, Add a board:
choose the port, press Add. Each board gets a row. Give them table numbers
by touching them (Number). Unplug one from the chain: its row says why.
Plug a third board into the chain if there is one: it gets a row by itself
within ten seconds.

If the port was added earlier as one board, its row says "More than one
board answers on this port: it is a loop" - press "Read it as a loop".

### 3d. One board of the newer kind, alone

Plug the newer board in on a port of its own (no loop) and add that port.
Its row shows its serial number; note it, and the "answers as" number it
shows once it is back on the loop. From then on the box knows that board
by its serial number on a loop too.

### If something on the loop is not understood

`docs/capture.md`: LiveChess drives the loop through a virtual port and a
proxy writes down every byte both ways. It is the answer sheet for
whatever Alnasl gets wrong, and it has not been needed so far.

## 4. What to send back

Put these in `captures/<date>/` and hand them over (or commit them on a
branch):

1. `single-1.jsonl` - step 1. And a second run if the first went wrong.
2. `loop-live.jsonl` - step 3b. **The important one.**
3. What `--discover` printed in step 3a, and the labels.
4. The capture(s) from step 2: `data/captures/board-*/`.
5. A text file, `hardware.txt`:
   - each board: model, RS232 or USB-C, serial number (it is printed in
     step 1), which way round it lay;
   - the clock model; which side of it White sat;
   - the LiveChess version;
   - the order of the boards on the loop cable, and which board number
     LiveChess gave each;
   - anything that surprised you.

## 5. What happens with them

| File | Used for |
|---|---|
| `single-1.jsonl` | (Done for the handshake and the clock: `docs/real-board-2026-10-12.md`.) Each `ASSUMED` in `protocol.ex` is checked against the `rx` bytes and corrected; the bytes become a test fixture; the tracker's handling of real hands (lift times, capture order, slides) is compared with your notes, and the timings in Setup adjusted if real hands are slower or faster than the simulator's |
| `loop-live.jsonl` | The three things `Arkab.Dgt.Bus` still calls ASSUMED: a move in the next "what changed?", the clock's times on the bus, "repeat". Each becomes a fixture and loses the word, or the driver is corrected |
| the labels | whether a newer board's number on the loop can be worked out from its serial number, and whether two of them can share one |
| step 2 captures | A whole game through the real driver: the first real fixture for the test suite |

Nothing else in the application should have to change: the tracker, the
outbox and the site take whole positions from a driver and do not know
which one.

## If there is time left

- Set up a results server (a tournament published from OpenPairings, a
  relay key from the OpenResults admin panel), put address, tournament and
  key in **Setup**, "Test connection", and watch a real board's moves
  arrive on the live page. Pull the network cable for a minute and put it
  back.
- Play a real blitz game on one board and compare the PGN (**PGN** page →
  export) with what was played. Fast hands are the real test of
  `settle_ms`.

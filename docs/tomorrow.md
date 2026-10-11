# The first session with real boards

Everything above the serial driver is proven on simulated boards. This is
the checklist for the day the driver meets a real one. The aim of the
session is **recordings**, not a working round: with the files listed at the
end, the single-board driver can be confirmed or corrected and the bus
driver finished at a desk.

Work through it in order. Each step says what should happen, and what it
means when it does not.

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

Plug in ONE board (not the loop), with its clock if it has one, pieces in
the starting position.

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
0.1   rx    93 00 05 01 ..               <- version
0.1   rx    86 00 43 08 09 0a 0c 0b ...  <- the board: 67 bytes
0.1   connected
0.1   position  rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR
```

| If you see | It means |
|---|---|
| `tx` lines and never an `rx` | wrong port, wrong cable, the board has no power - or it is still in bus mode from its last use (power it off and on) |
| `rx` bytes but no `position` | the framing in `lib/alnasl/dgt/protocol.ex` does not match. **Keep the capture**: it holds the bytes |
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
the side whose clock is really running? If the two are swapped, that is the
ASSUMED "left is White" - say so, it is one option to flip. If `running` is
wrong or always `none`, the status byte's bits are not what
`protocol.ex` assumes: the `rx 8d 00 0a ...` lines in the capture are what
is needed.

## 2. The same board, through the whole application

```
mix phx.server
```

Open http://localhost:4040, **Boards** → Add a board → "DGT board on its own
serial port" → the port → Add. It should show the position, serial number
and firmware, and "Start position: Right". Link it to a board number, open
**Round**, play a few moves, lift a piece, knock one over. This is the same
driver as step 1 with the site on top; if step 1 worked, this is the
pleasant part. Its capture is in `data/captures/board-<id>/`.

Without a results server set up, the Outbox simply keeps everything. That
is fine for today.

## 3. A loop

Now the loop: 2 or 3 boards on the bus cable. **Two captures, and the first
matters most.**

### 3a. DGT's own software driving the loop (the reference)

This is `docs/capture.md`: LiveChess talks to the boards through a virtual
port and `tools/serial_proxy.py` writes down every byte both ways. It needs
com0com and Python with pyserial; the steps and the script of moves are in
that file.

```
py -3 tools/serial_proxy.py --app COM11 --board COM3 --out captures/loop-livechess.log
```

Let LiveChess find the boards, then play the script, typing a note before
each action. **Make at least one move on every board**, and note which
board (`b2 d2d4`), so addresses can be matched to boards.

This capture is the answer sheet: it shows what a real master sends
(`APP>BRD`) and what real boards answer (`BRD>APP`).

### 3b. Alnasl's own guess at the loop

Close LiveChess and the proxy. Then:

```
mix alnasl.dgt --port COM3 --bus 1,2,3 --seconds 60 --out captures/loop-alnasl.jsonl
```

The addresses `1,2,3` are a guess - if 3a showed other addresses in the
`APP>BRD` lines, use those. Expect this to print `tx` lines and `poll ...
no answer` and nothing else: the frames in `lib/alnasl/dgt/bus.ex` are
ASSUMED. If boards do answer, so much the better. Either way keep the file.

Check what the proxy log holds:

```
mix alnasl.replay captures/loop-livechess.log --timeline
```

If the loop's answers happen to be framed like single-board messages this
already shows positions. More likely it shows nothing, and that is
expected - the log is still exactly what is needed.

## 4. What to send back

Put these in `captures/<date>/` and hand them over (or commit them on a
branch):

1. `single-1.jsonl` - step 1. And a second run if the first went wrong.
2. `loop-livechess.log` - step 3a. **The important one.**
3. `loop-alnasl.jsonl` - step 3b.
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
| `single-1.jsonl` | Each `ASSUMED` in `protocol.ex` is checked against the `rx` bytes and corrected; the bytes become a test fixture; the tracker's handling of real hands (lift times, capture order, slides) is compared with your notes, and the timings in Setup adjusted if real hands are slower or faster than the simulator's |
| `loop-livechess.log` | `bus.ex` is rewritten from it: command ids, the address bytes, the checksum, how LiveChess finds the boards, whether it asks for changes or dumps. Every TODO in that file is answered by this log or it is not answered |
| `loop-alnasl.jsonl` | Shows what the boards do with the current guess - sometimes a board's silence, or its error answer, says which byte was wrong |
| step 2 captures | A whole game through the real driver: the first real fixture for the test suite |

Nothing else in the application should have to change: the scheduler, the
board model, the tracker, the outbox and the site already run - against an
emulator that was written from the same assumptions, which is exactly why
it proves nothing about the wire.

## If there is time left

- Set up a results server (a tournament published from OpenPairings, a
  relay key from the OpenResults admin panel), put address, tournament and
  key in **Setup**, "Test connection", and watch a real board's moves
  arrive on the live page. Pull the network cable for a minute and put it
  back.
- Play a real blitz game on one board and compare the PGN (**PGN** page →
  export) with what was played. Fast hands are the real test of
  `settle_ms`.

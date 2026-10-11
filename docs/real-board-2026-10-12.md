# The first real board: what it sent, 2026-10-12

A DGT board (serial number **06310**, firmware **1.9**) on its own USB
serial port (COM4, 9600 8N1), with a DGT clock on its clock socket and one
black knight on it. Two recordings were made with `mix alnasl.dgt`; this is
every kind of message in them, what the driver made of each, and what that
settles about the constants in `lib/alnasl/dgt/protocol.ex`.

The recordings themselves stay out of the repository (`captures/` is
ignored). The parts that matter are test fixtures -
`test/fixtures/captures/real-06310-*.jsonl` - and
`test/alnasl/real_board_test.exs` pushes their bytes through the real
driver.

| Recording | Length | What was done |
|---|---|---|
| `single-1.jsonl` | 0.1 s of traffic | The opening handshake. One black knight on d6 - **the user looked, and confirms it** |
| `clock-1.jsonl` | **4 min 7 s** (not the 20 minutes it was meant to be: the file and the console text both end at 246.7 s) | The clock attached, set and started on White's side; the lever pressed four times; paused, resumed, paused, the lever tipped by hand; the knight carried over the board; the clock switched off, turned round, switched on and started - on Black's side |

**What is not in `clock-1`:** the presses made after the clock was turned
round. From 103 s to the end Black's side runs without interruption. Either
the recording was stopped earlier than remembered or those presses were
made after it was killed; nothing in the file is cut off (the last line is
whole, the last message complete).

## Verdict, in one table

| What | Before | Now | Evidence |
|---|---|---|---|
| Line: 9600 baud 8N1 | PUBLISHED | **CONFIRMED** | 8044 bytes, 336 messages, not one byte outside a message |
| Framing: id with bit 7 set, two 7-bit size bytes, size counts the header | PUBLISHED | **CONFIRMED** | every message of both recordings |
| Commands 0x45, 0x4D, 0x42, 0x4B | PUBLISHED | **CONFIRMED** | each was answered as described |
| Command 0x40 (reset) | PUBLISHED | consistent | sent; nothing came back, which is what it should do |
| Serial number 0x91, 8 bytes, 5 ASCII digits | PUBLISHED | **CONFIRMED** | `91 00 08 30 36 33 31 30` = "06310" |
| Version 0x93, 5 bytes, major and minor | PUBLISHED | **CONFIRMED** | `93 00 05 01 09` = 1.9 |
| Board dump 0x86, 67 bytes | PUBLISHED | **CONFIRMED** | 83 of them |
| Piece code 0x09 = black knight, 0x00 = empty | PUBLISHED | **CONFIRMED** | the knight; the other eleven codes were not on the board |
| Square order: 0 = a8 ... 63 = h1 | PUBLISHED | **CONFIRMED** | d6 is byte 19; field updates 36, 35, 50, 51 for e4, d4, c2, d2 |
| Field update 0x8E, 5 bytes: square, piece (0 = lifted) | PUBLISHED | **CONFIRMED** | 8 of them |
| Clock message 0x8D, 10 bytes | PUBLISHED | **CONFIRMED** | 243 of them |
| Clock times: hours in a nibble, minutes and seconds BCD | PUBLISHED | **CONFIRMED** | `01 30 30` on a clock showing 1:30:30; `01 30 00` followed by `01 29 59` |
| Clock "ack" form (low nibble 0x0A in an hours byte) is not a time | PUBLISHED | **CONFIRMED** | `0A 10 01 2A 00 00 00`, twice |
| Status bit 0 = running | ASSUMED | **CONFIRMED** | 0x10 / 0x11 around start, pause, resume |
| Status bits 3 / 4 = Black's / White's side to move | ASSUMED | **CONFIRMED**, and sharper: they name a **side of the clock**, not whoever started | the clock turned round said "Black" for the side that ran first |
| Status bit 5 = no clock | ASSUMED | **CONFIRMED** | 0x30 the moment the clock was switched off |
| Status bit 1 = the lever, "high on the right player's side" | ASSUMED | **CONFIRMED** as the lever; set = up on Black's side | set with every 0x0B, clear with every 0x11, and it moved alone (0x10 ↔ 0x12) when the lever was tipped on a paused clock |
| "The lever is high on the side whose clock is NOT running" (`lever_side/2`) | ASSUMED | **CONTRADICTED - fixed** | bit 1 was set exactly while Black's time ran. The lever is up on the side that runs. The code only used this when bits 3/4 said nothing, so no reading was wrong on the day |
| "Left is White, unless the board's `clock_white` option says otherwise" | ASSUMED | **Left is White: CONFIRMED. The option: removed** | bytes 3-5 counted down while the user watched White's display run. See [Sides](#sides-there-is-no-option) |
| A "no clock" message was `:ignore` in `Protocol.apply_message/2` | - | **fixed** | a recording replayed from its bytes kept the dead clock's last reading running. It is `{:info, %{clock: false}}` now, as the driver already said |
| Status bit 2 = battery low | ASSUMED | still unverified | never set |
| Flag bits in the high nibble of the hours | PUBLISHED | still unverified | never set (the `7` in `71 3F 7F` is a dead clock, not a flag) |
| Battery message id 0x20, long serial number id 0x22 | ASSUMED | still unverified | not sent by this board |
| Bus address, trademark, EEPROM moves | PUBLISHED | still unverified | never asked for |
| Everything in `lib/alnasl/dgt/bus.ex` | ASSUMED | still ASSUMED | one board on its own cable says nothing about a loop |

## Every message, with its bytes

Times are seconds from the start of `clock-1`.

### Sent by the driver (tx)

| Bytes | Command | When | What came back |
|---|---|---|---|
| `40` | reset | once, first | nothing |
| `45` | serial number | once | `91 00 08 30 36 33 31 30` within 11 ms |
| `4D` | version | once | `93 00 05 01 09` |
| `42` | whole board | once, then every 3 s (83 in all; 3000-3017 ms apart) | a 67-byte dump, its first byte 0-41 ms later (median 12) |
| `4B` | update mode "nice" | once | no answer of its own: field updates when a piece moves, the clock when it changes |

All five went out within 2 ms of each other, before the board had answered
anything, and it answered all of them in order.

### Received (rx)

**Serial number** - `91 00 08 30 36 33 31 30`. Driver: `{:info, %{serial:
"06310"}}`. Right.

**Version** - `93 00 05 01 09`. Driver: `{:info, %{firmware: "1.9"}}`.

**Board dump** - `86 00 43` and 64 squares. In `single-1` byte 19 is `09`
and the other 63 are `00`: `8/8/3n4/8/8/8/8/8`, a black knight on d6. That
is what stood on the board. Framing, the 64-byte layout, the piece code and
the orientation are right for this board lying the usual way round.

**Field update** - `8E 00 05 <square> <piece>`. The knight's trip:

| t | Bytes | Meaning |
|---|---|---|
| 84.160 | `8E 00 05 13 00` | d6 empty: lifted |
| 84.752 | `8E 00 05 24 09` | black knight on e4 |
| 89.898 | `8E 00 05 24 00` | e4 empty |
| 89.930 | `8E 00 05 23 09` | on d4, 32 ms later: slid, or put down next door at once |
| 90.154 | `8E 00 05 23 00` | d4 empty |
| 90.330 | `8E 00 05 32 09` | on c2 |
| 90.458 | `8E 00 05 32 00` | c2 empty |
| 90.649 | `8E 00 05 33 09` | on d2, where it stayed |

Driver: a whole new position for each, nine pictures in all. A dump that
arrived between a lift and a put-down (84.416: the empty board) agreed with
the picture the driver already had.

**Clock** - `8D 00 0A` and seven bytes: Black's side (hours, minutes,
seconds), White's side (the same), status.

| t | Bytes (data) | Status | What the clock was doing | Driver |
|---|---|---|---|---|
| 5.933 | `0A 10 01 2A 00 00 00` | - | announcing itself, 5.9 s after the handshake | `{:clock_ack, _}`: not a time, nothing reported |
| 6.445 | `01 30 30 01 30 30 10` | 0x10 | standing still, 1:30:30 each, lever up on White's side | `running: none`, set for White |
| 8.651 | `01 30 30 01 30 30 11` | 0x11 | started: White's time runs | `running: white` - **the user confirms** |
| 9.594 ... | `01 30 30 01 30 29 11` ... | 0x11 | one message a second, White's seconds going down | White counting down |
| 74.809 | `01 30 30 01 29 54 0B` | 0x0B | lever pressed at White's 1:29:25: Black runs, White has 1:29:54 | a press; `running: black` |
| 80.707 | `01 30 55 01 29 54 11` | 0x11 | pressed at Black's 1:30:25: White runs, Black has 1:30:55 | a press; `running: white` |
| 85.775 | `01 30 55 01 30 19 0B` | 0x0B | pressed at White's 1:29:49 → 1:30:19 | a press |
| 91.753 | `01 31 19 01 30 19 11` | 0x11 | pressed at Black's 1:30:49 → 1:31:19 | a press |
| 93.079 | `01 31 19 01 30 18 10` | 0x10 | paused | `running: none` |
| 94.902 | `01 31 19 01 30 18 11` | 0x11 | resumed | `running: white` (not a press) |
| 96.212 | `01 31 19 01 30 16 10` | 0x10 | paused again | `running: none` |
| 97.171 | `01 31 19 01 30 16 12` | 0x12 | still paused; the lever tipped to Black's side by hand | set for Black |
| 97.619 | `01 31 19 01 30 16 10` | 0x10 | tipped back | set for White |
| 98.050 | `01 31 19 01 30 16 12` | 0x12 | and over again | set for Black |
| 99.968 | `01 31 19 71 3F 7F 30` | 0x30 | **switched off**: bit 5, and nonsense where White's time was | `{:info, %{clock: false}}` |
| 100.991 | `01 30 30 01 30 30 0A` | 0x0A | **on again, turned round**: reset to 1:30:30, lever up on what the board knows as Black's side | `running: none`, set for Black |
| 102.814 | `0A 10 01 2A 00 00 00` | - | announcing itself again, 1.8 s after coming on | not a time |
| 103.260 | `01 30 30 01 30 30 0B` | 0x0B | **started on the wrong side**: Black's time runs | `running: black` - the driver was right to say so; the set-up was wrong |
| ... 246.414 | `01 28 07 01 30 30 0B` | 0x0B | Black's side still running when the recording ends | Black counting down, White untouched |

The increment is 30 seconds, added to the side that pressed, at the press.
The display shows a second less than "time at the press + 30" as often as
not, because the press falls inside a second.

The announcement `0A 10 01 2A 00 00 00` has the form DGT's description gives
a clock's answer to a command (low nibble 0x0A where the hours belong). No
command was sent to the clock. It is recognised and never read as a time;
what it says is not decoded, and nothing depends on it.

## The status byte

```
bit 0  0x01  running
bit 1  0x02  the lever is up on Black's side ("right") - Black's time runs, or will
bit 2  0x04  battery low            (published; never seen set)
bit 3  0x08  Black's side to move
bit 4  0x10  White's side to move
bit 5  0x20  no clock - the reading is not valid
```

Seen: 0x10 (4 times), 0x11 (76), 0x0B (157), 0x12 (2), 0x0A (1), 0x30 (1).

- Bits 3 and 4 follow the lever when the clock is switched on and at every
  press. They do **not** follow it while the clock is paused (0x12: bit 4
  with bit 1).
- Bits 3 and 4 are about a side of the clock. A clock has no idea who is
  White; the board's socket is wired so that one side is "left" and one is
  "right", and the convention makes left White.
- **Not seen:** which side runs when a clock paused in state 0x12 is
  started again. `Protocol.reading/1` calls a clock that stands still "set
  for Black" when either bit 1 or bit 3 says so. That errs toward warning.

## Sides: there is no option

The clock stands to the **right of the board**, White's display toward
ranks 1-2. The cable is too short for it to stand anywhere else, and DGT's
own LiveChess assumes exactly that. So:

- bytes 3-5 and bit 4 are White's, bytes 0-2 and bit 3 are Black's. One
  place says so: `Alnasl.Dgt.Protocol.reading/1`;
- the `clock_white` option of the serial driver is **gone**, with the
  second argument of `reading/2`. There is no setting, and no control on
  any page, to swap the sides of a clock. A test (`board_server_test.exs`)
  fails if the word comes back;
- a clock that reads the other way round is not read the other way round.
  It is **set up wrongly**, and the box says that.

## The clock in the starting-position check

From the bits above (`Alnasl.Clock.start_check/2`, `Alnasl.Session`):

| The clock | Check |
|---|---|
| none attached, or switched off (bit 5) | no clock check, as before |
| stands still, lever up on White's side and bit 3 clear (0x10) | right |
| stands still, lever up on Black's side or bit 3 set (0x0A, 0x12) | **"Clock not in starting position: Black's side would run first - the clock is turned or the lever is the wrong way"** |
| runs on White's side before move 1 (0x11) | right |
| runs on Black's side before move 1 (0x0B) | the same sentence - and, if the pieces are in the starting position, the alarm below |

A board is "Right" on the Boards page only when pieces and clock both are.
The sentence stands beside the piece check there, on the Round tile and on
the board's own page, in English and Dutch. For a game from a set position
with Black to move, the sides are the other way round.

**The alarm.** Black's time *started* with the pieces in the starting
position and no move made is a state of its own on the tile - "Clock wrong
way" - counted with the boards that need the arbiter, and a line in the log.
It is not "Out of sync": the pieces are fine and the moves go on being
followed; it is their clock times that are the wrong way round. It clears by
itself:

- before the first move, when White's side runs, or the clock stands still
  with the lever right, or is switched off;
- after moves have been made, at the first press that leaves the running
  side equal to the side to move. A clock still turned round fails that at
  every press, so the alarm stays for as long as it is true.

Two things it is deliberately not:

- a lever **pressed** over to Black's side with the pieces untouched is not
  this alarm. That is a first move the board did not see, and the press
  counts toward "Move missing?" as before;
- a clock running the wrong way over a board that is not in the starting
  position (pieces still being set up, or a lone knight) is not an alarm
  either. The check says it in words; there is no game to go wrong yet.

## Odd things in the stream

- **Messages arrive in pieces.** The USB adapter hands over at most 16
  bytes per read, about 16 ms apart: 834 reads for 336 messages, 503 of them
  ending in the middle of a message, one of them finishing two messages at
  once. The serial number came as `91 00 08 30` + `36 33 31 30 93 ...` in
  one recording and `91 00 08 30 36 33 31` + `30 93 ...` in the other. The
  parser's buffer did what it is for; the fixtures keep the pieces as they
  came.
- **No stray bytes, no unknown ids, no damaged frame** in either recording.
  The skip-to-the-next-header path of `parse/1` has still never met a real
  line.
- **The clock sends about once a second while it changes** and not at all
  while it stands still: nothing between 6.4 s and 8.7 s. The gaps are 0.9,
  0.9, 0.9, 0.9, 1.3 s, repeating - the clock's own rhythm, not ours. A
  press shows up 0.4-0.9 s after the last tick, so a press is seen within a
  second.
- **A clock is not there until it speaks.** For the first 5.9 s the board
  said nothing about a clock at all - not "no clock". "No clock" (bit 5)
  only came when a clock that had been there went away.
- **`:eacces`, by its shadow only.** `single-1` holds two starts (`cfg`
  lines at 0 s and +20.1 s) and the first never sent a byte. After the
  second, the handshake goes out 12.4 s late - four of the driver's
  3-second retries. That is what a port held by another program looks like
  from here: `open` fails (`:eacces` on Windows), the driver reports
  `{:info, %{error: ":eacces"}}` and tries again every 3 s, and gets in when
  the other program lets go. The error itself is printed to the console and
  is not a line of the capture file, so the files do not show the word. In
  the application the Boards page says "Cannot open the port" meanwhile.
  It behaved; it is not covered by a fixture, since no byte moved.
- **The recorder kept what the old code made of it.** `clock-1.jsonl` has
  `pos` and `clk` lines beside the raw bytes, and `Recorder.read/1` prefers
  those to decoding again. They happen to be right (the side mapping did
  not change), but they carry no lever. The fixtures hold `rx`/`tx` only, so
  they are decoded by today's parser every time.

## The whole recording, played back

`Recorder.dry_run/2` on the bytes of `clock-1` (the same through the Replay
driver into a board process, in `board_server_test.exs`):

| | |
|---|---|
| readings | 332 over 4:06: 83 dumps and 8 field updates (9 positions that differ), 240 clock readings, one "no clock" |
| moves | none. One knight is not a starting position: the tracker waits ("Waiting for start", `:not_start`) through all of it, and makes nothing of the knight's four squares |
| out of sync | never |
| presses | 4 (74.8, 80.7, 85.8, 91.8 s) |
| pauses | 2 (93.1 s and 96.2 s), 1 resume (94.9 s); not counted as presses |
| clock off | once, at 99.9 s; the clock is "not attached" for the second it is gone |
| clock check at the end | **wrong: Black's side runs** - turned round and started at 103.3 s |
| clock alarm | none raised, correctly: there was never a starting position on the board. With the same clock bytes over a board in the starting position (a test does this) the alarm is raised at 103.26 s, the moment the clock is started, and not while it merely stood the wrong way from 101.0 s |
| "Move missing?" | not raised in the recording (no game). Over a starting position the second press without a move raises it at 80.7 s, which is what it is for |
| crashes, nonsense | none |

## What changed in the code

- `Alnasl.Dgt.Protocol`: the clock message decoded as `black_ms` /
  `white_ms` (was `right_ms` / `left_ms`); `reading/1` (was `reading/2`
  with a side) gives `running` and `armed`; the lever's sense corrected; a
  "no clock" message is `{:info, %{clock: false}}`; comments say CONFIRMED
  where this capture shows it, and only there.
- `Alnasl.Driver.DgtSerial`: no `clock_white`; "no clock" reported once.
- `Alnasl.Clock`: `armed`, `started`, `off/2`, `first/1`,
  `start_check/2`.
- `Alnasl.Session`: the clock alarm; a clock switched off; `clock_check/1`.
- `Alnasl.BoardServer`: the clock of a board that is not linked yet; the
  state `:clock_alarm`; `clock_check` and `clock_alarm` in the snapshot; two
  log lines.
- `Alnasl.Recorder`: `clk` lines carry the lever (`l`) and "off"; a dry run
  reports presses, switch-offs, the alarm and the check.
- The site: Boards, the Round tile, the board's page, Help, Log; a tenth
  state with its own shape; English and Dutch.
- The simulator starts the clock of the side to move (it always said
  White, also from a position with Black to move).
- `.gitattributes`: LF everywhere. Three tests read files byte for byte and
  failed on a Windows checkout with `autocrlf`.

# Capturing the DGT bus

The driver is written against a recording of a real loop first. This is how
to make one on Windows with a single serial adapter: DGT LiveChess drives the
boards as usual, and a small proxy in between passes every byte through and
writes it down.

```
LiveChess --> COM10 (virtual) <==com0com==> COM11 (virtual) --> serial_proxy.py --> COM3 (adapter) --> DGT loop
                                                                      |
                                                                capture.log
```

## What you need

- The DGT loop with 2-3 boards (and the clock, if you have one), on its usual
  cable and adapter.
- DGT LiveChess.
- **com0com** - a free, signed virtual null-modem driver for Windows: it makes
  two COM ports wired to each other. Installing a driver is a change to the
  PC; you do this step yourself.
- Python 3 with `pip install pyserial`.

## Steps

1. **Find the real port.** Plug in the loop and look in Device Manager under
   *Ports (COM & LPT)*: e.g. `COM3`. Close LiveChess.
2. **Make a virtual pair.** In com0com's setup, create a pair and rename the
   two ends to free numbers, e.g. `COM10` and `COM11`. Untick "emulate baud
   rate" (leave the defaults otherwise).
3. **Start the proxy** (from the Alnasl folder):

   ```
   py -3 tools/serial_proxy.py --app COM11 --board COM3 --out capture-1.log
   ```

4. **Point LiveChess at the other end.** Start LiveChess and connect the
   e-boards on **`COM10`**, not COM3. If LiveChess only auto-detects, let it
   scan: COM3 is busy (the proxy holds it), so it can only find the boards
   through COM10. Check that the boards show up and their positions are right.
5. **Play the script below**, typing a note into the proxy window **just
   before** each action (`Enter` sends the note; an empty line stops).
6. Stop the proxy with an empty line, close LiveChess, and keep the log.

## What to do on the boards

Type the note, then do it. Board numbers are the order in the loop.

| # | Note to type | Action |
|---|---|---|
| 1 | `start` | Boards in the starting position, nothing touched for 10 s |
| 2 | `b1 e2e4` | Board 1: 1.e4 |
| 3 | `b1 e7e5` | Board 1: 1...e5 |
| 4 | `b2 d2d4` | Board 2: 1.d4 |
| 5 | `b1 lift g1 putback` | Board 1: lift the g1 knight, put it back on g1 |
| 6 | `b1 g1f3 slow` | Board 1: Nf3, holding the knight in the air for 3 s first |
| 7 | `b2 capture` | Board 2: play to a capture, e.g. 1...e5 2.dxe5 - take the piece off first, then move |
| 8 | `b2 capture other order` | Another capture, moving first and removing the captured piece after |
| 9 | `b1 castle` | Board 1: play to castling (e.g. Bc4, Nf6, O-O) - king first, then rook |
| 10 | `b1 knock` | Board 1: knock a piece over and set it back |
| 11 | `b2 promote` | Board 2 (set up a position): a pawn promoting to a queen |
| 12 | `b3 unplug` | Unplug board 3 from the loop for 10 s, plug it back in |
| 13 | `clock` | If there is a clock: start it, press it a few times, set it running |
| 14 | `end` | Nothing touched for 10 s |

Short runs are fine: several small logs beat one long one. Put the logs in
`captures/` (one subfolder per session), together with a line on what
hardware it was (board serial numbers, RS232 or USB-C, the clock model, the
LiveChess version).

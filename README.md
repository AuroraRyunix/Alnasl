# Alnasl

**Live chess boards, from the hall to the web.**

Alnasl reads electronic chess boards in the playing hall and sends every move,
with the clock times, to the live results site as it is played. It runs on a
small box beside the boards - a Raspberry Pi with a screen, keyboard and mouse
for the arbiter - and keeps working when the hall's internet does not.

> Status: **design stage.** Nothing here runs yet. This page says what Alnasl
> is going to be, so the first code has something to be measured against.

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
                            |
                            +--> "game over, 1-0?" offered to OpenPairings;
                                 the arbiter confirms every result
```

- **OpenPairings** pairs the tournament and owns the results. It tells Alnasl
  which physical board belongs to which game of the round.
- **OpenResults** shows the games live: a board per game, the round overview,
  the hall screens.
- **Alnasl** does only the part in the hall: talk to the boards, turn what
  they report into legal moves, and get those moves to OpenResults.

Alnasl is a separate program on purpose. A board that hangs, a loose cable or
a hall without a network must never be able to touch the pairing program.

## First goal

- **DGT boards** - the RS232 and the USB-C models. Both end up as a serial
  stream, so one driver serves them.
- **One serial loop of up to 12 boards**, each with its own address on the
  bus, polled in turn.
- **Moves from positions.** A board reports where the pieces are; Alnasl works
  out the legal move - and copes with a piece lifted and put back, a capture
  in two steps, a knocked-over piece, a hand hovering over the board.
- **Clocks** from a DGT clock on the board, when there is one.
- **Offline first.** Moves are kept on the box and sent in order once the
  connection is back. A finished game is also kept as PGN on the box.
- **A local screen** for the arbiter:
  - which boards answer;
  - each board's live position, so a misbehaving board is seen at once;
  - linking board 7 to "board 7 of round 4";
  - the connection to OpenResults and how many moves are waiting.

Later: more loops per box, more makes of board (Bluetooth DGT, Millennium,
Chessnut), each as a small driver behind one interface.

## Stack

- **Elixir**, the same language as OpenPairings, OpenResults and Ainalrami.
  Serial ports through `circuits_uart`.
- **A Phoenix LiveView page** for the local screen, shown full-screen in a
  kiosk browser on the box.
- **The box:** a Raspberry Pi on Photon OS. (Nerves, which builds a ready
  Raspberry Pi image from the same Elixir code, is the fallback if a kiosk
  on Photon OS turns into a fight.)

## The board protocol

A single DGT board on its own port speaks DGT's published protocol ("send
the whole board", "send every change"). A loop of boards uses DGT's bus
mode, where every board has an address and is polled in turn; that part is
only partly public. The first piece of work is therefore a capture: a real
loop, DGT's own software driving it, and a log of the serial traffic while
moves are played, pieces lifted and one knocked over. The driver is written
and tested against that log before it ever meets a board.

## License

Apache License 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Alnasl is not affiliated with or endorsed by DGT (Digital Game Technology).
"DGT" is their trademark, used here only to say which boards Alnasl talks to.

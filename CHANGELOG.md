# Changelog

What changed in Alnasl, newest first. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and each entry is
tagged so that a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a hole closed, or judged not to be one |
| [Verified] | checked against the real thing, no code change |

A version is released when its number is in `mix.exs` **and** it has a
section here (`## [0.2.0] - 2026-11-03`): the release's page on GitHub is that
section, word for word. See [docs/releasing.md](docs/releasing.md).

## [Unreleased]

- [Feature] **After a connect code the box says which boards play in the tournament, or asks.** The first real connection left the one board in the box's own tournament, reading a game that went nowhere, with nothing saying so. Now: one tournament and an unused own tournament, and every board plays there at once (its table number is its board; a board without a number gets the next free one), said in a line under the bar with an Undo; a group of tournaments or a game under way gets "Which tables play in ...?" on Setup with ranges filled in, and a tournament can be declared to have no boards here. A board connected later joins the only linked tournament while the own one is unused.
- [Feature] **A board that plays in no linked tournament is never silent.** The bar on every page, the Boards page, the Round tiles and "Ready for round N?" say "Board 1 is not playing in ...", with a button to put it there. A game under way on it is either the pairing's game (the moves stay, under the pairing's names, and are sent in full: "these moves are board N of round R") or closed without a result and kept, the board starting fresh; either way the flash and the log say which.
- [Change] **The statuses are about the tournament in use.** The bar names OpenPairings (connected, no answer, code refused) and the results site (sending, waiting, offline, "no relay key yet") instead of one "Not set up" that read as the connection just made having failed; the unused own tournament is no longer mentioned. The Outbox has a "Linked tournaments" panel, and Setup shows a missing relay key as a warning with the action spelled out (OpenPairings, Settings, Live boards, The results site); it clears by itself at the next poll once a key arrives, a rotated key replaces the stored one, and the games recorded meanwhile are queued in full.
- [Fix] **"Send now" always answers, and says why when it cannot.** It used to flash "Trying now" whatever the state, so on a box with nothing to send it looked broken. Now a press says how much was waiting, and a moment later how much went or why not (offline, refused); a button that could do nothing is disabled with the reason beside it (nothing waiting, switched off, no code, no relay key for the tournament, a board outside, Lichess waiting for a round and a token). The Outbox says in one line that sending is automatic. OpenPairings and the results site were on by default already, and an explicit off is kept.
- [Feature] **"Live · N ms" in the bar**: the browser's connection to the box, measured every few seconds, and "Reconnecting..." when it drops.
- [Feature] **Setup, "This copy of Alnasl"**: version, how it was started, the full path of the data folder, how many boards and tournaments it knows; the Help says the table numbers are kept with the data folder and that a copy started another way has its own.

## [0.1.0] - 2026-10-12

The first release. This is everything so far, in the order it
was built; the commit messages have the long version.

- [Feature] **An installer, a portable copy and an updater.** Windows: `Alnasl-Setup.exe` (per user, no administrator, a Start menu entry and a small window that is the stop button) and a zip that installs nothing. Linux, x86_64 and arm64: one line that installs a service under `/opt/alnasl`, as its own user, in the group that may open serial ports. The program asks GitHub every half hour whether a newer version is out and says so; it downloads nothing until you say yes, tells you the size first, and refuses to restart under a game in progress unless you insist. The question can be switched off (Setup, Updates). The data is in a folder of its own that no installer, update or uninstall touches. Nothing is signed: Windows will say so, once.
- [Feature] **The switch for the hall's network is on the Setup page.** "Let other machines in the hall open this site" used to be an environment variable set before the program started, which is not something an installed program has. It needs a PIN first, and takes effect at the next start. `ALNASL_LISTEN`, where it is set, still decides.
- [Feature] **A box serves several tournaments, and OpenPairings tells it who plays.** A connect code pasted once; pairings, colours and the rate of play arrive by themselves, a round starts when it is paired, and what each board saw goes back - moves, clocks, PGN and the result on the board, which is shown there and never entered.
- [Feature] **More than one place for the games to go.** The results server, OpenPairings and a Lichess broadcast, each with its own queue, its own switch and its own line saying whether it is connected and why not.
- [Feature] **A board that runs ahead is caught up, not stopped.** Moves that went by unseen are looked for and marked - reconstructed when one line fits, guessed when several did - and a tap on a guessed move asks which it was. A move read on the square beside the right one is rewritten. A piece that leaves the board for a while is not an alarm.
- [Feature] **Which board is which.** A board is known by its serial number and keeps its table number across ports and restarts; numbering a hall by touching the boards in order, from a phone; "Ready for round N?" with the reasons when it is not.
- [Feature] **Ending a game and beginning the next** on the same board, by the arbiter or by setting the pieces up again; fast play, with a preset for games of a few minutes.
- [Feature] **The management site**: Round, a board's page with the repair tools, Boards, Outbox, PGN, Recordings, Log, Setup, Help; English and Dutch; five colour themes; a PIN for other machines.
- [Feature] **Several boards on one cable: a port is added, and that is all.** Boards, Add a board, choose the port: the box asks the port who is on it and gives every board that answers a row of its own - one board is read as one board, two or more as a loop. No bus address is asked for anywhere. A board plugged into the chain later gets its row within ten seconds; one taken off keeps its row, which says why it is silent. An older board is known by its serial number on a loop as anywhere; a newer one (firmware 4) by the number it answers to, until it has been plugged in alone once.
- [Fix] **A loop added as one board is no longer a board with a bad cable.** Every board on a loop answers a single board's questions at once, and what arrived was nonsense that now and then looked like a position. The box asks who is on the line before anything else, reads nothing when it is more than one, and says so: "More than one board answers on this port: it is a loop", with "Read it as a loop" beside it.
- [Change] **`mix alnasl.dgt --bus` is gone; `mix alnasl.loop` is the loop's tool** (`--discover`, `--watch`, `--leave`, `--probe`). It sends questions and mode switches and nothing that writes to a board or a clock.
- [Verified] **A loop of two real boards has been read** (2026-10-12: 06310 with firmware 1.9 and a newer board with firmware 4.0, on one serial line): the frames, finding the boards with no prior knowledge, who they are, what stands on each, 16 ms a question and none unanswered in three minutes through the site. Nobody was at the boards and no clock was attached: a move as it is played, a clock and more than two boards on a loop have not been seen, and the box asks for the whole board every few seconds as well, so that a move there can be late but not wrong. `docs/real-loop-2026-10-12.md` has every byte - and the one thing that went wrong, a question that made the newer board restart itself.
- [Verified] **The DGT serial driver has read one real board and clock** (2026-10-12): handshake, position, piece movements, clock. A whole game on real hardware, and a loop of several boards on one cable, have not been played yet.

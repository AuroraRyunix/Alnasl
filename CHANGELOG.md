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

Nothing has been released yet. This is everything so far, in the order it
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

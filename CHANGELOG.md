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
- [Verified] **The DGT serial driver has read one real board and clock** (2026-10-12): handshake, position, piece movements, clock. A whole game on real hardware, and a loop of several boards on one cable, have not been played yet.

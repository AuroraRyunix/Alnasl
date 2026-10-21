# Alnasl

**Live chess boards, from the hall to the web.**

Alnasl reads electronic chess boards in the playing hall and sends every move,
with the clock times, to the live results site as it is played. It runs on a
small box beside the boards - a Raspberry Pi with a screen, keyboard and mouse
for the arbiter - and keeps working when the hall's internet does not.

> Status: **first build. Everything runs on simulated boards, one real
> board has been read, and so has a real loop of two.** The tracker, the
> outbox and the management site are written and tested without hardware.
> The serial driver met a real board and clock on 2026-10-12: handshake,
> position, piece movements and the clock are confirmed
> ([docs/real-board-2026-10-12.md](docs/real-board-2026-10-12.md)). The same
> day two boards on one cable were found, named and read as a loop
> ([docs/real-loop-2026-10-12.md](docs/real-loop-2026-10-12.md)) - with
> nobody at the boards: a move on a loop, a clock on a loop and a whole
> game on any real board have not been seen yet. See
> [What is not done](#what-is-not-done) and [docs/tomorrow.md](docs/tomorrow.md).

## The name

Alnasl is γ² Sagittarii, "the arrowhead" - the point of the archer's arrow.
Its sibling [Ainalrami](https://github.com/teapot-chess/Ainalrami), the pairing
engine, is ν¹ Sagittarii, "the eye of the archer". The eye decides who plays
whom; the arrow carries the games out of the hall.

## Where it fits

```
[electronic boards] --serial--> Alnasl (in the hall)
                          |  ^   \
     who plays whom, the  |  |    \  moves, clocks - live, buffered
     round that is on     |  |     \ when offline (push only)
                          |  |      v
   what each board saw    v  |    OpenResults
                       OpenPairings  (live boards, hall screens)
```

- **OpenPairings** pairs the tournament and owns the results. Alnasl asks it
  who sits where (the board link, `docs/board-link-api.md` in OpenPairings:
  a connect code pasted once, then a poll every five seconds) and tells it
  what each board saw: moves, clocks, PGN, and the result on the board -
  shown beside the pairing there, never entered as the result.
- **OpenResults** shows the games live. Alnasl writes to its live-boards API
  (`POST /api/tournaments/:slug/live`, with a relay key) and reads nothing
  from it: the address, the tournament's short name and the relay key
  arrive over the board link.
- **Alnasl** does only the part in the hall: talk to the boards, turn what
  they report into legal moves, and get those moves out.

Alnasl always calls; nothing calls Alnasl. So the hall opens no port, and the
same box works against a hosted OpenPairings over the internet and against a
desktop copy on the same computer (`http://127.0.0.1:<port>`) with no
internet at all.

Alnasl is a separate program on purpose. A board that hangs, a loose cable or
a hall without a network must never be able to touch the pairing program.

## Several tournaments, one box

A hall has one box and often more than one tournament: tables 1-4 the Open,
5-8 the under-twelves. Each is a tournament of its own on the box, with its
own pairings, its own round in play, its own results page and its own
Lichess round.

- **A connect code** from OpenPairings (Settings, Live boards) is for one
  tournament or for a group. Paste it under Setup, Tournaments. A tournament
  added to the group later appears on the box without a new code.
- **One tournament is one tournament on the box, however many codes reach
  it.** A group's code and the tournament's own, or a desktop copy's code
  for this computer and for the hall's network, used to make two rows that
  each reported every game. The second code now makes none and says so:
  "This code reaches Open, which this box already has through ...". The
  same tournament is known by the pairing program's address and the
  tournament's id there, or - at another address of the same program - by
  the listing's version and the game ids. "Use this code for Open" moves
  the tournament to the new code (a code withdrawn and made again), boards
  and games and all; the old code goes when it reaches nothing else. A box
  that already has two rows has them made one at start-up, the later into
  the first, and the log says what moved.
- **A team event reads as matches.** The Round page puts each match's
  boards under "Match 3: Team A - Team B", in board order, with each
  player's team on the tile and the match's score as the boards saw it
  finish - labelled so; the score that counts is the arbiter's, in
  OpenPairings. Tables can keep each match together (on by default), and
  "Ready for round N?" speaks of matches. The PGN of a team game has
  `WhiteTeam`, `BlackTeam` and `Round` as `3.6`.
- **After a code the box takes the obvious step or asks one question.** One
  tournament, and the box's own tournament unused: every board the box
  knows plays there at once (its table number is its board), and the line
  under the bar says so, with an Undo. A group, or a game already under way:
  "Which tables play in ...?" right on Setup, with ranges filled in. A board
  that plays in no linked tournament is never silent: the bar, the Boards
  page, the Round tiles and "Ready for round N?" all say "Board 1 is not
  playing in ...", with a button to put it there (a game under way on it
  either becomes the pairing's game, in full, or is closed and the board
  starts fresh). A board connected later joins by itself while the own
  tournament is unused.
- **Which table plays in which tournament is said on the box**: "tables 5
  to 8" under the tournament, and table 5 is its board 1. Board numbers
  begin again in each tournament; a table number is the sticker, as before.
- **A round starts by itself** when it is paired in OpenPairings, for that
  tournament's boards and no others. "Start round N" stays as the fallback.
- **A pairing changed after the round began** reaches the box the same way.
  A board where nothing was played takes the new pairing; a game with moves
  is kept and flagged "Pairing changed", and the arbiter says whether the
  moves are the new pairing's game or the game is set aside.
- **Without OpenPairings** the box works as it did: the results page typed
  in on Setup, the names said by hand on a board's page or read from a PGN.
  That is "this box's own tournament", which is always there. The box no
  longer reads pairings from the results site.

## Install

> **Releases exist since 0.1.0 (2026-10-12)** and the download links work.
> What has and has not been tried with them is under
> [What is not done](#what-is-not-done).

Four ways. All four run the same program, keep their data in the same
kind of place, and need nothing installed first - the runtime is inside.

### Checking a download

From the next release on, every file in a release, `SHA256SUMS` included, carries signed build provenance: a GitHub artifact attestation, signed keylessly through Sigstore, so there is no key of ours to lose. With the [GitHub CLI](https://cli.github.com/):

```sh
gh attestation verify <file> --repo teapot-chess/Alnasl
sha256sum --check --ignore-missing SHA256SUMS
```

The first line says this exact file was built by this repository's release workflow. `SHA256SUMS` is attested too, so the second line is as trustworthy as the first.

### Windows

Download **[Alnasl-Setup.exe](https://github.com/teapot-chess/Alnasl/releases/latest/download/Alnasl-Setup.exe)**
and run it. It installs for you alone, asks for no administrator, puts
"Alnasl" in the Start menu and on the desktop, and starts.

**Windows will warn you, once.** Alnasl is not signed - a certificate costs
a few hundred euros a year and this project has none. So the first time,
Windows SmartScreen shows "Windows protected your PC": click **More info**,
then **Run anyway**. Your browser may also ask whether to keep the file.

What starts is a small window that says "Alnasl is running", and your
browser on `http://localhost:4040`. **The window is the program**: closing
it stops Alnasl (it asks first), and while Alnasl is stopped the boards are
not read. Minimise it instead. When something is slow or odd, **Details** in
that window shows the program's own output and a few numbers (version, how
long it has run, processor, memory, the database, boards connected, the
results relay); **Copy** puts them and the last 200 log lines on the
clipboard, ready to mail.

Rather install nothing? **[alnasl-windows-x86_64-portable.zip](https://github.com/teapot-chess/Alnasl/releases/latest/download/alnasl-windows-x86_64-portable.zip)**:
unzip it anywhere and start `Alnasl.exe` in it. (`Alnasl.bat`, beside it,
starts the same thing with a console window that shows what the program
says - for when something is wrong.) Both are a folder with a small
launcher, on purpose: antivirus has been seen to delete single-file
programs that unpack themselves, and to leave this shape alone (measured
for OpenPairings, which is packaged the same way; not yet for Alnasl).

Windows 10 or 11, 64-bit. An electronic board on USB is a COM port; see
[Serial ports](#serial-ports).

### Linux and the Raspberry Pi

```
curl -fsSL https://github.com/teapot-chess/Alnasl/releases/latest/download/install.sh | sudo sh
```

That installs Alnasl under `/opt/alnasl`, makes a system user `alnasl` in
the group `dialout` (the serial ports), and starts a service that comes up
with the box and comes back when it falls over. Then
`http://localhost:4040` on the box.

- **A box without a screen**: `... | sudo sh -s -- --lan` lets the hall's
  network in from the first start. There is no PIN yet at that moment: open
  Setup from your laptop and set one before anybody else finds the address.
- **A hall without internet**: download
  [alnasl-linux-x86_64.tar.gz](https://github.com/teapot-chess/Alnasl/releases/latest/download/alnasl-linux-x86_64.tar.gz)
  (or [`-aarch64`](https://github.com/teapot-chess/Alnasl/releases/latest/download/alnasl-linux-aarch64.tar.gz)
  for a Pi) at home, and on the box: `tar -xzf alnasl-linux-*.tar.gz && sudo sh alnasl/install.sh`.
- **Without installing**: unpack the same archive and run `alnasl/alnasl.sh`.
  `alnasl/alnasl.sh details` (`--once` for one snapshot to paste) shows what
  the Windows Details panel shows, in the terminal, for a copy started that
  way.

It needs a **64-bit** system with systemd and glibc 2.35 or newer: Debian
12, Ubuntu 22.04, Raspberry Pi OS "Bookworm" (64-bit), or later. On a 32-bit
Raspberry Pi OS the installer says so and stops; there is no 32-bit build.
`journalctl -u alnasl` is the log; `/etc/alnasl/alnasl.env` holds the port
and, if you want it fixed there, who may reach the site.

The service runs as its own user, cannot become root, and sees the system
read-only except for its data. Read `install.sh` before you pipe it into a
root shell; it is two hundred lines and says what it does at the top.

### macOS

> **New, and not yet tried on a real Mac** (2026-10-14): it is built and
> started on GitHub's Macs on every push; [docs/macos.md](docs/macos.md)
> has the test list for a person with one.

Download **[alnasl-macos-aarch64.zip](https://github.com/teapot-chess/Alnasl/releases/latest/download/alnasl-macos-aarch64.zip)**
for a Mac with an Apple chip (M1 and later), or
**[alnasl-macos-x86_64.zip](https://github.com/teapot-chess/Alnasl/releases/latest/download/alnasl-macos-x86_64.zip)**
for an Intel Mac (macOS 10.13 or newer), open it, and drag **Alnasl** into
*Applications*.

**It opens with a double-click.** The app is signed with a Developer ID and
notarised by Apple, and the notarisation ticket is stapled to it, so macOS
opens it without a question, even with no network. (A build from a fork,
which has no signing secrets, is signed ad-hoc and does ask: docs/macos.md.)

What starts is an Alnasl icon in the Dock, a small window that says
"Alnasl is running", and your browser on `http://localhost:4040`. It is an
ordinary Dock app: right-click the icon, *Options > Keep in Dock* to keep it
there; close the window and click the icon to get it back. *Stop Alnasl*,
Cmd-Q or the Dock's *Quit* stops it, and asks first, because the boards are
not read while it is stopped. *Details* (Cmd-D) opens a window with the
program's output and the same numbers as on Windows, with *Copy* and *Open
log folder*. The data is in
`~/Library/Application Support/AlnaslData`, never in the app, so replacing
the app or dragging it to the Bin leaves it alone. Updating is by hand for
now: download the new zip and put the new app in place of the old one.

An electronic board on USB is `/dev/cu.usbserial-...` or `/dev/cu.usbmodem...`;
see [Serial ports](#serial-ports). macOS 11 (Big Sur) or newer.

### From source

[Running it](#running-it), below.

### Updating

Alnasl asks GitHub every half hour whether a newer version is out - one
small request - and says so at the top of every page. That is all it does
by itself:

- **Nothing is downloaded until you say yes**, under Setup > *Updates*,
  where it first tells you how big the download is. The hall may be on
  somebody's phone.
- **It will not restart under a game.** While a board has a game in
  progress, "Download and install" refuses and says which boards; an update
  stops the program for about a minute, and moves played in that minute are
  not read. You can insist; it asks whether you are sure.
- **Later** asks again tomorrow. **Don't ask again** stops the looking;
  Setup > *Updates* switches it back on, and has "Look now" either way.
- **Offline it is silent.** No warning, no error: it asks again later.

What "install" does: on Windows the program stops, its launcher fetches the
update (the difference from your version when there is one, the whole
program otherwise) and starts the new version - or the old one again if
anything went wrong. On an installed Linux box a root-owned updater
downloads the new release, checks it against its checksum, copies the
database aside, switches, and switches back if the new version does not
answer within a minute and a half. By hand: `sudo /opt/alnasl/update.sh`
(`--version 0.3.0` for a particular one). The portable zip does not update
itself: unzip the new one beside the old.

### Where your data lives, and uninstalling without losing it

Setup, "This copy of Alnasl", shows the version, how this copy was started
(installed, service, portable, from source), the full path of its data
folder and how many boards and tournaments it knows. The boards' table
numbers are kept there per board serial number, so they survive rounds,
updates and reinstalls - and a second copy started another way on the same
computer has a data folder, boards, numbers and tournaments of its own
(from source it is `./data` in the checkout).

Never in the program's folder:

| | The program (replaced by updates, removed by uninstalling) | Your data (touched by neither) |
|---|---|---|
| Windows, installed | `%LOCALAPPDATA%\AlnaslApp` | `%LOCALAPPDATA%\AlnaslData` |
| Windows, portable zip | where you unzipped it | `%LOCALAPPDATA%\AlnaslData` |
| Linux, installed | `/opt/alnasl` | `/var/lib/alnasl` |
| Linux, `alnasl.sh`; from source in `prod` | where it is | `~/.alnasl` |

"Data" is everything: the database with your boards, games and settings,
the PGN of every game, the raw recordings, and the secrets you pasted -
relay keys, the Lichess token, connect codes. [Where the data
lives](#where-the-data-lives) has the files.

- **Uninstalling keeps it.** Windows: Settings > Apps > Alnasl > Uninstall.
  Linux: `sudo /opt/alnasl/uninstall.sh`. The program goes; the data folder
  stays, and installing again finds it. Delete the folder yourself when you
  mean to.
- **Moving to another computer**: stop Alnasl, copy the data folder to the
  same place on the new one.
- **A backup** is a copy of that folder made while Alnasl is stopped (or of
  `alnasl.db`, `alnasl.db-wal` and `alnasl.db-shm` together).
- `ALNASL_DATA` puts it somewhere else. Alnasl refuses to start if that
  somewhere is inside the program's own folder: the next update would take
  it away.

This is not an accident of layout. A sister program once kept its data in
the folder its installer owned, and an uninstall deleted a season of
tournaments. Here the two have different names, the installer script
refuses to build when they do not, and a test reads both and compares.

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

No results site is set up in the demo: the badge at the top right says
"Not set up" and the Results page shows everything being kept, which is what
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
plus "match device", chosen per device (rail, or Setup on a phone). More
themes can be dropped in as **theme packs** - a folder each, in `themes`
inside the data folder - and are offered after the built-in ones. One comes
with every build: **Toon**, a cartoon theme (a pack of your own named `toon`
replaces it). [docs/theme-packs.md](docs/theme-packs.md) has the
format, the rules a pack's stylesheet must keep, and
`mix alnasl.theme_check` for checking one.

| Page | What it is for |
|---|---|
| **Live** | The screen during play. A tile per board: players, the position Alnasl is sure of, clocks, last move, and the state as a shape and a word - Live, Waiting for start, Settling, Reconstructed, Out of sync, No signal, Clock wrong way, Finished - with a count of the moves that were reconstructed or guessed, and a warning for a piece that is not seen. Before the first move a tile also says, in words, when the clock is not set for White. A tile is the way to the board's own page; under it, "Finish game" (the three results, or none) and "New game". Fetch the pairings, start the next round. With a results site: "Open the results site" (the live boards of the round, in a new tab), a "QR" of its live page, and a "Live page" link under each tile |
| **A board** | The position large, the move list - Left and Right step through it - and, when board and game have parted ways, what the board reads beside what is certain. Moves the box worked out are marked, and a tap on a guessed one asks which line it was. "This game": finish it with a result or without, start a new game on the board, and the games the board has seen this round with their PGN. The repair tools: "the board is right" (search deeper), type moves, undo, change a move, start from a FEN, pause and resume sending, turn the board round |
| **Boards** | What is plugged in. Add an electronic board or a simulator; connect and disconnect; each board's live picture, signal quality, serial number and firmware; the start-position check, pieces and clock ("black queen and black king are swapped (d8, e8)", "Clock not in starting position: Black's side would run first - the clock is turned or the lever is the wrong way"); each board's **table number** and its board of the round; "Which board is this?"; "Ready for round N?" with the reasons when it is not (the clock among them); the address and QR code for a phone; a printable sheet of labels. See [Which board is which](#which-board-is-which) |
| **Number / Find** | Two phone-sized pages under Boards: number the boards of a hall by touching them in order (a piece lifted or put down counts, a clock lever does not), and find out which board the one in front of you is |
| **Results** | The connections, honestly: for the results site and for every other destination, connected or not, last success, how much is waiting and why it is not going, in words; each with its own switch and its own "Send now". What waits, what the server refused, what went out |
| **Games** | Read PGN files or pasted moves (checked for legality). Play a game on a simulator board; attach a game that was not captured to its board, after asking; compare a scoresheet with the captured game (the first difference). Export a game or the whole round |
| **Recordings** | The raw captures per board. Replay one through the tracker as a dry run (what it makes of it, where it lost the thread); export it as a test fixture; download it |
| **Log** | What happened, in sentences, with filters: board connected, moves recovered, out of sync, repaired by the arbiter, offline, back |
| **Setup** | The **Setup wizard** comes first: it asks what the hall looks like (one hall and one tournament, several tournaments, several halls or rooms), how many Arkab bridges, roughly how many boards and what else is wanted, then lists the steps for that hall and ticks each one by what is really there. Then: this copy (version, how started, data folder); Tournaments: a connect code from OpenPairings (pasted once, never shown again), what each tournament came with, which tables play in it, "Test connection" that really asks and explains failures - a wrong code, a withdrawn one, nobody home, a tournament that is not published; for a box without OpenPairings the results site, tournament and relay key typed in; a Lichess broadcast round and its token per tournament, with a test of its own; the box's name, language, round; a PIN for other machines and the address they open; the tracker's timings, with "Bullet / fast play" for games of a few minutes or less |
| **Help** | The manual, in English and Dutch: seven chapters from getting started to troubleshooting, with a search, and a small *?* on every page that opens the section about it. The chapters are `priv/manual/*.md` (Dutch in `priv/manual/nl/`) |

A banner on every page says so when the results site cannot be reached.

Boards in another hall, or on a Raspberry Pi in the next room, come in
through **Arkab**: a small bridge program beside those boards that sends
their moves here over an outgoing connection. Here, go to Halls, the hall,
its **Bridges** tab and "Add a bridge"; paste the link on Arkab's page, or
scan its code. The hosted server has no boards of its own and takes bridges
only. [docs/glossary.md](docs/glossary.md) has the names in both languages.

## Which board is which

Twelve boards look alike, and so do twelve cables. Alnasl keeps three things
apart, and the Boards page shows all three:

1. **Which board it is.** An electronic board reports its serial number (it is also
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
   is touched and the mismatch is listed. (A simulator is known by its
   slot. A board on a loop: see [Boards on a loop](#boards-on-a-loop).)
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
board beep or blink: no board command for that is sent, because none was
verified.

**Ready for round N?** is one list before the round: two boards with the
same number, a board of the round without a board, a board without a number,
the same serial seen twice (the same board on two ports, two adapters on one
loop), a board that does not answer, a starting position that is wrong
(colours swapped, king and queen), a clock that is not in its starting
position ("Clock not in starting position: Black's side would run first..."
- only for a board that has a clock), a board plugged in turned round
(noticed and read the other way up - mentioned, not held against you).

### Boards on a loop

Several electronic boards chained on one serial cable are one port to the box.
**Add a board, choose the port, press Add**: the box asks the port who is
on it (some three seconds) and every board that answers gets a row of its
own. There is no "bus address" to type and no kind to choose - one board
is read as one board, two or more as a loop.

- A board plugged into the chain later gets its row within ten seconds,
  and the log says so. A board taken off keeps its row, which says "No
  signal" and why, and is back when the board is.
- A port that was added when one board was on it, and has several now,
  says so on its row - "More than one board answers on this port: it is a
  loop" - with one button, "Read it as a loop". Until then nothing is read
  from it: every board would answer every question at once.
- The older boards (firmware 1.x) are known by their serial number on a
  loop like anywhere else, with their table numbers. A newer one is shown
  by the number it answers to ("answers as 12799", small print) until it
  has been plugged into a port of its own once; from then on the box knows
  its serial number on a loop too.
- `mix alnasl.loop --port COM5 --discover` does the asking from a command
  line and prints every byte; `--watch` reads the loop for a minute.
  That is for a checkout: an installed copy has no `mix`. There the Boards
  page is the discovery - Add a board asks the port exactly this - and
  everything it needs (`Arkab.Dgt.Loop`, the bus driver, the serial
  program) is in the release.

### With your phone

The numbering is meant to be done walking: the two pages are built for a
phone held in one hand.

1. In Setup, *Access from other machines*: **set a PIN**, then "Let other
   machines in the hall open this site", and start Alnasl again - before
   the hall fills up. The switch wants the PIN first: without one, anybody
   on the hall's network who finds the address could renumber your boards.
   (`ALNASL_LISTEN=lan` in the environment does the same and overrules the
   switch.) On Windows, the first time, the firewall asks whether the
   program may be reached; say yes for private networks.
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

The results site is one destination. There can be more, and they do not
wait for each other: each has its own queue, its own pause after a failure,
its own line on the Results page (connected or not, last success, how many
wait, the last error in words), its own switch and its own "Send now".

| Destination | What it gets | Its place in the queue |
|---|---|---|
| **Results server** (OpenResults) | every change as a message of its own: the whole game so far, with the clock | the row of the outbox it has got to |
| **OpenPairings** | each game of a linked tournament as it stands, whenever anything but the clock changed: moves, clocks, PGN, the result the board saw, how many moves were reconstructed or guessed | per game, the game's change counter at the last report that was answered |
| **Lichess broadcast** | the PGN of each game of one round as it stands, whenever it changed | per game, the game's change counter at the last push Lichess answered for |

Each game goes to the places of **its own tournament**: that tournament's
results page with that tournament's relay key, that tournament's Lichess
round, the OpenPairings it came from. A tournament whose key is refused, or
which is not published yet, holds up nobody else's.

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

### The link, end to end

`mix test` uses a stand-in for OpenPairings. To run the link against the
real one - before a release, or after either side changed the board link -
you need an OpenPairings checkout whose development database may be thrown
away (a `git worktree` of it is the easy way), with its dependencies
fetched:

    OPENPAIRINGS_DIR=/path/to/scratch/openpairings sh tools/link_e2e_run.sh

That deletes and recreates that checkout's dev database, serves it on
`PORT` (4061), makes an arbiter, three tournaments and two connect codes in
it (`tools/link_e2e_openpairings.exs seed`), runs `mix alnasl.link_e2e`
against it with simulated boards - on port 4046, with its own data
directory `data/link-e2e` - and stops and cleans up afterwards. It takes
about two minutes and ends in `PASS: 33/33 checks.` or says which failed.
`OPENPAIRINGS_BUILD_PATH` and `OPENPAIRINGS_DEPS_PATH` set that checkout's
`MIX_BUILD_PATH` and `MIX_DEPS_PATH` when it needs its own.

Against an OpenPairings that is already running somewhere, with a person
playing the arbiter: `mix alnasl.link_e2e --code "<connect code>"` says at
each step what to do in OpenPairings and waits for it (see `mix help
alnasl.link_e2e`).

It is not part of `mix test` and does not run in CI: it needs two programs,
two ports and both sets of dependencies.

### From source on the box (Raspberry Pi, Linux)

[Install](#install) is the short way. This is the long one, for a system
the release was not built for, or to run a version nobody has released:

```
sudo apt install elixir erlang build-essential   # or asdf/mise for a newer Elixir
git clone https://github.com/teapot-chess/Alnasl && cd Alnasl
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

To run a build of your own as the installed service does: `MIX_ENV=prod
mix release alnasl`, then `sudo sh _build/prod/rel/alnasl/install.sh` - the
release carries the installer, the updater and the systemd units
(`rel/linux/`). A ready-made image for the Pi is not part of this build.
[docs/releasing.md](docs/releasing.md) has how a release is made.

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4040` | The port of the management site |
| `ALNASL_LISTEN` | (unset: the switch on Setup decides, and a new box answers only itself) | `lan` to let other machines in the hall reach the site - the arbiter's laptop, and the phone the boards are numbered with; `local` to forbid it. Set, it overrules the switch. Set a PIN when you open it |
| `ALNASL_DATA` | `./data` (dev); installed or `prod`: see [Where your data lives](#where-your-data-lives-and-uninstalling-without-losing-it) | Where everything is kept. Refused when it is inside the program's own folder |
| `ALNASL_THEMES_DIR` | `<ALNASL_DATA>/themes` | Where theme packs are read from ([docs/theme-packs.md](docs/theme-packs.md)). Nothing is there unless somebody puts it there |
| `ALNASL_UART` | on for Linux/macOS, off for Windows | `1` / `0`: build the serial library or not |
| `ALNASL_NO_LOCAL_BOARDS` | (unset: a box with ports) | `true`: a server that reads no boards of its own and takes bridges only. Every page asks who is there, always, and accounts come by invitation |
| `ALNASL_ADMIN_EMAILS` | (none) | Comma-separated addresses that are admins: every hall and the box itself. On the server they sign in with 02cloud before any account exists; optional on a box |
| `ALNASL_KEYCLOAK_CLIENT_SECRET` | (unset: no 02cloud button) | **Secret.** The client secret of the Keycloak client; set, the sign-in page offers "Sign in with 02cloud" |
| `ALNASL_KEYCLOAK_URL` | `https://auth.zerotwo.cloud` | Keycloak's base address |
| `ALNASL_KEYCLOAK_REALM` | `zerotwo` | The realm |
| `ALNASL_KEYCLOAK_CLIENT_ID` | `alnasl` | The client |
| `ALNASL_KEYCLOAK_REDIRECT_URI` | (the address the browser used, `/auth/keycloak/callback`) | Pin the redirect address when a proxy hides the real one |

Everything else is set on the Setup page and stored in the database.

### Where the data lives

One directory (`ALNASL_DATA`):

```
alnasl.db                      settings, boards, games, the outbox, the log (SQLite, WAL, fsync on commit)
captures/board-<id>/*.jsonl    everything every board delivered, raw: always on, nothing to switch (rotated at 8 MB, capped in Setup)
pgn/round-<r>/board-<n>.pgn    every game as PGN with clock times, rewritten on every move
fixtures/*.jsonl               captures exported as test fixtures
themes/<id>/                   theme packs of your own, if you installed any (never created by the box)
secret_key_base                the cookie-signing secret, made on first start (installed and prod)
listen                         "lan" or "local": Setup's switch for the hall's network
launcher.log                   Windows: what the program said when it last started
run/launcher.token             the Details secret of a copy that no launcher started; removed on a clean stop
tmp/                           Windows: what the runtime writes when it starts
update/                        Linux, installed: where "Download and install" leaves its request
backups/before-<version>-*/    Linux, installed: the database as it was before each update (never pruned)
```

A real board is recorded from the moment it is connected, linked to a
round or not: every byte in both directions (`rx`/`tx`), every position
and clock reading made of them, with wall-clock milliseconds. The file is
`<ALNASL_DATA>/captures/board-<id>/<UTC date>-<time>.jsonl` - `./data/...`
from `mix phx.server`, `/var/lib/alnasl/...` on an installed box, `%LOCALAPPDATA%\AlnaslData\...` on Windows. The Recordings page
lists, replays and downloads them; at a desk it is

```
mix alnasl.replay data/captures/board-3/20261012-101500.jsonl --timeline
mix alnasl.replay data/captures/board-3/20261012-101500.jsonl --settle 150 --depth 3
```

which plays the file through a fresh tracker (with other settings, if you
want to know what they would have made of it) and saves nothing.

### Serial ports

An electronic board is a serial port to the system: `/dev/ttyUSB0` or `/dev/ttyACM0`
on Linux (the user needs to be in the `dialout` group), `COM3` and the like
on Windows (Device Manager, *Ports (COM & LPT)*), `/dev/cu.usbserial-...` or
`/dev/cu.usbmodem...` on a Mac. 9600 baud, 8N1.

A Mac lists every adapter twice, as `/dev/tty.X` and `/dev/cu.X`; the `tty.`
one waits for a modem signal a board never sends, so Alnasl offers only the
`cu.` one. No permission is needed for a serial port on a Mac, but an
RS232 board's USB adapter needs a driver macOS has. Adapters with an FTDI
chip work as they are (macOS carries that driver); Prolific (PL2303),
WCH (CH340/CH341) and Silicon Labs (CP210x) adapters may need the chip
maker's driver, depending on the adapter and the macOS version. If the
board is plugged in and no `cu.` port appears, that is the driver.
`ls /dev/cu.*` in Terminal shows what macOS sees.

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
  mix alnasl.loop --port COM5 --discover
  ```

  (PowerShell: `$env:ALNASL_UART = "1"` and so on.) Verified on this
  project's Windows 11 machine: with those three variables the library
  builds and loads; without them the build stops in `make` on the space.

Without the library everything works except opening a real port: the Boards
page says so, and simulator boards are unaffected.

One program at a time can have a port. The board maker's own software holds the ports of
the boards it shows: close it before the box reads them, and stop the box
before LiveChess does. The box leaves the boards as LiveChess expects them
("end bus mode" is the last thing it says on a loop).

## How it works, in short

[docs/design.md](docs/design.md) is the long version.

- **A driver delivers whole positions**, not moves: 64 squares, each a piece
  or empty, every time anything changes. `Simulator` (PGN games played by an
  invisible hand, with faults), `Replay` (a capture file), `DgtSerial` (one
  electronic board), `DgtBus` (a loop of them). Which of the two a port needs is
  found out by asking the port.
- **The tracker turns positions into moves.** It keeps the last *certain*
  position. A board one legal move away is that move, once it has stood
  still for a moment (or at once on a clock press).
- **A board that has run ahead is caught up, not stopped.** When the board
  is further from the game than one move, the box looks for the legal moves
  in between - first among the squares it saw change, then among all of
  them - takes what it finds and marks it: **reconstructed** (orange, a
  diamond) when one line of moves fits, **guessed** (red, a question mark)
  when several did and one was taken, by the clock's press count, the order
  the readings show, and a fixed tie-break. It also asks whether a move it
  already has was misread - a pawn set down between d3 and d4, read on d3,
  that then takes on e5 - and rewrites that move ("read as d3" beside it)
  rather than invent moves to make the board fit. It never adds more moves
  than the clock was pressed for. And it never moves a piece the readings
  did not see leave its square, nor one out and straight back: a board
  that stayed connected is not explained by moves nobody saw. When what
  it shows is one move by the side that is not to move, or one piece gone
  where it cannot go, the alarm says exactly that - "Black moved (Nc6),
  but it is White's turn", "A move that is not legal: white bishop c1-g5"
  - adds nothing to the game, and is gone when the piece is back. The marks are on the moves, on
  the Round tile and in the Boards list, and in the log. A tap on a red
  move asks which line it was, one move at a time, each option on a small
  board. Only when no line of legal moves leads to the board does it go
  "Out of sync" - and it comes back by itself the moment the pieces make
  sense again.
- **A piece that leaves the board is not a reason to stop.** A player parks
  a knight beside the board, or a sensor loses a piece: when one piece (never
  a king) is gone from its square and the game goes on around it, it is
  taken to stand there still. The moves are followed as plain moves, and the
  board's page, the Round tile and the Boards list say "White knight not
  seen on f3" until it is seen there again, moves from there, or is taken
  there. Anything that cannot be so with the piece on its square is the
  alarm it always was. A switch in Setup, on by default.
- **The outbox sends, and never loses.** Every change is written to SQLite
  first, numbered per game, then sent in order with the relay key. Each
  message is the whole game so far, which is the server's own rule and what
  makes a retry harmless. Offline for hours is normal.
- **More than one destination.** The results site is one; a Lichess
  broadcast is another; the pairing program a third (`Alnasl.Destination`).
  Each keeps its own place in the queue and its own sender, so one being
  down never holds up another.
- **The pairings are asked for, not typed.** `Alnasl.OpenPairings` polls
  the pairing program's listing with its `ETag` and fetches a tournament
  when its version changed; the answer is kept, so the box knows who plays
  with the network gone. `current_round` moving is what starts a round.
- **Everything is recorded raw**, per board, so a game can be rebuilt and a
  failure in a hall replayed at a desk.
- **A result is never final without the arbiter.** Mate on the board, or
  the kings set in the centre, is a suggestion.

## What is proven, and how

By `mix test` (695 tests), three tools, three sessions with a real board and
one with a real loop:

**The link, end to end against the real OpenPairings** (`mix
alnasl.link_e2e`, run on 2026-10-12 against a scratch copy of OpenPairings
on a throwaway database - once at its main, commit `b868fee0`, and once
with the changes to `current_round` and the `rewritten` count that came
out of it): 33 checks. A group code and a code for one tournament are
accepted; three tournaments arrive with players, round 1 and the rate of
play; tables 1-2 and 3-4 become two tournaments' boards 1-2 with their own
names; four simulated games are reported and OpenPairings holds each with
its moves, "finished" and the result the board saw, beside an arbiter's
result that is still empty; round 2 paired there starts here for that
tournament and no other; a result cleared in round 1 does not walk the
boards back; two players swapped under games with moves flags both, and
both of the arbiter's answers go through; a tournament added to the group
appears; the code works through `http://127.0.0.1`; the code withdrawn
stops the box asking, in words. How to run it is under "Running it".

**The link with OpenPairings**, against `Alnasl.FakeOpenPairings` - a
pairing program written from the contract, not from OpenPairings' code, and
not OpenPairings: reading a connect code; the poll and its `ETag` (an
unchanged listing is one request and no document); a group code and a
tournament that joins the group later; a tournament that leaves; a code
withdrawn (asked no more), nobody home (the document is kept), another
program on the port; a round paired there starting here for one
tournament's boards and no other's, and not walking the boards back; a
pairing changed with and without moves on the board, a game moved to
another board number, the two answers of the arbiter; the report of a game,
`seq` with its duplicate and stale answers, the queue through an outage;
each tournament's games to its own results page and Lichess round; the
migration from a box with one tournament in its settings, on a database of
its own; a team event (boards by match, tables kept together by match even
when the round is numbered otherwise, the ready list by match, the team
tags, each destination's key); two codes for one tournament (a group's and
its own in either order, a tournament joining a group later, two addresses
of one program, a late match by game id, "use this code", a row its old
code stops listing, and two rows made one at start-up).

**The tracker**, against 69 games (59 classics before 1930, 7 constructed
for underpromotion and en passant, 3 more; 4599 plies) played through the
simulator under each fault mix, three passes each (`mix alnasl.bench
--passes 3`, 207 games a row):

| fault mix | every move seen | reconstructed (orange): right / wrong | guessed (red): right / wrong | alarm | **wrong, unmarked** |
|---|---|---|---|---|---|
| clean; hover, lift, knock, swap, missing clock presses, pawn left for a queen, takebacks, slides - each alone at 20-30%, and all together | 207 of 207, every row; **no alarm, no mark** | - | - | 0 | **0** |
| a piece not seen where it stands for 1-5 plies (5% of plies): alone, without a clock, and with the benign faults at 5% each | 207 of 207, every row | - | - | 0 | **0** |
| a piece set down between two squares and read on the wrong one (5% of quiet moves) | 77 (it never happened) | 80 / 5 | 18 / 9 | 2 | **0**, and 16 where the board never contradicted itself (see below) |
| the same, no clock | 77 | - | 98 / 14 | 2 | **0**, and 16 |
| one ply at a time unseen (10%) | 6 | 195 / 1 | 4 / 1 | 0 | **0** |
| the same, with the other faults at 5% | 11 | 193 / 0 | 3 / 0 | 0 | **0** |
| unplugged for 2 plies, twice | 0 | - | 204 / 3 | 0 | **0** |
| up to 3 plies in a row unseen (25%) | 0 | 37 / 2 | 41 / 18 | 109 | **0** |
| unplugged for 3 plies | 0 | 0 / 3 | 162 / 41 | 1 | **0** |
| unplugged for 8 plies | 0 | - | 9 / 75 | 123 | **0** |
| a move out of turn at ply 12, left standing 4-10 s and taken back | 207, the alarm named in 195 | - | - | 0 at the end | **0** |
| an illegal move at ply 12, taken back the same way | 207, the alarm named in 203 | - | - | 0 at the end | **0** |
| an illegal move at ply 12, played on | - | 0 / 12 | 0 / 10 | 185; named first in 206 | **0** |
| bullet speed (a move every 0.3-2 s, the clock a second late), no faults; defaults, and "Bullet / fast play" | 206, both | 1 / 0, both | - | 0 | **0** |
| bullet with slammed and knocked-over pieces, 6% of plies unseen, 10% of presses unreported; "Bullet / fast play" | 24 | 180 / 0 | 2 / 1 | 0 | **0** |

A game is counted once, by the worst thing in it: "guessed, wrong" is a
game in which the first move that differs from the game played is a red
one. Read the hard rows for what they are.

- With one ply at a time unseen, or the cable out for two, the box
  finishes 199-204 games in 207 by itself; the 1-3 it gets wrong are the
  positions two different pairs of moves lead to, marked red.
- **A move misread** is found out when a later move makes no sense with
  the piece where it was read, and rewritten: 98 of the 130 games it
  happened in end right. In 14 the box picked the wrong neighbouring
  square or the wrong moment (marked), 2 end in the alarm, and in 16
  nothing the board ever read contradicts the move as it read it - a queen
  read on c1 that was on d1 and went on to c2 from either. Those 16 are
  wrong and unmarked, and no reading tells them from the game played: the
  board said so. They are counted apart, not as silence.
- **The box no longer adds more moves than the clock was pressed for.**
  That is why, with a quarter of all plies unseen (and their presses with
  them, which the box cannot know), half the games now end in the alarm
  where they used to end as a guess: 22 wrong guesses instead of 83, 104
  alarms instead of 4. Fewer wrong red moves, fewer right ones, and an
  arbiter asked. A board whose cable was out is not held to the clock
  (it was not heard either), so those rows are as they were.
- With three plies or more unseen and nothing read of them, a red move is
  still wrong about as often as right, because the order of two moves
  nobody read is a coin toss; and an orange one is wrong in 1-3 games in
  207, where two moves explain a board that three made.
- **A move out of turn, or a move no rule allows, taken back** is said by
  name ("Black moved (Nc6), but it is White's turn", "A move that is not
  legal: white bishop c1-g5") while it stands, adds nothing to the game,
  and leaves the game whole when the piece is back: 207 of 207, both rows.
  (The few games where the alarm is not named are a "move out of turn"
  that undoes the move just made, which is a takeback and read as one, and
  an illegal move that a neighbouring-square misread explains for the
  seconds it stands - put right the moment the piece goes back.)
- **An illegal move played on** is named first in 206 games of 207 and is
  the alarm at the end in 185. In 22 the game that follows is still
  explained: 12 as "the move before was one square off" (orange), 10 red.
  A piece that moved a moment ago and now moves as it could only from the
  square beside is, to a board, the same thing as a misread; the rewrite
  that reads the real misread on board 06310 is what reads these. Not
  fixed, and counted.
- **No phantoms.** A reconstructed line only moves pieces the readings saw
  leave their squares, and never a piece out and straight back. For the
  rows where plies go unread this changes little - a ply nobody read
  still empties its square - and costs one game in 621: a king stepping
  out of a check and back (Torre's windmill), where the true line *is* an
  out-and-back and the box takes another, marked orange. Where the cable
  was out, everything found is now red, right or not (204 and 162 games
  that were orange): across a hole in contact nothing is vouched for.

That is the limit of reading a game from positions, `docs/design.md` says
exactly where it lies, and the marks are how the box says it too.

The tests assert the last column on every row, the first on the first two
rows, and that no orange move is wrong where at most two plies went by
unseen.

The search is bounded: 8 plies among the squares that were seen to change
(4 ms on average at six plies, about 0.1 s at eight), 4 plies among all
moves (20 ms on average), and a budget of nodes and of time after which it
gives up and says so: half a second at most by itself, which is also the
worst single search in the fault matrix.

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

**The serial driver, against a real board** (serial 06310, firmware
1.9, with a clock; recorded 2026-10-12, decoded message by message in
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

**A loop of two real boards** (06310 and a newer board with firmware 4.0
on one serial line, no clocks, nobody at the boards; recorded 2026-10-12,
[docs/real-loop-2026-10-12.md](docs/real-loop-2026-10-12.md), fixtures
`real-loop-*.jsonl`, `test/alnasl/real_loop_test.exs`). Confirmed by those
recordings:

- the frames: a four-byte command with the board's address, an answer with
  its size, the address and a checksum; every command the driver sends;
- finding the boards with no prior knowledge: a ping to everybody, each
  board answering after a wait of its own (26 to 1020 ms), told to sit out
  the next one so that the others are heard; one real collision, and what
  it looks like;
- who they are: firmware 1.9 and 4.0, and that 06310 answers as 6310 - its
  serial number - while the newer board's address is not its serial number;
- what stands on each: the 64 squares of both, and that the squares each
  board wrote in its own memory add up to that position;
- that a loop treated as one board answers every command twice at once -
  what the owner saw - and that the single-board driver now sees a loop
  for what it is before it asks anything;
- the pace: 16 ms for a question that has "nothing changed" for an answer,
  3553 of them in 64 seconds through the real driver, none unanswered; the
  site reading both boards for four minutes without losing either.

NOT seen on a real loop, because nobody was there: a move as it is played,
a clock, more than two boards. The driver's handling of those is tested
against an emulator that answers as the two real boards did.

**The tracker, against a game on that board** (2026-10-11, fixtures
`real-06310-unseen-knight.jsonl`, `real-06310-castling-after-set.jsonl`,
and from the day after `real-06310-misread-pawn.jsonl`):

- a real game followed from the starting position with the clock: 1. d4 d5
  2. Nc3 Nf6 3. Nf3, each move confirmed by its press;
- the knight then taken off f3 and parked beside the board for five moves,
  and brought down on e5. As recorded, the tracker waited for it and went
  out of sync six plies behind; with the rule above it reads 3... Nc6
  4. Be3 e6 5. Qc1 Bb4 6. Ne5 Bd7 7. Qd2, no alarm
  (`test/alnasl/unseen_piece_test.exs`);
- a position set by hand from the board mid-game, after which Black
  castled short and White long, king first. As recorded both were out of
  sync: the FEN offered for a bare board said nobody could castle. It now
  offers every right whose king and rook stand at home, and the side to
  move from the clock (`test/alnasl/position_set_by_hand_test.exs`).

- 1. e4, a twenty-four minute think, 1...e5, and then Black's knight to c6
  as well, taken back, and a bishop put through its own pawn to g5, taken
  back (`real-06310-out-of-turn.jsonl`). As recorded, the box made
  `2. Ba6 Nc6 3. Bf1` of the knight: a bishop that never left f1, out and
  back, so that Black could move twice. It now reads `1. e4 e5`, no mark
  on either, with the two things it saw in the log by name
  (`test/alnasl/no_phantoms_test.exs`);
- a pawn set down between d3 and d4 on purpose, read on d3, that then
  took on e5. As recorded, the reconstruction made `3. d3 e5 4. d4 Ba3
  5. dxe5 Bf8` of it - ten moves to seven presses of the clock, and a
  bishop that never moved. It now reads `3. d4 e5 4. dxe5`, the third
  move marked "read as d3" (`test/alnasl/misread_move_test.exs`). That
  morning "Check them" also did nothing when tapped; it now always opens
  the question, or says that there is no other line and what can be done
  instead (`test/alnasl_web/live/review_test.exs`).

Two things the first recording corrected: the lever is up on the side whose time
*runs* (the code had it the other way, in a fallback that was never
reached), and a "no clock" message was dropped when a recording was
replayed from its bytes.

The same drivers are also run, byte for byte, against emulated boards built
from the protocol description and from those recordings - which proves
driver and emulator agree with each other, and is how the clock check and
the clock alarm are tested with the pieces in the starting position.

**The site**: LiveView tests of every page's main actions; an accessibility
pass that computes the contrast of every text pairing of the colour tokens
(all above 4.5:1, in every theme) and checks structure, labels
and names on every page in both languages.

## What is not done

- **The link has met OpenPairings at a desk, not in a hall.** `mix
  alnasl.link_e2e` (below) runs it against a real OpenPairings with
  simulated boards; no hall, no real board, no hosted server over the
  internet, and no tournament that was published to a results site (the
  results page and relay key arriving over the link are tested against the
  stand-in only). A desktop copy of OpenPairings in its own "local" mode
  was not started either: its address shape (`http://127.0.0.1:<port>`,
  plain http) was used against a development server on this machine.
- **The QR code of a connect code cannot be scanned by the box's own
  page.** A browser lends its camera only to a page served over https (or
  from the same machine), and the box is plain http on the hall's network.
  So: the phone's own camera reads the QR, the link it shows is copied
  instead of opened, and pasted. A photo decoded on the box, or the box
  serving https, would lift that; neither is built.
- **A box elsewhere on the LAN cannot use a desktop OpenPairings.** The
  desktop copy answers on its own computer only; that is its decision, and
  the box says so when such a code gets no answer.
- **No real team event has been played through the box.** Matches on the
  Round page, tables kept together by match, the team tags in the PGN and
  what goes to each destination are built from the contract and tested
  against the fake pairing program; neither a real OpenPairings team event
  nor a results site showing one has been looked at with it. The match
  score is the boards' view only.
- **Two codes for one tournament are recognised by what the contract
  gives**: the address and the id, or the same id with the same version or
  a shared game id at another address. A tournament reached at two
  addresses that is never paired and never agrees on a version at the
  moment of a listing would still make two rows until its first round.
- **Chess960 from the pairing program is not started.** The round's drawn
  position arrives and is ignored (see below).

- **Twenty moves have been played on a real board**, not a game: one
  capture, no promotion, no en passant, and castling only after a
  position set by hand. The clock's battery-low bit and the flag bits
  beside the hours were never set; a board lying the other way round was
  not tried. Next session: [docs/tomorrow.md](docs/tomorrow.md).
- **One game of a board is sent; the others stay on the box.** The results
  server and Lichess know a game by round and board, and OpenPairings by its
  pairing - one game each, so one game of a board is sent; the others are in
  the PGN export and on the board's page. Where a pairing names the board
  and its game has no result, "New game" makes the new game the one that
  is sent and keeps the old one at home; where the game has a result, the
  new game is an extra one that stays (the page offers to let it replace the
  pairing's game on purpose). A live game that stays on the box says so on
  its tile, its page and on the Results page, with "Send this one instead".
  Nobody has pressed this at a real results site or a real OpenPairings yet:
  it is tested against fakes of both.
  The reconstruction, the choice of line and "New game" have been used in
  the simulator and in tests, not yet by a person at a real board.
- **A loop has been read, not played on.** Two real boards on one cable
  were found, named and read (see above); nobody moved a piece and no clock
  was attached. That a move comes out of the next "what changed?" is what
  the protocol text and the boards' own memories say, and the driver asks for the
  whole board every few seconds besides, so that a move on a loop can be
  late but not wrong. Help says so; nothing on the Boards page calls a loop
  "not verified" any more.
- **A newer electronic board does not say its serial number on a loop.** Board
  06310 (firmware 1.9) answers as 6310, which is its serial number. The
  board with firmware 4.0 answers as 12799, which is not: it is known by
  that number until it has been plugged in alone once. Whether two such
  boards on one loop answer to different numbers is not known.
- **Reading a serial number on a loop is not attempted.** A single-board
  command on a loop is answered by every board at once; one sent into the
  middle of a bus answer made the newer board restart itself (it wrote that
  in its memory, and went on). The drivers send none where more than one
  board answered.
- **The result gesture** (kings in the centre: both on light squares = 1-0,
  both on dark = 0-1, one on each = draw) is how the board maker's own software is understood
  to work, not something read in a specification. It is only ever a
  suggestion.
- **No clock commands** are sent (nothing is written to the clock's
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
- **Three or more moves unseen in a row**, with nothing read of them, are
  reconstructed with a mark that is wrong about as often as right where
  two moves could have been played in either order (see the table). The
  clock's press count is used against the other failure - two moves
  explaining what three made - but the simulator does not press for a
  move it hides, so that rule is tested by hand, not by the matrix.
- **A piece that stands crooked and is found out by another piece's
  move** is carried as "read on d3, standing on c4" and followed one move
  at a time; the search for several unseen moves does not know about it
  until it has moved or been straightened. Tested in the simulator, never
  seen on a real board.
- **Marks are not kept across a choice of line forever**: the alternatives
  for a red move are searched for again when asked, from the game as
  stored, without the readings that ranked them the first time.
- **Bullet on a real board has not been played.** The fast-play rules and
  numbers come from the simulator (`docs/design.md`, "Fast play"). How a
  real board's scan reads a slammed or toppled piece is not known; the
  recording of the session will say.
- **No visual check in a browser by a person** was part of this build; two
  screenshots were taken headless. Colour-blind safety rests on shapes and
  words, which the tests check exist and differ, not on anybody looking.
- **The installers have been used once, on one Windows PC.** The release
  workflow has run and published 0.1.0 to 0.1.2 for all three targets. One
  Windows PC installed 0.1.0 with `Alnasl-Setup.exe` and took the update to
  0.1.1 from the Setup page; its board and its tournament link were still
  there afterwards. Not watched by anybody: uninstalling (the data must
  stay), reinstalling, the fallback when an update fails, the portable zip,
  and everything on Linux - `install.sh`, `update.sh` and the systemd units
  have been read by a shell's syntax check and by nobody's Raspberry Pi.
  [docs/releasing.md](docs/releasing.md) lists what is still to prove, one
  line a claim.
- **Nothing is signed.** No code-signing certificate: Windows SmartScreen
  warns on first run, and some antivirus may want convincing. The Linux
  download is checked against a checksum from the same place it came from,
  which catches a broken download and not a forged one.
- **No Pi image, no 32-bit build, and the Mac app is untried.** A Raspberry Pi needs the 64-bit system. The Mac app is built
  and started by CI on every push, has not yet been opened by a person on a
  Mac. It is signed and notarised (docs/macos.md).
- **An update that changes the database cannot be undone by going back.**
  On Linux the old program is put back when the new one does not answer,
  and the database from before is kept beside the data - but it is not put
  back by itself, because that would discard whatever was recorded since.
  On Windows nothing copies the database before an update.
- **"Start with Windows" has never started with Windows.** The switch
  writes one registry value for the current user; whether Velopack's
  shortcut stub passes `--background` on to the launcher is assumed.
- **One loop per port is modelled; several ports work** (each port is its
  own bus), but more than one has only been run against the emulator. More
  than two boards on a loop likewise: twelve would each be asked what
  changed some four times a second (counted from the two that were
  measured, not measured).
- **Bluetooth boards, Millennium, Chessnut**: not started. A driver is one
  module behind `Alnasl.Driver`.

## Stack

Elixir, Phoenix 1.8 LiveView, SQLite (`ecto_sqlite3`), `Req` for HTTP,
`circuits_uart` for serial ports, `eqrcode` (MIT) for the QR code of the
box's address. No Tailwind and no component library: the
stylesheet is hand-written (`assets/css/app.css`), bundled by esbuild.

## License

Apache License 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).

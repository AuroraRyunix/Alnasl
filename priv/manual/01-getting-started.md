# Getting started

Alnasl reads the electronic boards in a playing hall, works out the moves from where the pieces stand, and sends the moves and the clock times to the results site while the games are played. This chapter says what it is, the two ways to run it, how to install it, and what to check before the first round.

> [!NOTE] It never decides a result
> A mate on the board or two kings in the centre is a suggestion. You confirm it. A board never enters a result anywhere.

## What Alnasl does {#what-alnasl-does}

Who plays whom, Alnasl learns from OpenPairings. What each board saw goes back there, beside the pairing. The moves and the clocks go to the results site (OpenResults), where spectators follow them. Alnasl keeps everything itself first, so a hall without internet loses nothing: what could not be sent goes out, in order, when the connection is back.

You work with it in a browser, on the box itself or on your laptop in the hall. The places are in the rail on the left (on a phone, along the top):

| Page | What it is for |
| --- | --- |
| Round | The screen during play: a tile per board |
| Boards | What is plugged in, the table numbers, "Ready for round N?" |
| Outbox | What has gone to the results site and the other destinations, and what waits |
| PGN | Games as text: read, attach, compare, export |
| Recordings | Everything the boards said, raw, for looking at again |
| Log | What happened, in sentences |
| Halls | The halls you belong to, their bridges and people |
| Setup | Links, tournaments, accounts, updates |
| Help | This manual |

## Two ways to run it {#two-ways}

It is the same program either way. What differs is where it runs and what is plugged into it.

**A box in the hall.** A small computer (a Raspberry Pi, a mini PC, the arbiter's laptop) with the boards plugged into it by USB or serial cable. It reads them itself. This is the normal case, and it works with no internet at all.

**The hosted server.** The same program runs on a server, at alnasl.zerotwo.cloud. A server has no boards of its own: it has no ports to read. It takes **bridges** instead: Arkab, a small program in a hall that read the boards there and send them on over the internet (see [Bridges](03-bridges.md)). The pages are the ones you know: the round, the games, the corrections. The difference is that every page asks who you are, always, and accounts come by invitation only (see [Accounts, halls and roles](06-accounts-and-halls.md)).

The server leaves out what only a box can do, instead of greying it out: adding boards and the list of serial ports on the Boards page, simulator boards, the Updates panel and starting with Windows, the PIN and the hall network, and the box's name. Setup says which edition you are looking at, under "This copy of Alnasl".

> [!TIP] Which one?
> Boards in your own hall and you want it simple: a box in the hall. Several halls, an arbiter at home, or nobody wants a computer in the hall: bridges and the server. Both can be used together, because one bridge may feed more than one server.

## Installing {#installing}

**Windows.** Alnasl-Setup.exe installs for you alone, without an administrator, and puts "Alnasl" in the Start menu. The program is not signed, so the first time Windows says "Windows protected your PC": choose "More info", then "Run anyway". The small Alnasl window is the program: closing it stops Alnasl, and while it is stopped the boards are not read. There is also a zip that installs nothing: unzip it and start Alnasl.exe.

**Linux and the Raspberry Pi.** One line installs Alnasl as a service that starts with the box (64-bit; Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm, or newer):

```
curl -fsSL https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh | sudo sh
```

**Mac.** Download alnasl-macos-aarch64.zip for a Mac with an Apple chip (M1 and later; there is no build for Intel Macs), open it, and drag Alnasl into Applications. Apple has not signed it yet, so the first time macOS refuses to open it: in System Settings, Privacy & Security, click "Open Anyway" beside the message about Alnasl. Quitting Alnasl (Cmd-Q) asks first, because while it is stopped the boards are not read.

Then open the site in a browser: on the box itself at `http://localhost:4040`; from a laptop on the hall's network, the box's address with the same port (Boards and Setup show it, with a QR code for a phone, once other machines are let in).

### Updating {#updating}

The box asks once every half hour whether a newer version is out, and says so at the top of the page. It downloads nothing until you say yes under Setup, Updates, where it also says how big the download is. It will not restart while a game is being played unless you insist: the moves played during the restart are not read. "Later" asks again tomorrow; "Don't ask again" stops the looking, and Setup switches it back on.

### Where your data is {#where-your-data-is}

Not in the program's folder. Windows: `%LOCALAPPDATA%\AlnaslData` (type that in Explorer's address bar). Linux, installed: `/var/lib/alnasl`. Mac: `~/Library/Application Support/AlnaslData`. It holds the database, the PGN of every game, the raw recordings, and the keys and codes you pasted. Updating and uninstalling leave it alone; installing again finds it. To move to another computer, copy that folder while Alnasl is stopped.

Setup, "This copy of Alnasl", says the version, how this copy was started and where its data folder is. A second copy started another way on the same computer has a data folder of its own: its own boards, numbers and tournaments.

## Before the round {#before-the-round}

The same short list every time. Each step has a page that says in words what is wrong, if something is.

1. Setup, Tournaments: paste the connect code from OpenPairings and say which tables play in which tournament (see [OpenPairings, OpenResults and Lichess](05-openpairings-and-openresults.md)). Press "Test connection".
2. Boards: every board should show a state other than "No signal", and its picture should match the pieces on it.
3. Boards: the column "Start position" must say "Right" for every board. If not, it names the pieces and squares. A king and queen swapped is the usual one.
4. A board with a clock is only "Right" when its clock is too: to the right of the board, the lever up on White's side so that White's time runs first.
5. Boards: give each board its table number (see [Boards and ports](02-boards-and-ports.md)).
6. Boards: "Ready for round N?" must say Ready. If not, it lists what is wrong, board by board.
7. Round: every tile should read "Waiting for start".

## Language and colours {#language-and-colours}

The site is in English or Dutch: EN and NL at the foot of the rail. The choice is the box's, so everybody who opens it sees the same language, and so does this manual.

The colours come in the same themes as OpenResults: Paper, Night, Board, Slate and High contrast, and Match device, which follows the phone or computer. Choose with the half-moon at the bottom of the rail, or under Setup (on a phone, the rail is not shown). The choice is kept in that browser only. High contrast is the one for a projector at the back of the hall.

More themes can be added as theme packs: one folder per theme, in the folder `themes` inside the data folder. On the next page load they are offered after the built-in ones. A pack the box will not load is listed in grey, with the reason.

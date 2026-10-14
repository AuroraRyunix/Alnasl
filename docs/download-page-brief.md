# Alnasl: brief for the download page

For whoever maintains the public website. You have not seen this code and
do not need to: everything the page may say is here, and so is what it may
not.

> **Status (2026-10-12): version 0.1.0 is released.** The download links
> below are permanent and were checked after the release: the Windows
> installer, the Linux install script and the checksum file all download.
> Lines marked **[not yet watched]** describe something that is built but
> that nobody has yet seen work on a real machine; word them as
> "available", not as "tested".

## What it is

Alnasl reads electronic chess boards in a tournament hall and sends every
move, with the clock times, to the live results site as it is played. It
runs on a PC or a small box beside the boards, takes the pairings from
OpenPairings, and keeps working - and loses nothing - when the hall's
internet does not.

## Who it is for

Arbiters and organisers who run a tournament with OpenPairings and have
DGT electronic boards on some or all tables. Not for players, and not for
spectators: they watch on the results site and never see Alnasl.

It is one of four programs that go together. Say so, so that nobody
downloads the wrong one:

| | |
|---|---|
| **OpenPairings** | pairs the tournament; the arbiter's program |
| **OpenResults** | the public results site, with the live boards |
| **Alnasl** | in the hall: reads the boards, sends the moves |
| Ainalrami | the pairing engine inside OpenPairings; nobody downloads it |

## The download links

These addresses are the same for every release, now and later. Link to
them exactly; do not link to a file on a particular release's page, and do
not host copies.

| What | Address |
|---|---|
| Windows installer | `https://github.com/AuroraRyunix/Alnasl/releases/latest/download/Alnasl-Setup.exe` |
| Windows, portable zip | `https://github.com/AuroraRyunix/Alnasl/releases/latest/download/alnasl-windows-x86_64-portable.zip` |
| Linux, PC (x86_64) | `https://github.com/AuroraRyunix/Alnasl/releases/latest/download/alnasl-linux-x86_64.tar.gz` |
| Linux, Raspberry Pi and other arm64 | `https://github.com/AuroraRyunix/Alnasl/releases/latest/download/alnasl-linux-aarch64.tar.gz` |
| Linux installer script | `https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh` |
| Checksums | `https://github.com/AuroraRyunix/Alnasl/releases/latest/download/SHA256SUMS` |
| All versions, release notes | `https://github.com/AuroraRyunix/Alnasl/releases` |
| The newest version's notes | `https://github.com/AuroraRyunix/Alnasl/releases/latest` |

How this works: the files carry **no version in their names**, on purpose,
so GitHub's `releases/latest/download/<name>` always resolves to the newest
release. There are no versioned copies beside them. The version is inside
each file and on the releases page; do not print a version number on the
download page unless you fetch it (the releases page's API,
`https://api.github.com/repos/AuroraRyunix/Alnasl/releases/latest`, field
`tag_name`) - a number typed into the page will be wrong within a month.

The same holds for the file sizes. In 0.1.0: Windows installer 27 MB,
portable zip 21 MB, Linux x86_64 33 MB, Linux arm64 31 MB. They will
change; take them from the API (`assets[].size`) or say nothing.

## Instructions, three lines each

**Windows (10 or 11, 64-bit)**

1. Download `Alnasl-Setup.exe` and run it. Windows warns that it does not
   know the program: click "More info", then "Run anyway".
2. Alnasl starts: a small window, and your browser on the management site.
3. Leave the small window open - closing it stops Alnasl. Plug in the
   boards and follow "Before the round" on the site's Help page.

**Windows, without installing**

1. Download the portable zip and unzip it anywhere.
2. Start `Alnasl.exe` in the unzipped folder (the same warning, once).
3. To update, unzip the new version beside the old one; your data is not in
   the folder.

**Linux and Raspberry Pi (64-bit; Debian 12, Ubuntu 22.04, Raspberry Pi OS
"Bookworm" or newer)**

1. On the box, in a terminal:
   `curl -fsSL https://github.com/AuroraRyunix/Alnasl/releases/latest/download/install.sh | sudo sh`
2. Open `http://localhost:4040` on the box. Alnasl now starts with the box.
3. For a hall without internet: download the archive beforehand, unpack it
   on the box, and run `sudo sh alnasl/install.sh` from it.

Show the `curl` line as copyable text, in one piece. Do not shorten the
address and do not wrap it in a redirect of your own: people are being
asked to run it as root, and it should visibly come from the project's
GitHub.

## System requirements

- **Windows**: Windows 10 or 11, 64-bit. No administrator rights needed.
  About 60 MB of disk for the program.
- **Linux**: 64-bit x86 or arm64, systemd, glibc 2.35 or newer - Debian 12,
  Ubuntu 22.04, Raspberry Pi OS "Bookworm" **64-bit**, or later. Root is
  needed once, to install. **There is no build for 32-bit Raspberry Pi
  OS**; say so, because that is what many Pis run.
- **macOS**: no download. It runs from the source code; do not offer a
  button.
- **Boards**: DGT electronic boards with a serial connection: a DGT USB
  board directly, or a serial (RS232) board through a USB-serial adapter.
  A DGT clock connected to the board is read too. See "What not to claim"
  for how much of this has been tried.
- **A browser** on the same computer (any current Chrome, Edge, Firefox or
  Safari) for the management site; optionally a phone or a laptop on the
  hall's network.
- **Internet** in the hall is optional: moves are kept and sent when the
  connection returns. Installing with the one-line command, and updating,
  need it for that moment.
- **OpenPairings** to get the pairings from, and a results site
  (OpenResults) for the games to appear on. Alnasl also works without
  OpenPairings, with the players typed in.

## The unsigned-program warning

Alnasl is not code-signed. Say it plainly, next to the Windows button, so
that the warning is expected rather than alarming. Suggested wording:

> **Windows will warn you the first time.** Alnasl is free software without
> a paid code-signing certificate, so Windows SmartScreen shows "Windows
> protected your PC". Click **More info**, then **Run anyway**. The
> download comes straight from the project's GitHub releases.

Dutch:

> **Windows waarschuwt de eerste keer.** Alnasl is vrije software zonder
> betaald certificaat voor code-ondertekening, dus Windows SmartScreen toont
> "Uw pc wordt beschermd". Klik op **Meer informatie** en dan op **Toch
> uitvoeren**. De download komt rechtstreeks van de GitHub-releases van het
> project.

Do not write "safe", "virus-free" or "verified": nobody has verified it,
and a page that says so is the first thing an antivirus vendor's reviewer
distrusts. Do not tell people to switch off their antivirus.

## Licence

Apache License 2.0. Free to use, also commercially; the source is public.
Copyright 2026 Jorian Burssens. (OpenPairings is under a different licence,
the Elastic License 2.0; do not copy its licence line here.)

"DGT" is a trademark of Digital Game Technology B.V. Alnasl is not
affiliated with or endorsed by DGT. Put that sentence in the page's small
print, and do not use DGT's logo.

## Links

- Source and issues: <https://github.com/AuroraRyunix/Alnasl>
- Releases: <https://github.com/AuroraRyunix/Alnasl/releases>
- Install, update, where the data is, in full: the README's "Install"
  section, <https://github.com/AuroraRyunix/Alnasl#install>
- The arbiter's guide to setting up electronic boards is a chapter of the
  OpenPairings manual, which is public (no login):
  <https://pairings.zerotwo.cloud/help>, chapter "Setting up electronic
  boards" (`/help/setting-up-boards`; and `/help/live-boards` for what
  live boards are). Open the chapter's address once before linking to it:
  it appears with the OpenPairings deploy that follows this release.
- On the box itself: the Help page of the management site, in English and
  Dutch.

## What not to claim

This is the part to read twice. As of this writing:

- **It has not been used at a tournament.** Real DGT boards have been
  connected and read at a desk: a few short games on one board with a
  clock. No tournament game has been played through Alnasl.
- **Two boards were tried**, an older serial board (firmware 1.9) and a
  newer USB-C board (firmware 4.0): one alone on its cable, and both
  together on one cable (DGT's "loop"), where both were found and read.
  A move played live on a loop, a clock on a loop, and more than two
  boards on a loop have not been seen. Bluetooth boards, and boards from
  Millennium or Chessnut, are not supported at all.
- **No number of boards is proven.** Do not write "up to N boards".
  Everything about many boards at once comes from a simulator.
- **The installers have been built and published, not used.** **[not yet
  watched]** Nobody has yet installed, updated or uninstalled Alnasl with
  them. Ask the owner which lines of `docs/releasing.md`'s checklist have
  been struck before describing installation as anything more than
  "available".
- **Lichess broadcasting** is built against Lichess's documentation and has
  not been run against lichess.org. Do not advertise it.
- **Raspberry Pi**: the arm64 build exists for it; no Pi has run it. Say
  "for Raspberry Pi (64-bit)", not "tested on Raspberry Pi".
- It **does not decide results**, and the page must not suggest it does:
  what a board saw is shown to the arbiter in OpenPairings, who enters the
  result.
- It is **not a DGT LiveChess replacement in general**: it sends games to
  OpenResults (and to OpenPairings), not to arbitrary sites.
- Do not call it "stable", "production-ready" or "1.0". The version starts
  with 0 for a reason.

Honest words that are true today: "new", "first release", "built for
OpenPairings", "keeps working offline", "nothing is installed without
asking". "Your data survives an uninstall" is how it is built and
tested in code, **[not yet watched]** on a real machine: leave it out
until the owner says he has seen it.

## Suggested text

English:

> **Alnasl - live boards from your hall**
>
> Alnasl reads the electronic boards in your playing hall and puts every
> move and clock time on your results site as it is played. It takes the
> pairings from OpenPairings, runs on a Windows PC or a small Linux box
> beside the boards, and loses nothing when the hall's internet drops:
> moves are kept and sent when the line is back.
>
> It is new. Real boards have been read with it at a desk; no tournament
> has been played on it yet. If you try it at an event, keep scoresheets as you
> always do, and tell us how it went.
>
> Free and open source (Apache 2.0). For DGT boards with a serial or USB
> connection.

Dutch:

> **Alnasl - live borden vanuit je speelzaal**
>
> Alnasl leest de elektronische borden in je speelzaal en zet elke zet en
> elke kloktijd op je uitslagensite terwijl er gespeeld wordt. Het haalt de
> paringen uit OpenPairings, draait op een Windows-pc of een klein
> Linux-kastje naast de borden, en verliest niets als het internet in de zaal
> wegvalt: de zetten worden bewaard en verstuurd zodra de verbinding terug
> is.
>
> Het is nieuw. Er zijn echte borden mee gelezen aan een bureau; er is nog
> geen toernooi op gespeeld. Probeer je het op een evenement, hou dan notatieformulieren bij
> zoals altijd, en laat ons weten hoe het ging.
>
> Gratis en open source (Apache 2.0). Voor DGT-borden met een seriële of
> USB-aansluiting.

## When this brief goes out of date

When the installers have been watched on real machines; when a tournament
has been played on it;
when a second board model has been tried; when anything is signed. Each of
those changes a sentence above. The file lives at
`docs/download-page-brief.md` in the Alnasl repository; if the copy you
were sent is older than the one there, the one there is right.

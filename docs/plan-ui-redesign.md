# Plan: the Alnasl UI, rethought

Status (2026-10-17): steps 0 to 4 are built; the glossary of H is
[glossary.md](glossary.md) and the manual's "Words used here". Written after
the hosted server went live and an account-wide OpenPairings link filled the
front page with every board of every tournament.

## What is wrong today (the short list)

- **The front page shows everything.** `/` draws one section per active
  tournament and one full SVG tile per *paired* board of its current round,
  whether or not a board exists here (`round_live.ex` `load/1`,
  `Tournaments.active/0`). An account link brings every current tournament:
  15 tournaments x 40 boards = 600 tiles, 15 QR codes, a 16-item filter, and
  a full recompute every 300 ms while any board moves.
- **The server shows things it cannot do.** Add a board (serial/simulator),
  Serial ports, Updates and the installer, autostart, PIN/LAN access, "This
  box". A browser has no USB port for it.
- **The frame.** The hall switcher is an unstyled bulleted list of every hall
  (no CSS exists for it), it squeezes the navigation, and switching always
  throws you back to `/`. Theme and language sit in the rail footer, which
  is hidden on phones, so on a phone you cannot sign out. Theme picker and
  language exist twice (rail and Setup); the language link changes the whole
  box's language for everybody, by a GET, with no role check. Halls and
  Boards share one icon.
- **Setup is a junk drawer.** Twelve panels on one page, from tournaments to
  the tracker's internals; the tournament list has a block and a form per
  tournament, gone ones included.
- **Scope differs per page.** Round, Boards, PGN: this hall. Log and
  Recordings: all your halls. Walk: everything. Outbox: a mix, and the
  Outbox badge in the rail counts every hall.
- **Lists without an end.** Tournament filter, hall switcher, the "outside
  this tournament" banner (boards x tournaments buttons), the "which tables"
  banner, the per-row tournament select on Boards, Recordings, hall cards.
- **Words.** "box", "server", "results site/page/server" for the same
  things; some literals not translated; the server still calls itself a box.
- **Odds and ends.** ~67 inline `style=`; classes used but never styled
  (`.hall-switcher`, `.account-line`, `.hall-cards`, `.inline`, `.warn-text`);
  PIN and Join pages copy the door frame by hand and have no flash.

## Principles

1. **Show what plays here.** A page shows the current hall's boards and the
   tournaments that have tables in it. Everything else is one line away, not
   on the screen.
2. **One edition flag.** The program knows whether it is a box in a hall or
   the server, and never offers what the edition cannot do.
3. **Every setting in one place.** No control twice.
4. **Same scope everywhere:** the current hall, with an explicit "all my
   halls" where that makes sense.
5. **Phone first for the arbiter pages** (Live, Game, Walk), desk first for
   setup.

## A. The edition flag

`Alnasl.edition/0` returns `:box` or `:server` (today's `server?` -
`ALNASL_NO_LOCAL_BOARDS` - made explicit, read once at boot, shown in About).
Every page asks it; nothing is greyed out, it is simply absent.

On the server, gone: Add a board, Serial ports, the simulator, Updates and
the installer, autostart, PIN and hall-network access, "Number by touching"
for local ports (it stays for bridged boards), the box-name setting (the
server has a fixed name), and the word "box" in the frame. Present on both:
bridges, halls, accounts, tournaments, results, Lichess, PGN, log,
recordings, tracker (admins).

On a box, gone: nothing that works today. A box with no accounts keeps the
open behaviour.

## B. The frame

**Left rail, desktop**

1. Brand: logo, "Alnasl", and under it the edition: the box's name, or
   "server".
2. **Hall picker**: one button showing the current hall and its live-board
   count. It opens a menu: your halls (search field from 7 halls on), each
   with its role and live boards; at the bottom "All halls". Switching keeps
   the page you are on (`/halls/:id/enter?return_to=`). Not shown when you
   have one hall.
3. Navigation in groups:
   - *Play*: Live (the front page), Boards, Games (PGN)
   - *Send*: Results (today's Outbox)
   - *Manage*: Hall (people, bridges, invitations), Setup
   - *Look back*: Log, Recordings
   - Help at the bottom of the list.
   Each item has its own icon (Halls no longer borrows Boards'). Counts
   (alarms, waiting) are per hall.
4. **Account button** at the foot: initials or email, opening a menu with:
   your role in this hall, Account, Language (EN/NL, *per person*, stored on
   the account or in a cookie without one), Theme (the full picker, the only
   place it lives), Sign out. The box-wide default language stays in Setup
   for admins only.

**Phone (<= 860 px)**: the rail becomes a top bar (brand, hall picker,
account button) and a bottom tab bar: Live, Boards, Results, More (the rest
of the navigation). Nothing is hidden that the desktop has.

**Banners**: one stack under the bar, at most two visible, the rest folded
into "2 more notices". The "outside this tournament" and "which tables"
banners name at most three tournaments and link to Setup for the rest.

## C. The front page: Live

- Shows only tournaments **placed in this hall** (the placements work) and,
  within them, only boards that **exist here** or have a game. Paired boards
  with no physical board are a count ("26 pairings without a board"), not
  tiles.
- Other tournaments the links bring: one line, "14 more tournaments not on
  the boards here", to Setup > Tournaments.
- Tournament tabs only for tournaments placed here; with one, no tabs.
- **Two views**, remembered per browser: *Boards* (today's tiles, with the
  SVG) and *List* (one row per board: table, players, last move, clock,
  state). From 24 tiles the list is the default.
- QR code of the results site moves into a "Share" button in the bar, made
  on demand.
- Redraw only the tile that changed (streams keyed by board), not the page.

## D. Setup, split

Setup becomes a page with sections in a side list (desktop) or a select
(phone), each its own URL:

| Section | Holds |
|---|---|
| Tournaments | compact rows: name, status dot, round, boards, tables chip; open one for details, placements, auto-start. "On the boards here" first, the rest folded, finished/not started hidden by default, search from 9 on. |
| Connections | codes and account links, one line each with a status badge and a menu (Test, Retry, Remove); "+ Add": paste a code, or connect an account. |
| Results and Lichess | results site, relay keys, Lichess push/pull. |
| This box / This server | name (box only), round, default language (admins). |
| Access | box: PIN, hall network, phone; server: nothing here (accounts live under Hall). |
| Updates | box only. |
| Advanced | tracker settings (admins). |

The colour theme leaves Setup (account menu). The bridges panel leaves Setup
(Hall page). The phone-access panel lives in one place: Boards on a box, the
account menu ("Sign in a phone") everywhere.

## E. Hall

`/halls` becomes a compact table (name, your role, live boards, bridges,
attention), not cards. `/halls/:id` gets tabs: People, Invitations, Bridges,
Settings (rename, delete). The hall picker in the rail is the everyday way
to switch; `/halls` is for managing them.

## F. Scope, the same everywhere

Every page reads the current hall: Round/Live, Boards, Walk (fixed: it reads
everything today), PGN, Results (Outbox: every count and the rail badge per
hall), Log and Recordings (default this hall, a toggle "all my halls").
Global helpers used inside hall pages (`Tournaments.many?/0`, `active/0` in
`Status`, `links/0` in RoundLive) get a hall argument.

## G. Lists with an end

Recordings and Log: paging (50 a page) and a search. Boards: the per-row
tournament select lists only tournaments placed in this hall. Hall cards:
table (E). Tournament filter: tabs only for placed tournaments (C).

## H. Words

One vocabulary, in a glossary in the manual and enforced by a test of the
English catalogue:

- **box** - Alnasl in a hall; **server** - the hosted Alnasl; never "box" on
  the server (the frame and texts ask `edition/0`).
- **results site** - OpenResults; never "results server" or "results page"
  for the site itself ("results page" = one tournament's page on it).
- **bridge** - Arkab; **connection** - a code or account link to OpenPairings.
- The literals "QR", "PGN", "EN/NL", "English/Nederlands", the topbar colour
  in JS, `|| "OpenPairings"`: through gettext or tokens.

## I. Look

- Every inline `style=` becomes a class; spacing as tokens
  (`--space-1..6`); the five undefined classes get CSS.
- Door pages (PIN, Join) use `Layouts.door` and get flashes.
- Empty states where missing: Setup lists, bridges, help search.
- The progress bar takes `--accent`.

## Order of work

Each step ships on its own.

0. **Now, small** (independent of placements): the edition flag hides what
   the server cannot do; Live shows only boards that exist here or have a
   game, with the "N more" line. This alone fixes the flooded front page.
1. **After placements is merged**: the frame (hall picker, grouped
   navigation, account menu with language and theme, phone tab bar), and
   Live's "placed here" filter and list view.
2. Setup split, the compact tournament rows, Connections.
3. Hall pages, scope consistency, lists with an end.
4. Words, inline styles, door pages, empty states.
5. Manual (EN+NL) follows each step; a final pass at the end.

## Later: the browser bridge

Not part of this redesign; after it. Chromium browsers on the desktop
(Chrome, Edge) have the Web Serial API: over https a page may open a serial
port after one click in the browser's own port dialog, and an electronic board on
USB is one. So on the server, a laptop with Chrome and a board on USB could
be a bridge without installing anything: Boards > "Connect a board here",
the page reads the board and sends what it sees over its own socket, and
the server treats it as one more bridge (`Alnasl.Driver.Remote`).

Needs: the board protocol again in JavaScript, a small queue in the browser
(IndexedDB) so a dropped line loses nothing, and the tab staying open.
Chromium on the desktop only; no Firefox, no Safari, nothing on iOS; plain
http on a hall network does not qualify (localhost does). First trial: one
board, Chrome, against the server. Arkab stays the answer for a hall full
of boards.

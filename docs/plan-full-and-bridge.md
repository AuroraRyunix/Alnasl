# Plan: Alnasl (full) and Arkab (the bridge)

> **Revised 2026-10-16, after the maintainer's decision.** There is no
> "bridge mode" switch in Alnasl. Instead:
>
> - **Arkab** (own repository, AuroraRyunix/Arkab, Apache-2.0) is the small
>   program: the board drivers, the serial transport, the bus/loop discovery,
>   the capture recorder, the store-and-forward queue, the outgoing link to
>   one or more Alnasls, and one small status/join page. No tracker, no
>   rounds, no logins, no OpenPairings/OpenResults. Its own release.
> - **Alnasl** is the full program and takes Arkab **as a library**
>   (`{:arkab, ...}` dependency, pinned by tag like OpenPairings pins
>   Ainalrami). Boards on its own ports run Arkab's drivers in-process;
>   boards elsewhere arrive through an Arkab bridge over the link
>   (`Alnasl.Driver.Remote`). Above the driver they are the same.
> - The driver code therefore MOVES from Alnasl to Arkab and exists once.
>
> Read "bridge mode" below as "Arkab"; everything else (link, joining in
> one step, many-to-many, logins, halls, roles, the server instance)
> stands as written.

Status: built. Arkab 0.1.0 (2026-10-16) holds the drivers; the bridge link and "Add a bridge" shipped in Alnasl 0.2.0 (2026-10-17) and the Setup wizard in 0.3.0 (2026-10-18). The bridge code lives in its own repository, **Arkab** (Apache-2.0); see "Decided" below. The plan text below is kept as it was written.

## What the maintainer asked for

- Alnasl gets **two run modes**: `full` (what it is today, plus more) and
  `bridge` (reads the boards in the hall and nothing else).
- A full Alnasl on the server ("the cloud version") does **everything**:
  follow and correct games from home, several halls at once, club arbiters
  with their own login.
- **The local full version allows the same.** No feature is cloud-only. The
  cloud is just a full Alnasl that happens to have no serial ports of its
  own, and gets all its boards from bridges.
- Login works like OpenPairings: its own accounts, plus the 02cloud single
  sign-on (Keycloak, `auth.zerotwo.cloud`, realm `zerotwo`).

## The idea in one picture

```
 hall A                       hall B                    server
 ┌──────────────┐            ┌──────────────┐          ┌──────────────────────────┐
 │ Alnasl       │            │ Alnasl       │  out-    │ Alnasl (full)            │
 │ mode: bridge │──────────▶ │ mode: bridge │──going──▶│  boards of hall A + B    │
 │ electronic boards   │  outgoing  │ electronic boards   │  only    │  tracker, games, rounds  │
 └──────────────┘  only      └──────────────┘          │  OpenPairings/OpenResults│
                                                        │  logins, roles           │
 hall C                                                 └──────────────────────────┘
 ┌──────────────────────────┐
 │ Alnasl (full)            │   today's box, unchanged in what it can do,
 │ its own electronic boards       │   and it can ALSO take bridges (a second
 │ + optional bridges       │   room in the same club, for example)
 └──────────────────────────┘
```

A full Alnasl takes boards from two places: its own serial ports (as now)
and bridges. To everything above the driver - the tracker, the round, the
outbox, the pages - a bridged board is a board like any other.

## Where it splits: the driver

`Alnasl.Driver` already reduces a board to a handful of small messages:
`{:position, board}` (the whole board), `{:clock, ...}`, `:connected` /
`:disconnected`, `{:info, ...}`, `{:poll, ...}`, `{:raw, ...}`. That is the
cut.

- **Bridge mode** runs the drivers, the bus (`DgtBus`, the loop discovery)
  and the capture recorder. Every driver event goes up the wire with the
  time it happened. It does **not** run the tracker, the session, the
  destinations or the round.
- **Full mode** gets a new driver, `Alnasl.Driver.Remote`: a board whose
  events arrive from a bridge instead of a port. The tracker reads it
  exactly as it reads `DgtSerial` today.

Why there and not higher up: the tracker (positions to moves, the
reconstruction, fast play) is the hard part and must exist in one place
only. A bridge that only reports what the boards show cannot disagree with
anyone about what move was played, and it needs no update when the tracker
improves.

Timestamps travel with each event, so fast play and clock readings keep
their real timing even when the line is slow.

## The bridge link

- **Outgoing only.** The bridge connects to the full Alnasl; the hall needs
  no port forward and no fixed address.
- **One WebSocket**, TLS, through the Cloudflare tunnel like the other
  sites. Up: driver events. Down: commands (scan a port, add a port, forget
  a board, start/stop recording, "send me the whole board again").
- **Nothing is lost when the line drops.** The bridge writes each event to
  its own SQLite queue first, numbered, and drops it only when the server
  has acknowledged that number - the outbox's guarantee, one level lower.
  On reconnect it resends from the last acknowledged number; the server
  ignores numbers it already has. After a long outage the server does not
  replay every intermediate position into the live view. It feeds them to
  the tracker in order and then shows the result.
- **Joining a box to an account.** The full Alnasl shows a short code. On
  the bridge's one setup page you type the code and the server address.
  The bridge then receives its own long key; the code is used up. The key
  can be revoked from the full side (the same idea as the relay keys to
  OpenResults).
- **Board identity.** The bridge reports "port, bus address, serial
  number". The full side decides which table row that is, using the
  recognition that already exists (`Alnasl.Tables`, `Alnasl.Loops`). So
  moving a board between bridges, or a loop to another adapter, works as
  it does locally.

## The bridge's own page

Small and local, on the box itself (port 4040 in the hall network, as now):
which server it is joined to and whether the line is up; how many events
are waiting; the ports and the boards each one answers with; the join
code field; a "leave this server" button. No games, no rounds, no logins.
Anyone in the hall network can see it. Changing the server takes the
current key.

## Logins and roles (full mode, local and cloud alike)

- **Accounts** as OpenPairings has them: `phx.gen.auth` (email +
  password), plus **"Sign in with 02cloud"** through Keycloak. The
  Keycloak module is OpenPairings' own (`PairingsEngine.Keycloak`, a
  minimal confidential OIDC client), copied with its own client id
  `alnasl`. Signing in with Keycloak links to an existing account by
  email or creates one.
- **Halls.** A hall is a place that has boards: "this box's own ports" is
  one hall, and each joined bridge belongs to a hall. Tournaments belong to
  a hall.
- **Roles**, per hall: *owner* (joins bridges, invites people, everything),
  *arbiter* (games, corrections, rounds, the links to OpenPairings and
  OpenResults), *viewer* (follows the games, changes nothing). One account
  can have different roles in different halls; every page shows only the
  halls the account belongs to.
- **Several halls at once**: a hall switcher at the top, and an overview
  of all your halls, with live boards and anything that needs an arbiter.
- **From home**: the existing pages (round, walk, game, corrections), but
  reached through the login instead of the hall network. Nothing new to
  learn.

## The local box keeps working as it does today

- **No login until you want one.** A box with no accounts behaves exactly
  as today: anyone in the hall network can use it. Creating the first
  account (the owner) switches login on, and from then on every page
  needs it.
- **Phones in the hall.** The QR code on the setup page then carries a
  short-lived sign-in link, so an arbiter does not type a password on a
  phone.
- **Upgrading changes nothing** for an existing box: same data, same
  pages, mode `full`, no accounts.

## The server instance

- Alnasl in full mode as its own systemd service on the VPS, its own data
  directory and SQLite database, behind the Cloudflare tunnel
  (`alnasl.zerotwo.cloud`, say). Resource caps like the other services
  there (2 vCPU box).
- Added to `openpairings-deploy` like OpenResults (`--alnasl`), with its own
  rollback point.
- On the server, the serial-port drivers, the simulator and the board finder
  are off; boards come only from bridges.
- Its links to OpenPairings and OpenResults become server-to-server,
  which is simpler than from a hall.

## Order of work

Each step ships on its own and leaves the box working.

1. **Run mode switch** (`ALNASL_MODE=full|bridge`, default `full`), and
   the supervision tree for each mode. Bridge mode: drivers, bus,
   recorder, bridge page; nothing else starts.
2. **The link**: `Driver.Remote` on the full side, the bridge's queue and
   WebSocket client, the server's socket endpoint, join codes, keys,
   commands down. Proved with the simulator and the replay driver
   through a real socket, including cutting the line mid-game and a
   restart on either side. Then with the real boards (only when the
   maintainer is not using LiveChess on that port).
3. **Accounts**: `phx.gen.auth`, "no accounts means open", roles, the QR
   sign-in link.
4. **Keycloak** sign-in (needs the `alnasl` client in Keycloak: redirect
   URL and secret, which the maintainer creates as for `openpairings`).
5. **Halls**: scoping every page and query by hall, the switcher, the
   overview, invitations.
6. **Server instance**: config for running without serial ports, the
   deploy script, the tunnel route. Deploying needs the maintainer's go.
7. **Manual (EN+NL), changelog, release.**

## Decided (2026-10-16)

1. **Accounts on the server: by invitation only.** `jorian@zerotwo.cloud`
   is the admin and the only one who can invite. A 02cloud login alone
   gets nobody in.
2. **Bridges and full Alnasls are many-to-many.** One bridge can feed
   several full Alnasls (the club's own box and the server, say), and one
   full Alnasl takes many bridges. Integration is the point. So a bridge
   holds a list of servers, each with its own key and its own position in
   the queue: an event leaves the queue only when every server has
   acknowledged it, and a server that is down holds up nobody else.
   Commands down from two servers can contradict each other; the bridge
   applies them in arrival order, and only an owner-level server may make
   it forget a board or a port.
3. **The bridge lives in its own repository**, not in Alnasl. Alnasl keeps
   its two run modes; bridge mode runs that repository's code, which
   Alnasl takes as a dependency, and the protocol is defined there too, so
   any full Alnasl and any bridge agree on it.
4. **The bridge repository is Arkab** (AuroraRyunix/Arkab), Apache-2.0 like Alnasl.

## Keep it simple (maintainer, 2026-10-16: "not 20 key add places")

Joining a bridge to a server is **one action, one place**:

- On the full Alnasl (server or club box): **Halls → Add a bridge**. It
  shows a QR code and the same thing as a link
  (`https://alnasl.zerotwo.cloud/join/K7Q-4MD`), valid for 15 minutes.
- On the bridge's page: **scan or paste that link**. Done. The address
  and the one-time code are both in it; the bridge fetches its own key
  and stores it. Nobody types a server address, sees a key or copies one.
- A second server is the same step again: the bridge page lists its
  servers, each with a green/red dot and a **Remove** button. Removing on
  either side ends it for both.
- Keys are never shown, never exported, never typed. Losing a bridge is
  one Remove on the server.

That is the whole key story: one "Add a bridge" button, one paste, one
Remove. No settings files, no environment variables, no keys in two
places.

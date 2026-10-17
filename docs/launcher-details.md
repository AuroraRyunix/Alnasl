# Launcher details: `GET /_launcher/stats`

What the Windows launcher's **Details** panel, the Mac app's **Details**
window and `./alnasl.sh details` show. OpenPairings has the same endpoint with
the same shape (its `docs/launcher-details.md`); only the app-specific block
differs.

## Who gets an answer

All three, or a plain `404 Not Found` with no hint which one failed:

1. **From this machine.** The socket's peer address is `127.0.0.0/8` or
   `::1`. Forwarded headers are never read as an address. The site itself may
   be open to the hall's network (`ALNASL_LISTEN=lan`); this endpoint is not.
2. **With this start's secret** in the header `x-launcher-token`, compared in
   constant time.
3. **Without a proxy header** (`x-forwarded-for`, `forwarded`, `x-real-ip`,
   `cf-connecting-ip`, `x-forwarded-host`). A box somebody put behind a
   tunnel sees its public traffic arrive from loopback; those requests carry
   one of these and get the 404. The launchers and the terminal command talk
   to the socket directly and send none.

There is no hosted Alnasl to exclude: the box is an appliance. Where no secret
exists (`config :alnasl, launcher_details: false`, which the tests set) the
answer is always 404.

It is `GET` only and sits in the endpoint ahead of the request logger, so
polling does not fill the log it shows.

## The secret

A launcher makes one per start (random, at least 16 characters; the Windows
launcher uses 48 hex digits, the Mac app two UUIDs without dashes) and passes
it to the release in `ALNASL_LAUNCHER_TOKEN`. Nothing is written to disk.

A release started without it (`alnasl.sh`, the systemd service, a terminal)
makes its own and writes it to `<data>/run/launcher.token`:

```
<secret>
<port>
```

mode `0600` in a `0700` directory on Linux and macOS (on Windows the profile
folder's own rights apply), written empty-then-chmod-then-filled so the secret
is never in a readable file, and deleted on a clean stop. A crash leaves it;
the next start overwrites it, and an old secret opens nothing. `<data>` is the
folder holding `alnasl.db`.

## The answer

`200`, `application/json`, `cache-control: no-store`. `?lang=nl` words the
`summary` in Dutch; anything else is English. Typical cost is a millisecond or
two: nothing reads a table except `count(*)` on tournaments, boards and the
pending part of the outbox.

```json
{
  "app": "alnasl",
  "version": "0.1.4",
  "uptime_s": 3121,
  "started_at": "2026-10-14T19:40:12Z",
  "system": {"os": "windows", "os_version": "10.0.26100", "arch": "x86_64-pc-windows",
             "cores": 8, "otp": "29", "elixir": "1.20.3", "load_average": null},
  "beam": {"memory_bytes": {"total": 0, "processes": 0, "ets": 0, "binary": 0, "code": 0},
           "processes": 420, "schedulers": 8, "run_queue": 0, "cpu_percent": 0.8},
  "database": {"path": "C:\\Users\\...\\AlnaslData\\alnasl.db", "size_bytes": 4096000,
               "wal_bytes": 41232, "ping_ms": 0.12,
               "slow_queries": [], "slow_threshold_ms": 100},
  "log": {"source": "file", "path": "C:\\Users\\...\\AlnaslData\\launcher.log"},
  "alnasl": {"live_views": 2, "tournaments": 1, "boards": 8, "boards_connected": 8,
             "buses_open": 1, "outbox_pending": 0, "relay": "connected"},
  "summary": [
    {"label": "Version", "value": "Alnasl 0.1.4"},
    {"label": "Boards connected", "value": "8 of 8"}
  ]
}
```

| field | meaning |
|---|---|
| `uptime_s`, `started_at` | since the runtime started |
| `system.load_average` | Linux only (`/proc/loadavg`), `null` elsewhere |
| `beam.cpu_percent` | scheduler utilisation since the previous request; `null` on the first request of a start |
| `database.ping_ms` | a `SELECT 1` through the pool; `null` if it failed |
| `database.slow_queries` | the last five queries of 100 ms or more since the start, newest first; the query text cut at 160 characters (placeholders, never the values) |
| `log.source` | `file` (a launcher's `launcher.log`), `journald` (with `unit`, under systemd) or `stdout` (a terminal) |
| `alnasl.boards` | boards set up; `boards_connected` those with a running process and driver |
| `alnasl.buses_open` | serial buses open (one per port). Counted from the registry: **no port is opened or touched to answer this** |
| `alnasl.outbox_pending` | messages for the results site not sent yet |
| `alnasl.relay` | `unconfigured`, `disabled`, `idle`, `connected`, `offline` or `blocked`. No address and no error text: those can name the arbiter's server, and the panel gets pasted into mails |
| `summary` | the same numbers as label/value lines in words and units, in a fixed order (`Alnasl.LauncherDetails.Stats.labels/1`) |

No token, no key, no player or game data is in the answer. Fields are added,
not renamed; a reader ignores what it does not know.

## Showing it

- **Windows** (`rel/windows/launcher.c`): *Details* beside the buttons grows
  the window with the summary (every 2 s, WinHTTP), the last 500 lines of
  `launcher.log` (every second, opened with every share flag so the server's
  writes are never blocked; left alone while somebody has scrolled up or
  selected), *Copy* (title, summary, log path and the last 200 log lines) and
  *Open log folder*. English or Dutch, like the rest of that window.
- **macOS** (`rel/macos/Launcher.swift`): *Details* (also Cmd-D) opens a
  window of its own with the summary (every 2 s, `URLSession`), the end of
  `<data>/logs/server.log` (every second), *Copy* and *Open log folder*
  (Finder, file selected).
- **Linux and macOS terminals** (`./alnasl.sh details`, built on
  `bin/alnasl eval`): refreshes every 2 s with the last 20 log lines below
  (`q` or Ctrl-C quits); `--once` prints one snapshot, `--json` the raw answer.
  It reads `<data>/run/launcher.token`, so it must run as the user Alnasl runs
  as. On an installed Linux box:
  `sudo -u alnasl env ALNASL_DATA=/var/lib/alnasl RELEASE_TMP=/tmp RELEASE_DISTRIBUTION=none /opt/alnasl/current/bin/alnasl eval "Alnasl.LauncherDetails.CLI.main()" --once`.
  A `journald` log is read with `journalctl -u alnasl.service` when the
  account may; otherwise it says how.

# Alnasl on macOS

Since 2026-10-14 every push to `main` builds **`Alnasl.app`** for Apple
Silicon Macs, and a release attaches it, together with a build for **Intel
Macs** (from macOS 10.13; built only for a release, see
[Intel Macs](#intel-macs)). Nobody on the project has a Mac:
everything here was built and started on GitHub's macOS runners, and the
[test list](#testing-a-build-on-a-real-mac) at the end is what a person
with a Mac (and ideally an electronic board) still has to confirm.

| | |
|---|---|
| Apple Silicon (M1 and later) | `alnasl-macos-aarch64.zip`, built on `macos-15` |
| Intel | `alnasl-macos-x86_64.zip`, built on `macos-15-intel`, only for a release or a hand-started run |
| Runtime | Erlang/OTP 29.0.5 compiled on the runner by `rel/macos/build_otp.sh`, for macOS 11, with OpenSSL 3.5 compiled the same way and linked into `crypto` statically; Elixir 1.20 from its own precompiled zip. Cached, so only the first run with a given set of versions pays. Linux and Windows use `erlef/setup-beam`; on macOS that would be `erlef/otp_builds`, which is built for macOS 15 and made the app refuse to open on 14 (see [Why the runtime is built here](#why-the-runtime-is-built-here)) |
| Serial library | `circuits_uart`, compiled on the runner (`ALNASL_UART=1`, on by default on any Unix); the build stops if it is missing |
| Oldest macOS | Apple Silicon: 11 (Big Sur); Intel: 10.13 (High Sierra), see [Intel Macs](#intel-macs). Everything compiled on the runner is built for it (`MACOSX_DEPLOYMENT_TARGET` is the target's `macos_min` in the workflow: 11.0, or 10.13 for Intel; the SQLite NIF from source with `EXQLITE_FORCE_BUILD`), and `build_app.sh` fails the build, naming the files, if any binary asks for newer; what they accept goes into `Info.plist` |
| Signed | ad-hoc only, for now - see [Unsigned, for now](#unsigned-for-now) |

## What the app is

```
Alnasl.app/Contents/
  Info.plist              rel/macos/Info.plist, version from the release's VERSION
  MacOS/Alnasl            rel/macos/Launcher.swift, compiled (arm64, macOS 11+; x86_64, macOS 10.13+)
  Resources/launcher.sh   rel/macos/launcher.sh
  Resources/app/          the release (bin/alnasl), whole
  Resources/Alnasl.icns   from rel/macos/Alnasl-icon.png
```

`rel/macos/build_app.sh` builds it on the runner and compiles the launcher
there with `swiftc` (plain AppKit, one file, no Xcode project). The icon is
`rel/macos/Alnasl-icon.png`, 1024 pixels with Apple's margin, drawn from
`priv/logo/mark.svg` by `rel/windows/build_icon.py` like the Windows one.
The two halves:

- **`Launcher.swift`** is what you see. A normal **Dock icon**: the running
  dot, *Options > Keep in Dock*, Cmd-Tab. A **small window** - "Alnasl is
  running at http://localhost:4040", *Open in browser*, *Stop Alnasl* - in
  English, or Dutch when the Mac's first language is Dutch. Closing the
  window only hides it; clicking the Dock icon brings it back, and the Dock
  icon's menu has *Open in browser* too. The browser opens by itself once
  the site answers.
- **`launcher.sh`** is what it runs: the release, with distribution off and
  everything it writes outside the bundle; it waits until the port answers
  and stops the server on SIGTERM (clean `init:stop()`, twenty seconds, then
  insists). It also watches its parent: if the app is force-quit, the server
  goes with it.

**Quitting stops the server.** *Stop Alnasl*, Cmd-Q and the Dock's *Quit*
**ask first**, as on Windows: while Alnasl is stopped the boards are not
read. Logging out and shutting down do not ask (a question would only hold
up the logout) and stop it cleanly. A second start opens the browser at the
running copy instead of a second server. If the server stops by itself, the
app says so and names the log.

Until 2026-10-14 the launcher was the shell script alone, with an
AppleScript `display dialog` for a window and `LSUIElement` set: no Dock
icon, nothing to keep in the Dock. The Swift half exists for that.

Nothing is written into the app: a fresh download runs from a read-only,
"translocated" copy, and a write would break the bundle's seal. The
release's runtime files go to the temporary folder and crash dumps to the
data folder; CI starts the app from a read-only bundle and checks its seal
afterwards.

There is no "Start with macOS" switch (Windows has one). Add the app to
*System Settings > General > Login Items* if the box should start with the
Mac.

## Details

The app's window has a *Details* button (Cmd-D too). It opens a window of its
own with the numbers the running server reports about itself and the end of
`logs/server.log`, with *Copy* (numbers plus the last 200 log lines, for a
mail) and *Open log folder* (Finder, the file selected). The app makes a
secret at every start and hands it to the server in `ALNASL_LAUNCHER_TOKEN`;
the server answers `GET /_launcher/stats` only to this machine, only with that
secret and only without a proxy header. Nothing is written to disk and no port
is opened. The contract is `docs/launcher-details.md`.

## Where the data is

`~/Library/Application Support/AlnaslData` - the database, the PGN, the
recordings, the codes and keys, and `logs/server.log` - the server's output
for the current run (a fresh file on every start; the previous run is kept
once as `server.log.1`). Never inside the app:
replacing the app (an update) or binning it (an uninstall) leaves it alone.
`Alnasl.DataHome` refuses to start with a data folder inside any `.app`
(`ALNASL_DATA` included), and `test/alnasl/data_home_test.exs` holds the
module, the launcher and the scripts to the same names.

## Updates

**The update notice says what to do; it does not install.** On a Mac,
Setup > Updates says "Mac: download the new zip from the page above, stop
Alnasl, and put the new Alnasl.app in place of the old one", gives the size
of the right zip (`Alnasl.Updates.asset_name/2` knows the Mac names), and
links to the release. The install kind is `:manual`, the same as the
Windows portable zip; Setup's "This copy of Alnasl" says *The Mac app*.

Velopack (which updates the Windows copy in place) was considered and not
used, for now:

- On Windows the update is applied by the launcher, through
  `velopack_libc.dll`. A Mac would need a compiled launcher with Velopack's
  macOS library and its install hooks: a second native program, written
  blind.
- Velopack's Mac installer is a `.pkg` installing into `/Applications` as
  root, so an update in place needs an administrator.
- Unsigned, the `.pkg` meets the same Gatekeeper refusal as the app, and
  nobody has tried an update over an ad-hoc signed bundle.

Worth another look once the app is signed and can be tested on a Mac. The
feed would be `releases.osx.json` beside `releases.win.json`.

## Intel Macs

macOS 10 exists only on Intel Macs, so the Intel build is also the one that
reaches back. It is `alnasl-macos-x86_64.zip`, compiled on GitHub's Intel
runner (`macos-15-intel`; a real Intel machine, nothing is cross-compiled)
with `MACOSX_DEPLOYMENT_TARGET=10.13`, which `build_otp.sh` and
`build_app.sh` read like the Apple Silicon build reads 11.0. The serial
program (`circuits_uart`'s C port) and the SQLite NIF are compiled by the
same `mix` run, natively, for the same target: nothing extra is needed for
x86_64.

It is built **only when a release is published** (a version bump on `main`
with its changelog section) **or when the workflow is started by hand**
(*Actions > Build and release > Run workflow*), never on an ordinary push or
pull request: the Intel runner is slow, and on every push it cost about
thirteen minutes, which is why Intel was dropped on 2026-10-14. The `plan`
job in `release.yml` decides, from the release's own two conditions, and
adds the Intel target to the build matrix when it should run. A release that
cannot build for Intel is not published. A hand-started run on a branch
builds and uploads the zip as an artifact and publishes nothing: the
`release` job runs on `main` and on tags only.

Alnasl picks the zip that matches the Mac it is on (`Alnasl.Updates.arch/0`):
an Intel Mac gets `macos-x86_64`, an Apple Silicon Mac `macos-aarch64`, and
an Intel build running under Rosetta on an Apple Silicon Mac still counts as
Apple Silicon (`sysctl.proc_translated`).

### How far back

10.13 (High Sierra) is where the Intel build stops. The smoke test's log
lists the `minos` of every Mach-O file in the bundle (`vtool -show-build`)
and `LSMinimumSystemVersion` from `Info.plist`, which the test compares
with the target. Erlang/OTP 29 and OpenSSL 3.5 build with a 10.13 target
without patches. The launcher is Swift, and macOS before 10.14.4 has no
Swift runtime: the libraries it uses are copied into `Contents/Frameworks`
by `swift-stdlib-tool` and found through an `@rpath`. The few Foundation and
AppKit calls newer than 10.13 that `Launcher.swift` makes ask `#available`
and use the older call on 10.13.

**Not tested on a real Mac running 10.13.** The runner is macOS 15. CI
proves that nothing in the bundle asks for more than 10.13 and that the app
starts and answers on a current macOS; whether 10.13 runs it is for the test
list below, on a Mac that old.

## Unsigned, for now

There is no Apple Developer account yet. Every binary in the app carries
an ad-hoc signature (Apple Silicon runs nothing without one), but
Gatekeeper does not know who made it.

**Opening it the first time** (once per download):

- **macOS 15 Sequoia and newer**: double-click; macOS says it could not
  verify the app. Click *Done*. *System Settings > Privacy & Security*,
  scroll down to "Alnasl was blocked...", **Open Anyway**, confirm with your
  password or Touch ID, *Open*. (Right-click > Open no longer does it on
  Sequoia.)
- **macOS 14 and older**: right-click the app, **Open**, then *Open*.
- **"Alnasl is damaged and can't be opened"**: it is not. In Terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Alnasl.app
  ```

**What can still ask, signed or not:**

- *"Do you want the application beam.smp to accept incoming network
  connections?"* - when the macOS firewall is on and Setup lets other
  machines in the hall in. Allow it, or the arbiter's laptop and the phone
  cannot reach the box. A box that answers only itself never asks.
- *Local network* (macOS 15 and newer) - may be asked the first time the box
  sends to an OpenPairings or a results site on the hall's network. Allow
  it, or those sends fail; *System Settings > Privacy & Security > Local
  Network* switches it back on.
- **The serial port asks nothing.** The USB adapter may need a driver:
  FTDI adapters work as they are; Prolific (PL2303), WCH (CH340/CH341) and
  Silicon Labs (CP210x) ones may need the chip maker's driver, depending on
  the adapter and the macOS version. A board plugged in with no `cu.` port
  appearing (Terminal: `ls /dev/cu.*`) is that.

**Signing, when the account exists**, is five repository secrets -
`APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
`APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_PASSWORD` - see
[releasing.md, "Signing the Mac app"](releasing.md#signing-the-mac-app). The
step is in the workflow already and skips itself while they are missing.
Then the first start is a double-click.

## Serial ports on a Mac

Every adapter appears twice, `/dev/tty.usbserial-XXXX` and
`/dev/cu.usbserial-XXXX` (a USB board: `usbmodem...`). The `tty.` one is
for dial-in and waits for a carrier signal a board never sends, so Alnasl
lists only the `cu.` one (`Arkab.Transport.Uart.one_per_device/1`). Pick
`/dev/cu.usbserial-...` or `/dev/cu.usbmodem...`; `Bluetooth-Incoming-Port`
and `debug-console` are the Mac's own and never a board.

## Why the runtime is built here

Until 2026-10-17 the Mac job took Erlang from `erlef/setup-beam`, as Linux
and Windows still do. On macOS that is `erlef/otp_builds`, which is built
on the newest runner without a deployment target, so `beam.smp`, `erlexec`
and the OTP NIFs all said "macOS 15 or newer" (`minos 15.0` in
`LC_BUILD_VERSION`), and the precompiled SQLite NIF said 14.0. The build
script wrote the newest of those into `LSMinimumSystemVersion`, faithfully,
and a Mac on 14.6 answered *You can't use this version of the application
with this version of macOS*.

So now `rel/macos/build_otp.sh` compiles OpenSSL (static) and Erlang/OTP
(no wx, no Java, no ODBC, no docs) with `MACOSX_DEPLOYMENT_TARGET=11.0`,
checks each download against a SHA-256 in the script, and installs Elixir's
precompiled zip for that OTP major. `actions/cache` keeps the result under a
key of the OTP, OpenSSL and Elixir versions, the target, the runner and the
script itself. The versions are in the workflow's `env`; a version bump
also needs its checksum in the script, which fails loudly without one.
`exqlite` is compiled from source on the Mac (`EXQLITE_FORCE_BUILD=true`,
read in `config/config.exs`), and the deployment target is in the deps
cache key so a NIF built for another macOS cannot come back from it.

`build_app.sh` fails the build if any Mach-O file in the bundle asks for a
macOS newer than 11.0, and prints each of them with its `minos`. It used to
only report the number, which is how 15.0 shipped.

## What CI checks on every push

In the macOS jobs of `.github/workflows/release.yml`:

1. `build_app.sh`: `Launcher.swift` compiles (swiftc's errors become
   annotations on the run); the serial program is in the release; every
   binary links only to the system - `/usr/lib` (the Swift runtime in
   `/usr/lib/swift` included) and `/System`; none asks for a macOS newer
   than 11.0 (the build fails and names the files), and the oldest macOS
   they accept goes into `Info.plist`; the ad-hoc signature verifies.
2. The zip is unpacked as an arbiter would, the bundle made read-only, the
   serial library loads from inside it (`Uart.available?()` is `true`).
   `Info.plist` has no `LSUIElement`, and `CFBundleExecutable` is a Mach-O
   arm64 executable.
3. The bundle's own executable, with `--headless` (no window, no browser;
   it runs `launcher.sh` and passes signals on), starts it with a scratch
   data folder on port 4046. It must serve its help page on
   `127.0.0.1:4046` alone, without `epmd`.
4. A second start must leave at once.
5. SIGTERM to the launcher must stop the server, leaving nothing running;
   the bundle's seal must still verify; the database must be in the data
   folder.

The zip is uploaded as the workflow artifact `release_assets_macos-aarch64`
on every push, and attached to the release when one is
published. What CI cannot check: the window, the Dock, Gatekeeper on a
download, a real board. That is the list below.

## Testing a build on a real Mac

For the owner's M1 Pro, before anything is released. About twenty-five
minutes, plus the board.

**Get the build**

1. On GitHub: **Actions > Build and release**, open the newest green run
   (for `main`, or for the branch you were asked to test - *Run workflow* on
   that branch builds one without publishing anything).
2. Under *Artifacts*, download **`release_assets_macos-aarch64`** (signed in
   to GitHub).
3. Open it until you have **`Alnasl.app`** (the artifact is a zip holding
   `alnasl-macos-aarch64.zip`, which holds the app).
4. Drag `Alnasl.app` into **Applications**.

**First start**

5. Double-click it. Expect macOS to refuse; follow
   [Opening it the first time](#unsigned-for-now). Note the message you saw.
6. Expect within about ten seconds: an Alnasl icon in the **Dock** with a
   running dot (the white tile with the squares, sized like its
   neighbours), a small window **"Alnasl is running at
   http://localhost:4040"** (in Dutch if your Mac is in Dutch) with *Stop
   Alnasl* and *Open in browser*, and the browser on Alnasl's site. No
   Terminal window.
7. Setup, *This copy of Alnasl*: version as on the run's commit, started as
   **The Mac app (Alnasl.app)**, data folder
   `/Users/<you>/Library/Application Support/AlnaslData`.

**The data folder**

8. Finder > *Go > Go to Folder...* >
   `~/Library/Application Support/AlnaslData`: `alnasl.db`,
   `secret_key_base`, `logs/server.log`.

**A board**

9. Plug in the electronic board (USB, or RS232 through its adapter). In Terminal,
   `ls /dev/cu.*` should list a `cu.usbmodem...` or `cu.usbserial-...`. If
   nothing new appears, the adapter needs its driver (see above) - note the
   adapter's make.
10. Boards page, add an electronic board: the port list shows the `cu.` port, and no
    `tty.` twin. Pick it and connect: the board's picture appears, with its
    serial number. Move a piece: the picture follows.
11. (If an OpenPairings is at hand) a connect code in Setup, *Test
    connection*. Note any "Local network" question macOS asks.

**Running, stopping**

12. Close the browser tab, *Open in browser*: it comes back. Cmd-Tab:
    Alnasl is in the list.
13. Close the small window (red button): the Dock icon keeps its dot and
    the board keeps being read. Click the **Dock icon**: the window comes
    back. Right-click the Dock icon: *Open in browser* opens a tab; choose
    *Options > Keep in Dock*.
14. Double-click the app in Applications again: a browser tab, still one
    Dock icon, no second server.
15. **Stop Alnasl**: it asks first ("the boards are not read while it is
    stopped"). *Keep running* keeps it; *Stop Alnasl* stops it: the app
    goes (the kept icon stays, without a dot), `http://localhost:4040` no
    longer answers, *Activity Monitor* has no `beam`.
16. Start it again **from the Dock icon**: no Gatekeeper question; the board
    is still known by its number. Quit with **Cmd-Q**: the same question,
    and the same clean stop. Start it again and quit with the Dock icon's
    *Quit*: likewise.
17. With it running, log out and back in: no question holds up the logout,
    and it starts normally afterwards.

**Updates**

18. Setup > Updates: the setting is there; *Look now* says nothing newer for
    the newest build. If a newer release exists, the notice gives the size
    of `alnasl-macos-aarch64.zip` (or `alnasl-macos-x86_64.zip` on an Intel Mac) and the Mac line of what to do - no
    *Download and install* button. That is intended on a Mac.

**Removing it**

19. Quit Alnasl, drag it from Applications to the Bin, empty the Bin.
20. `~/Library/Application Support/AlnaslData` is **still there**.
21. Install again (3-5): the board and its number are back.

**Report back**: macOS version, the Gatekeeper message (step 5), the
adapter and whether a driver was needed (step 9), any step that went
otherwise, and `logs/server.log` if something failed. Delete the data folder
yourself afterwards if you want everything gone; the app never does.

# Fair-play calibration: the run sheet for the 80-core VM

One Linux machine, 80 cores, 251 GB of memory, about 180 GB free, reached
as `root@172.16.63.81`. Everything lives under `/root`; nothing is
installed system-wide. The general recipe and what the output means are in
`docs/fair-play-calibration.md`; the statistics in `docs/plan-fair-play.md`
(§5).

The run has two steps. **Label** (hours, all cores): replay each game,
ask Stockfish about every position that counts, write one JSON line per
game. **Fit** (minutes, one core): turn the lines into
`priv/fair_play/model-sf19.json`. Labelling is the expensive half and can
run from either the release tarball or a checkout; fitting must use code
from the `fairplay-2` branch or later, because that is where the holdout by
event, the covariance and the false-positive table are.

Downloads below (Erlang, Elixir, Stockfish, the games) are fetched by the
VM from their publishers. Nothing in this sheet downloads anything on the
person's own computer.

## 0. What it costs, roughly

Not yet measured on this machine: the number to trust is the one the label
task prints itself (section 4). The estimate:

| | |
| --- | --- |
| games to label | ~15,000 standard-time games with both players rated |
| positions asked per game | ~65 (the rest are opening, forced, decided, repeated) |
| seconds per position per engine | 0.8 to 1.0 at 1,000,000 nodes, one thread (the plan's figure) |
| engines | 78 (two cores left for the BEAM and the shell) |
| wall time | 975,000 positions × 0.8-1.0 s / 78 ≈ **3 to 3.5 hours**; up to **7 hours** if the 80 "cores" are 40 cores with hyper-threading |
| memory | 78 × 64 MB of hash ≈ 5 GB, plus about 2 GB for the BEAM |
| disk | the games ~1-3 GB compressed, the labels ~1 GB |

The figure to replace the estimate with is printed on the label task's last
line (and every 50 games): `s per position per engine`. Multiply by the
positions still to go and divide by the engines.

## 1. The code, onto the VM

`git clone` over https may not work there. From a checkout on your own
computer, on the branch to run:

```sh
git archive --format=tar.gz --prefix=alnasl/ -o alnasl-src.tar.gz HEAD
scp -i ~/.ssh/photon_openpair alnasl-src.tar.gz root@172.16.63.81:/root/w-fairplay-2/
```

On the VM:

```sh
mkdir -p /root/w-fairplay-2 && cd /root/w-fairplay-2
tar -xzf alnasl-src.tar.gz          # -> /root/w-fairplay-2/alnasl
```

`git archive` takes what is committed, with LF line endings and the
execute bits as the repository has them; a copy of the working tree from
Windows would not.

## 2. Erlang and Elixir, under /root

Erlang/OTP **29** and Elixir **1.20** (what CI uses). OTP 28 or later is a
must: the games are read as `.pgn.zst`, through OTP's `:zstd`.

Prebuilt, no compiler needed, nothing outside `/root`:

```sh
cd /root/w-fairplay-2
. /etc/os-release && echo "$ID $VERSION_ID"     # e.g. ubuntu 24.04

# Erlang/OTP 29, built by Hex for this distribution (pick the one that matches)
curl -fLO https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-29.0.tar.gz
mkdir -p otp && tar -xzf OTP-29.0.tar.gz -C otp --strip-components=1
(cd otp && ./Install -minimal "$PWD")

# Elixir 1.20, precompiled for OTP 29
curl -fLO https://github.com/elixir-lang/elixir/releases/download/v1.20.3/elixir-otp-29.zip
mkdir -p elixir && (cd elixir && unzip -q ../elixir-otp-29.zip)

cat > env.sh <<'EOF'
export PATH=/root/w-fairplay-2/otp/bin:/root/w-fairplay-2/elixir/bin:$PATH
export MIX_HOME=/root/w-fairplay-2/.mix HEX_HOME=/root/w-fairplay-2/.hex
export MIX_ENV=prod ERL_AFLAGS="+S 80:80"
# prod insists on a writable data directory, even for a task that stores nothing there
export ALNASL_DATA=/root/w-fairplay-2/data
EOF
mkdir -p /root/w-fairplay-2/data
. ./env.sh
erl -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)]), halt().'   # 29
elixir --version                                                                     # 1.20.x
```

If Hex has no build for the distribution, either take the Alnasl Linux
release tarball for **labelling** (it carries its own Erlang; see
`docs/fair-play-calibration.md` §1 - its labels are the same format and fit
fine with this branch), or ask for the toolchain to be installed another
way. Do not install Erlang system-wide for this.

Then the project:

```sh
cd /root/w-fairplay-2/alnasl
mix local.hex --force && mix local.rebar --force
mix deps.get --only prod
mix compile
```

## 3. Stockfish 19 and the games

Stockfish, through the same installer the halls use: it checks the
archive's SHA256
(`9defc0d4e55d49c65a6d042f3e571a39fcea499ade6dbe741b53b8c65e03611f` for
`stockfish-linux-x86-64-universal.tar.gz`), unpacks it and runs `bench`,
which must say **2497913**:

```sh
cd /root/w-fairplay-2
curl -fLO https://github.com/official-stockfish/Stockfish/releases/download/sf_19/stockfish-linux-x86-64-universal.tar.gz
sha256sum stockfish-linux-x86-64-universal.tar.gz      # compare by eye too
(cd alnasl && mix run --no-start -e '
  IO.inspect(Alnasl.FairPlay.Installer.install(
    {:file, "/root/w-fairplay-2/stockfish-linux-x86-64-universal.tar.gz"},
    platform: :linux_x86_64, dir: "/root/w-fairplay-2/sf19"))')
# => {:ok, %{path: "/root/w-fairplay-2/sf19/stockfish-linux-x86-64-universal", bench: 2497913, ...}}
```

The games: Lichess broadcast months, 2024-2025, from
<https://database.lichess.org/#broadcasts> (CC BY-SA 4.0). Look at the
sizes listed on that page before fetching; months are tens of MB each,
compressed, and grow towards 2025. Keep them compressed; the task reads
`.zst` as a stream.

```sh
mkdir -p /root/w-fairplay-2/games && cd /root/w-fairplay-2/games
for y in 2024 2025; do for m in 01 02 03 04 05 06 07 08 09 10 11 12; do
  curl -fLO https://database.lichess.org/broadcast/lichess_db_broadcast_$y-$m.pgn.zst || echo "missing $y-$m"
done; done
ls -la && du -sh .
```

## 4. Label, detached

A quick measurement first, a few games, so the hours below are a number
and not a guess:

```sh
cd /root/w-fairplay-2/alnasl && . ../env.sh
mix fair_play.label --engine /root/w-fairplay-2/sf19/stockfish-linux-x86-64-universal \
  --engines 78 --games 100 --out /root/w-fairplay-2/try.jsonl \
  /root/w-fairplay-2/games/*.pgn.zst
# last line: N games, M positions, ... s per position per engine
```

Then the real run, in the background, with its log:

```sh
cd /root/w-fairplay-2/alnasl && . ../env.sh
nohup mix fair_play.label \
  --engine /root/w-fairplay-2/sf19/stockfish-linux-x86-64-universal \
  --engines 78 --shard 1/1 --games 15000 \
  --out /root/w-fairplay-2/labels-1.jsonl \
  /root/w-fairplay-2/games/*.pgn.zst \
  > /root/w-fairplay-2/label-1.log 2>&1 &
echo $! > /root/w-fairplay-2/label.pid
```

- `--engines 78`: one engine per core (`Threads 1`, `Hash 64`), two cores
  left over. More engines than cores only makes each slower.
- `--nodes` stays at its default, 1,000,000: the model belongs to that
  node count, and the halls analyse at the same.
- `+S 80:80` (in `env.sh`) gives the BEAM one scheduler per core; the
  engines are separate processes and do not need schedulers of their own.
- Progress: `tail -f /root/w-fairplay-2/label-1.log` (a line every 50
  games, with games per minute and seconds per position per engine).
- Is it alive: `kill -0 $(cat /root/w-fairplay-2/label.pid) && echo running`;
  `ps -o pid,etime,cmd -p $(cat /root/w-fairplay-2/label.pid)`.

**Resumable.** The labels file is the progress: after a crash, a reboot or
a `kill`, run the same command again. It reads `labels-1.jsonl`, skips
every game already in it, drops a last line a crash left half-written, and
appends the rest. `--games 15000` counts what is in the file, so a second
run stops at the same total. To split the work into pieces that can be
stopped and started separately, run `--shard 1/4` ... `--shard 4/4` one
after another (each with its own `--out` and `--engines 78`); the shards
never share a game.

## 5. Fit, and fetch the model

On the VM (one core, a few minutes):

```sh
cd /root/w-fairplay-2/alnasl && . ../env.sh
mix fair_play.fit --holdout 0.67 \
  --out /root/w-fairplay-2/model-sf19.json \
  /root/w-fairplay-2/labels-*.jsonl | tee /root/w-fairplay-2/fit.log
```

- `--holdout 0.67`: two thirds of the **events** are held out, about
  10,000 games, about 2,500 to 3,000 player-events with 40 counted moves.
  That is the size the gate needs: showing "under 1 in 700 at 3 or more"
  takes at least 2,583 held-out player-events with none that high. The fit
  keeps about 5,000 games, the same as phase 1 planned.
- The log ends with the false-positive table and the gate's verdict:
  *passed*, *passed, not proven* (the point estimate is fine but there are
  too few player-events to prove it - label more games), or *failed*
  (the model does not ship).

Back on your own computer, into the checkout:

```sh
scp -i ~/.ssh/photon_openpair root@172.16.63.81:/root/w-fairplay-2/model-sf19.json priv/fair_play/model-sf19.json
scp -i ~/.ssh/photon_openpair root@172.16.63.81:/root/w-fairplay-2/fit.log .
```

Keep the labels on the VM until the model is merged: a fit with other
settings needs only them, not another day of Stockfish.

## 6. The first run, 2026-10-21

What came out, so the next run has something to beat.

- **Labelled:** 15,000 games (`--engines 78`), 997,614 positions, 52,625 s
  (14.6 hours): 17.1 games a minute, **4.1 s per position per engine**,
  four to five times the estimate in section 0. The 80 "cores" do not
  behave like 80 cores. Budget an hour per 1,000 games.
- **Which games:** the task takes games in file order, so `--games 15000`
  took January, February and half of March 2024 and nothing else. The
  24 months hold 233,002 games the classical filter keeps (the old
  filter, before it read minutes and clocks, kept 12,700 of them).
  A wider spread needs the months passed in a different order, or shards
  per month.
- **Fit** (`--holdout 0.67`, 28 s): 5,481 games fitted, 9,479 held out by
  broadcast, 3,203 held-out player-events with 40 counted moves.
- **False positives** (held out): 2.0 or more 54 (1.69%, 95% 1.27-2.19%);
  2.5 or more 13 (0.41%); 3.0 or more 2 (0.06%, 95% 0.01-0.23%); 3.5 or
  more 1; 4.0 or more none (95% upper bound 0.12%).
- **Gate:** passed on the point estimate (about 1 in 1,600 at 3), not
  proven: the upper bound, 0.23%, is above 1 in 700. With two events at 3
  it takes about 5,000 held-out player-events, roughly 15,000 held-out
  games, to prove it.
- **Covariance:** the three z's have variances 1.63, 1.82 and 1.84 on the
  fitting player-events, not 1: the overdispersion section 5 of the plan
  warned about, now divided out.
- **Per band:** 1400-1799 players reach 2 more often (3.3-3.7%) than the
  rest (0.5-1.8%); the 1000 band has 17 player-events, three of them at 2
  or more, too few to say anything.

## 7. The second model, 2026-10-22

The same 30,029 labelled games as the extended first run
(`/root/w-calibration/labels-ext.jsonl`, 15,000 from January-March 2024
plus 15,000 more, 2025 first), the same split (`--holdout 0.67`, the same
hash): 9,944 games fitted, 19,958 held out, **6,626 held-out
player-events** with a score. The first-form model's numbers were
reproduced exactly by a refit before anything was changed.

What changed (CHANGELOG, Unreleased): the per-game variance with
cross-fitted correlations, the rating spline and its interactions, no
score under 1000, three more features (evaluation, opponent's rating,
share of the clock used), format 2.

| | first form | items 2-4 only | second form (shipped code) | second form, band variant fit |
| --- | --- | --- | --- | --- |
| games fitted | 9,944 | 9,944 | 9,944 | 5,276 |
| >= 2.0 | 115 (1.74%) | 99 (1.49%) | 120 (1.81%) | 116 (1.75%) |
| >= 2.5 | 28 (0.42%) | 21 (0.32%) | 23 (0.35%) | 21 (0.32%) |
| >= 3.0 | **6 (0.09%, upper 0.20%)** | 3 (0.05%, upper 0.13%) | **4 (0.06%, upper 0.15%)** | 2 (0.03%, upper 0.11%) |
| >= 3.5 | 1 | 0 | 0 | 1 |
| gate | passed by default | passed | **passed by default** | passed |

"Items 2-4 only" is the intermediate commit (per-game variance, spline,
cross-fit, no features beyond the first form's). It is listed because it
was run, not because it may be picked: choosing between it and the
second form after seeing these held-out numbers would be tuning on the
test set. The four columns differ by one or two player-events at 3 out of
6,626, which is what Poisson noise looks like at this size; none of them
is shown to be better than another, and the second form is **not shown
to pass**. If the rate stays near 0.06%, the upper bound gets under 1 in
700 at about 10,000 held-out player-events, half again as many as now:
some 10,000 more labelled games at the same holdout.

Per band, second form (events, mean score, share at 2 or more): 1000
(that is, 1000-1199): 17, +0.80, 17.65%; 1200: 52, +0.13, 0.00%; 1400:
392, +0.04, 3.57%; 1600: 712, +0.10, 3.09%; 1800: 1111, −0.05, 1.71%;
2000: 1240, +0.01, 1.53%; 2200: 1564, +0.02, 1.73%; 2400: 1276, +0.06,
1.02%; 2600: 261, −0.03, 1.15%. The means are flatter than the first
form's (1000: +1.29, 1200: +0.49, 1400/1600: +0.13); the 1000-1199 band is
still wrong, and with 17 held-out player-events and a few dozen in the
fit, no model of this corpus can tell why. Under 1000 the corpus has six
player-games, now not scored.

The correlations measured (second form, cross-fitted): two moves of one
game correlate 0.014 (MM), 0.018 (EV), 0.022 (ASD); two moves of
different games of one player-event 0.003-0.005. Small numbers with
large effects: a 35-move game has 595 pairs of moves, so its variance is
about 1.5 times the independent one, and nine such games about 2.4 times.

**The per-band variant** (`--band-thresholds 0.4`, 4,668 training games
set aside to set the thresholds): thresholds between 2.84 (1600) and 3.44
(1400), 3.27 for 2600; held out, 2 of 6,626 at or over their band's
threshold (upper 0.11%), the same 2 as the plain score of that fit. It
flattens the share at 2 a little (1400: 3.57% to 1.28%) and does nothing
for the 1000-1199 band, whose threshold rests on two events. Not
adopted.

**The held-out hits at 3 or more.** First form: six. Second form: four.

| player-event (rating, opponents' average) | first form | items 2-4 | second form | why |
| --- | --- | --- | --- | --- |
| 1184 v 1482, 3 games, 72 moves | 3.74 | 3.15 | 3.49 | still there: the 1000-1199 band, which no version fits |
| 1496 v 2173, 3 games, 118 moves | 3.43 | 2.46 | 2.25 | its EV z was 7.7 under independent moves; three long games are three games, not 118 coins |
| 1974 v 2359, 1 game, 80 moves | 3.28 | 2.65 | 2.39 | one 80-move game, read as one game |
| 1466 v 1626, 8 games, 304 moves | 3.21 | 2.31 | 1.83 | a long event gets the spread of eight games, where the global covariance gave every event the average one's |
| 1537 v 2086, 3 games, 207 moves | 3.16 | 1.80 | 1.51 | long games again |
| 1564 v 1679, 3 games, 116 moves | 3.10 | 2.78 | 2.61 | the same, more mildly |
| 1839 v 1794, 2 games, 41 moves | 2.75 | 3.04 | 3.21 | new: a short event now gets less inflation than the average event did |
| 2345 v 2182, 5 games, 124 moves | 2.74 | 2.78 | 3.11 | new, from the added features |
| 2013 v 2203, 4 games, 98 moves | < 2.5 | 2.37 | 3.01 | new, from the added features |

`mix fair_play.hits` lists them with names; they are left out here.
Five of the old six went, and most of the drop is already in the items
2-4 column: the per-game variance, which no longer treats a long event and
a short one alike. The three new ones are short-to-medium events that the
old global inflation had been holding down, or that the added features
pushed over the line. None of this is evidence about any of these
players; it is evidence that the old variance was the wrong shape.

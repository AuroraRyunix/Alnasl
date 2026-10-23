# Fair-play calibration: the run

How `priv/fair_play/model-sf19.json` is made. The why is in
`docs/plan-fair-play.md` (§5); the code is `Alnasl.FairPlay.Calibration`.

For one big machine (the 80-core VM) the step-by-step run sheet is
`docs/fair-play-calibration-run.md`; this page is the general recipe.

Four Linux machines (x86-64), each on its own, with no cluster software
and no Elixir: each runs Alnasl's Linux release tarball, which carries its
own Erlang. One machine (or a checkout anywhere) fits at the end.

## 1. On every machine: Alnasl, Stockfish, the games

```sh
# Alnasl: the release tarball from GitHub (alnasl-linux-x86_64.tar.gz)
mkdir -p /opt/alnasl && tar -xzf alnasl-linux-x86_64.tar.gz -C /opt/alnasl
A=/opt/alnasl/alnasl/bin/alnasl

# Stockfish 19, the official linux-x86-64 universal build, checked by the
# same installer the halls use: digest, then bench (must be 2497913).
curl -LO https://github.com/official-stockfish/Stockfish/releases/download/sf_19/stockfish-linux-x86-64-universal.tar.gz
$A eval 'IO.inspect(Alnasl.FairPlay.Installer.install({:file, "stockfish-linux-x86-64-universal.tar.gz"}, platform: :linux_x86_64, dir: "/opt/sf19"))'
# => {:ok, %{path: "/opt/sf19/stockfish-linux-x86-64-universal", bench: 2497913, ...}}

# The games: Lichess broadcast months (database.lichess.org/#broadcasts,
# CC BY-SA 4.0), 2024-2025. Every machine needs the SAME files.
mkdir -p /data && cd /data
for m in 2024-01 2024-02 2024-03; do   # ...and so on, the same list everywhere
  curl -LO https://database.lichess.org/broadcast/lichess_db_broadcast_$m.pgn.zst
done
```

The `.pgn.zst` files are read compressed, as a stream; do not unpack them.

## 2. Label: one shard per machine

Machine K of 4 (K = 1, 2, 3, 4):

```sh
cd /data
nohup $A eval 'Alnasl.FairPlay.Calibration.main()' label \
  --engine /opt/sf19/stockfish-linux-x86-64-universal \
  --shard K/4 \
  --out /data/labels-K.jsonl \
  /data/lichess_db_broadcast_*.pgn.zst \
  > /data/label-K.log 2>&1 &
```

- Each machine reads every game, keeps standard time controls (first
  period at least 60 minutes) with both players rated, and of those only
  the games whose id hashes to shard K. The four files never share a game
  and together hold all of them.
- `--engines` defaults to the number of schedulers (one engine per core,
  `Threads 1`, `Hash 64` each: 64 MB of hash per core). `--nodes` defaults
  to 1,000,000; every machine must use the same.
- `--games N` stops once the file holds N games; leave it out for all.
- The bench is measured at the start and written into every line, with
  the engine's name and the node count.
- Progress is in the log every 50 games: `tail -f /data/label-K.log`.

**After a crash or a reboot**, run the same command again. It reads
`labels-K.jsonl`, skips the games already in it, cuts off a line the crash
left half-written, and appends the rest.

## 3. Fit

Copy the four files to one place, then (a checkout or any of the
machines):

```sh
scp machineK:/data/labels-K.jsonl .     # for K = 1..4

# from a release
$A eval 'Alnasl.FairPlay.Calibration.main()' fit \
  --holdout 0.2 --out model-sf19.json labels-*.jsonl

# or in a checkout
mix fair_play.fit --holdout 0.2 --out priv/fair_play/model-sf19.json labels-*.jsonl
```

- Files from different engines, benches or node counts are refused.
- A share of the **events** is held out (all of an event's games, never
  some of them), chosen by a hash of the event's name, so the same files
  always give the same split. `--holdout 0.2` is too little for the gate:
  see `docs/fair-play-calibration-run.md`, which uses about two thirds.
- It prints the held-out false-positive table - for 2.0, 2.5, 3.0, 3.5,
  4.0, 4.5 and 5.0, the share of player-events with at least 40 counted
  moves scoring that much or more, with the exact 95% interval - and, per
  200-point rating band, the number of events, the mean score and the share
  at 2 or more. The table goes into the model file and onto the report.
- The gate (plan §5): more than about 1 in 700 held-out player-events at 3
  or more and the model does not ship; "passed" needs the upper end of the
  interval under 1 in 700. The task says which, and how many held-out
  player-events it would have needed. "Passed by default" (the point
  estimate is under the line, the interval is not) does **not** ship.
- What is fitted on the training events: the two regressions and the loss
  table on all of them; the correlations the per-game variance is built
  from (`Alnasl.FairPlay.Cluster`) **cross-fitted** - the training events
  split in two by a hash of the event, a model fitted on each half, the
  correlations measured on the other half. Nothing is measured on the
  games it was fitted on.
- The model file is format 2 and lists its features. A format-1 file is
  refused (the report then says "not calibrated"), and so is a file whose
  features are not the code's.

### Who scored high

```sh
mix fair_play.hits --model model-sf19.json --holdout 0.67 [--threshold 3.0] labels-*.jsonl
```

The held-out player-events at or over the threshold, highest first: the
score, the three z's, the counted moves, the games, the rating, the
opponents' average rating, the player and the event. `--holdout` must be
the fit's, or the list is of games the model was fitted on.

### The per-game scan

The score is the larger of two z's (`Alnasl.FairPlay.Stats`): the event
score over all of a player's counted moves, and the **scan** - each game
of 20 or more counted moves scored on its own, standardised against honest
single games of its length, and the most unusual of them corrected for
how many games there were (`Alnasl.FairPlay.Scan` has the formula). One
engine game among nine barely moves the first and moves the second a
great deal. The fit measures the honest single games in its cross-fit,
from the same residuals as the correlations, and writes them into the
model as `"scan"`; a model file without them scores the event alone. The
held-out table above is of the larger of the two, so the rarity on the
report is that score's. The report says "decided by one game: round N"
when the scan is the larger, and gives no interval then.

### Per-band thresholds (a variant, off by default)

`--band-thresholds 0.4` on the fit keeps 40% of the **training** events
out of the fit, measures each 200-point band's mean and spread of scores
on them (`Alnasl.FairPlay.BandScale`: shrunk towards all bands with 50
pseudo-events, chosen in advance), and then judges the same held-out
events by `(score − mean_band) / sd_band` as well as by the plain score.
Three disjoint sets - fit, thresholds, test - so the test set never sets
a threshold. Both tables and both gates are printed; the model above is
then fitted on fewer games. The report does not use the variant.

### Power: how many cheaters it would catch

The false-positive table says how often an honest player is accused. A
score that accuses nobody passes it perfectly, so it is half a check.
The other half needs cheaters, and a corpus of broadcast games has none
anybody can name, so they are made up:

```sh
mix fair_play.power --holdout 0.67 [--model model-sf19.json] [--out power.json] labels-*.jsonl
# from a release
$A eval 'Alnasl.FairPlay.Power.main()' --holdout 0.67 labels-*.jsonl
```

**Method** (`Alnasl.FairPlay.Power`). The same split as the fit (same
`--holdout`, same hash); the model is fitted on the training events, or
read with `--model` (it must be the one fitted with that holdout). Every
held-out player-event with a score is scored as recorded (honest), then
once per cheating scenario: chosen counted plies get the played move
replaced by one of the label's own MultiPV lines, with `played_cp` and
`rank` taken from that line, so loss, match and equal-value match are
exactly what that move would have scored. What the model expects of a
ply does not depend on the move played, so only the residuals move.
Injection is seeded (`--seed`) per player-event and scenario, and every
scenario uses the same events: the comparisons are paired.

**The cheaters**, each at 5, 10, 20, 30 and 50% of the counted moves
(`--rates`):

| profile | what it does |
|---|---|
| naive | the engine's first choice on random moves |
| selective | the first choice on the player's worst moves (largest scaled loss; among equals, the fewest good alternatives): the "one move a game" cheat at 3-5% |
| camouflaged | on random moves, a line by lot among those within 40 cp of the best (`--window`), the best included: built to keep the match rate down |
| whole games k | every counted move of k games (`--games 1,2,3`), in events of more than k games |

**Output.** Per scenario, the share of cheating player-events at 2.0, 2.5,
3.0 and 3.5 with exact 95% intervals, beside the honest events' share at
the same thresholds (the false positives, same events), and the mean change
in each z (MM, EV, ASD): which test noticed. Then, at 3.0, each profile at
20% (and one whole game) by counted moves, games and rating.

**Probes.** Beside the three shipped tests, the benchmark scores three
more (`Alnasl.FairPlay.Probes`): error avoidance (fewer moves losing 0.5
or more than `P(error)` predicts, a logistic model on the model's
features), blunder avoidance (the same at 1.0), and hard ASD (the ASD
residual weighted by `P(error)`). They are fitted on the training events,
their correlations with everything else cross-fitted like the model's,
and they go into the variants below as weight vectors over the six. The
per-game scan is scored too, from a calibration measured the same way,
so a model file without one can still be judged with it.

**Variants, without tuning on the test.** The held-out events are split
once more by a hash of the event (`"power:"`, `--tune 0.5`): a tuning half
and a final half. Every choice - weights, a threshold that spends a given
false-positive budget (`--budget 0.01`), per-band scales - is made on the
tuning half and reported only on the final half. Compared: the default
weights `[1,1,1]`, each test alone, MM-heavy `[2,1,1]`, ASD-heavy `[1,1,2]`,
MM+ASD `[1,0,1]`, "fitted" (the grid vector with the most realistic power
on the tuning half), the per-band thresholds of `BandScale` with their
scales measured on the tuning half's honest scores, the probes added to
the three or instead of ASD, and the scan as `max(event, scan − offset)`
for offsets 0, 0.5 and 1 (with the scan in the default, "no scan" and
the two larger offsets; every weighting is then judged with the scan). Realistic power is
pooled over selective and camouflaged up to 30% and one whole game. Each
variant is judged (a) at its own budget threshold and (b) at the report's
3.0, with its paired difference from the default and a 95% interval. The
verdict names a variant only if it beats the default on the final half at
both, with no more held-out false positives at 3.0; among several, the
one with the largest paired gain at 3.0 on the tuning half. It also
prints each variant per realistic scenario at both thresholds, and one
whole game by the number of games in the event.

**Limitations.** Later plies stay as recorded: a real engine move would
have changed the opponent's reply and everything after, here the game goes
on as if the human move had been played. The clock and the time spent are
the honest player's. The cheater's engine is the labelling engine at its
node count. And the honest events are whatever the broadcasts held. The
numbers are therefore about this score on these positions, not a promise
about any particular cheater.

On one machine, both steps at once: `mix fair_play.calibrate --engine ...
--games 7000 --holdout 0.2 --out priv/fair_play/model-sf19.json files...`
(labels go to `<out>.labels.jsonl`).

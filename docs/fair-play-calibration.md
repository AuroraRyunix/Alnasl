# Fair-play calibration: the run

How `priv/fair_play/model-sf19.json` is made. The why is in
`docs/plan-fair-play.md` (§5); the code is `Alnasl.FairPlay.Calibration`.

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
- 20% of the games are held out, chosen by a hash of their id, so the same
  files always give the same split.
- It prints the held-out false-positive table (share of player-events with
  at least 40 counted moves scoring above 2, 3, 4 and 5) and, per 200-point
  rating band, the number of events, the mean score and the share above 2.
- The gate (plan §5): more than about 1 in 700 held-out player-events
  above 3 and the model does not ship. The task says so on its last line.

On one machine, both steps at once: `mix fair_play.calibrate --engine ...
--games 7000 --holdout 0.2 --out priv/fair_play/model-sf19.json files...`
(labels go to `<out>.labels.jsonl`).

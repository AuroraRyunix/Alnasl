# Fair-play screening, phase 3: a human-move model beside Stockfish

Status: research and pilot on branch `fairplay-maia`, 2026-10-20. Nothing
here is user-visible yet; no weights or data are in the repository.

Phase 1 and 2 ask Stockfish what the best move was and a small logistic
model how often a player of a given rating finds it (`docs/plan-fair-play.md`
§5). That logistic model knows four numbers about a position: the rating,
the gap from the best move to the second, how many moves are close, and the
material. It does not know whether the best move is a natural recapture a
1600 plays every time or a quiet rook lift a 2600 misses. A human-move
model does: given the position and the rating, it gives the probability of
every legal move. Using it as the "expected match" makes the expectation
position-specific, which narrows the spread of normal players' scores and
so the false positives at any threshold.

Every public Maia was trained on online games (Lichess blitz and rapid).
Over the board, at classical time controls, people play differently, and
FIDE ratings are not Lichess ratings. Phase 3 fine-tunes Maia-2 on
over-the-board classical games and measures whether that is better than
stock Maia-2 on events it has never seen.

## 1. Licences

| What | Licence | Verdict |
| --- | --- | --- |
| Maia-2 code (`CSSLab/maia2`, PyPI `maia2` 0.11.0) | MIT, "Copyright (c) 2024 CSSLab" | Fine. We use it only in the offline tools (`tools/maia/`), never in Alnasl. |
| Maia-2 weights (`rapid_model.pt`, `blitz_model.pt`, Google Drive links pinned by SHA-256 in the package) | **None stated.** The LICENSE speaks of "the Software and associated documentation files"; the weights are not in the repository and no model card exists | **Open question.** Unlicensed by default means all rights reserved. MIT probably was meant to cover them (the package downloads them itself), but "probably" is not a licence for weights we would modify and redistribute. |
| Maia-3 (`CSSLab/maia3`, Hugging Face `UofTCSSLab/Maia3-5M/23M/79M`, 2026) | Code **AGPL-3.0**; weights: no licence on the model cards | Not usable for us as things stand: an Apache-2.0 app cannot take AGPL code into its tree, a re-implementation of its architecture to run the weights would be a derivative, and the weights carry no licence at all. Recommended by its authors for new projects; worth a second look if they license the weights. |
| Maia-1 (`CSSLab/maia-chess`, Lc0 networks per rating band) | Code GPL-3.0; the networks sit in the GPL repository | Same problem as Maia-3 for shipping; and Maia-1 is one network per 100-point band up to 1900, useless for most OTB players. |
| Lichess broadcast database (`database.lichess.org/broadcast/`) | "Broadcast games are released under the Creative Commons Attribution-ShareAlike 4.0 license" (the standard game exports are CC0) | Fine for training. Whether a network trained on CC BY-SA data is an "adapted material" is unsettled; to be safe the fine-tuned weights carry the attribution and are offered under CC BY-SA 4.0 too, as `model-sf19.json` already is. |
| PyTorch, onnx, onnxruntime, python-chess | BSD / MIT / MIT / GPL-3.0 | python-chess is GPL: tools only, never in Alnasl (which already has its own move generator). |
| Ortex (`elixir-nx/ortex` 0.1.10) and ONNX Runtime | MIT / MIT | Fine to link from Apache-2.0. |

What follows for shipping:

- **Never in the repository or the release.** Like Stockfish, the network is
  downloaded when the owner switches the human model on, from a URL and a
  SHA-256 in Alnasl's source, and checked the same way. The ONNX file is
  85 MB (fp32); int8 would be about a quarter of that.
- **Where from.** Fine-tuned weights are a modified copy of CSSLab's, so
  someone hosts a derivative. That needs the weights' licence settled first.
  **Decision for the user:** write to CSSLab asking them to state that the
  Maia-2 weights are under MIT (or any permissive licence), and for their
  blessing to publish an OTB fine-tune with attribution. Until then, the
  fallback that needs no permission is to download CSSLab's own stock
  weights from their link at enable time and run them unmodified, which
  gives up the fine-tune.
- Training from scratch on OTB games alone (no CSSLab weights) would remove
  the question but not work: 24 months of broadcasts are ~20 M positions,
  Maia-2 was trained on billions.

## 2. Maia-2 as it is

- **Network.** ResNet stem (5 blocks, 256 channels) into a 2-layer
  transformer whose attention queries are shifted by a rating embedding
  (self and opponent); 23.3 M parameters. Three heads: move logits over a
  fixed 1,880-move vocabulary, an auxiliary head (moving piece, captured
  piece, check, from/to squares, legal moves) and a value head.
- **Input.** 18 planes of 8x8, always from the mover's side (a Black move
  is mirrored): 12 piece planes, side to move, four castling rights, the en
  passant square (only when the capture is legal, because maia2 builds its
  boards from FENs). No history, no clock.
- **Rating conditioning.** Not continuous: 11 bins, `<1100`, then 100-point
  bins to 1999, then **one bin for everything from 2000 up**. A 2050 and a
  2750 are the same player to stock Maia-2. For Lichess that was fine; for
  broadcast OTB games, where most counted plies are by players above 2000
  (§5), it throws away the very thing the screening conditions on.
- **Training data.** Lichess rated rapid and blitz, 2018-2023, the first 10
  plies skipped, positions with under 30 s on the clock dropped.
- Lichess ratings are not FIDE ratings (Lichess rapid runs a few hundred
  points above FIDE in the middle of the range). Stock Maia-2 fed a FIDE
  rating is therefore conditioned on the wrong player as well.

## 3. Data pipeline (`tools/maia/build_dataset.py`)

Input: the monthly broadcast files, 2024-01 to 2025-12 (24 files, 346 MB
compressed), downloaded to `C:\Users\jorian\maia-work\data\raw`, never into
the repository.

A game is kept when:

- standard chess (no setup FEN), a decisive or drawn result;
- **both players have a FIDE ID and a rating of 1000 or more**, neither is
  a BOT. Early 2024 files rarely carry FIDE IDs (2024-01: 2,234 of 14,422
  games), so those months contribute little;
- **classical**: the first clock either side shows is 50 minutes or more;
  without clocks, a TimeControl whose first period is 50 minutes or more,
  in seconds or in words ("90 min + 30 sec"). Events or time controls
  saying rapid, blitz, bullet, armageddon, tie-break, 960 or freestyle are
  dropped. Conservative: 45+15 (classical by FIDE's 60-minute rule) is lost;
  no rapid game gets in;
- at least 10 plies, and every move legal.

**Dedupe:** the same game broadcast twice (an official and a mirror
broadcast; several groups of one event) is one game: the key is both FIDE
IDs plus the full move list. First seen wins.

**Split by event, not by game.** The event is the broadcast's tournament
name (`BroadcastName` up to ` | `, so a tournament's groups stay together),
and the held-out share is chosen with the same hash rule as phase 2
(`Alnasl.FairPlay.Calibration.held_out?/2`, 20%). A validation set for
training is carved out of the training events (one event in twenty), so
the held-out events are looked at only by the final evaluation.

**Finding for phase 2.** The PGN `Event` tag is not the event in these
files: since 2024 most broadcasts put the chapter there,
`"Round 11: Kuybokarov, Temur - Torre, Eugenio"`, one value per game
(2024-01: 7,414 of 7,522 distinct Event values occur once; 2025-08:
24,841 of 25,197). Phase 2's calibration groups player-events and picks
its holdout by that tag (`player_events/1`, `holdout_key/1`), so on these
files a "player-event" is mostly one game (never 40 counted moves, so it
drops out of the covariance and the false-positive table), and the holdout
is by game again. It should key on `BroadcastName` (or the tournament part
of `BroadcastURL`) when present. Also, its `standard?/2` reads only
numeric TimeControls (`5400+30`): free text such as `"90 min + 30 sec per
move"` (the majority in some months) parses as 90 seconds and is dropped,
and many games have no TimeControl at all. The clock rule above keeps them.

Stored per position (about 120 bytes): the twelve piece bitboards and a
flags word (decoded to maia2's 18 planes on the GPU; checked against
maia2's own `board_to_tensor` on 17,400 random positions by
`tools/maia/check_encoding.py`), the move played, both ratings, the ply,
the mover's clock, the result, the game and the event.

## 4. Fine-tuning recipe, sized for 8 GB (`tools/maia/finetune.py`)

- Start from stock Maia-2 **rapid** (the closer of the two to classical;
  measured, §5), with the rating embedding **widened to 19 bins**: the old
  ten below 2000 as they were, then 2000-2099 ... 2700-2799 and 2800+, all
  starting as copies of the old 2000+ row, so the widened network begins
  exactly where the stock one is. Ratings are FIDE.
- Whole training split in host RAM as bitboards, batches decoded on the
  GPU, bf16 autocast, no dataloader worker processes: the CPU stays free
  and the GPU does the work. Batch 1024 runs on the 8 GB card without
  trouble, at 5,900-6,700 positions a second (RTX 3060 Ti).
- AdamW, base learning rate 3e-5 (Maia-2 trained at 1e-4), the rating
  embedding at 10x, linear warm-up 300 steps then cosine to the time cap,
  gradient clipping at 1.0, weight decay 1e-5.
- Loss: policy cross-entropy plus the value head (MSE on the result from
  the mover's side), as maia2. Its auxiliary head is not trained (it needs
  legal-move masks for every training position).
- Positions: from ply 10 on, mover not under 30 s, as maia2.
- The checkpoint kept is the one with the best validation loss.

## 5. Evaluation (`tools/maia/evaluate.py`)

The only question: is the fine-tune a better model of OTB classical
players than stock Maia-2 on **events it has never seen**? Measured on a
fixed sample of 100,000 positions from the held-out events, counted as the
screening counts them (ply 16 on, mover not under 60 s when known), per
FIDE band of the mover:

- top-1 accuracy (the network's favourite was played) and top-3;
- the mean negative log-likelihood of the move played: the number that
  matters, since the statistics use probabilities, not guesses;
- the mean top probability against top-1 accuracy, a first look at
  calibration.

Pilot result (2026-10-20; 100,000 positions, 399 held-out events; FIDE
band of the mover):

| Band | n | Stock rapid top-1 | Pilot top-1 | Stock NLL | Pilot NLL |
| --- | ---: | ---: | ---: | ---: | ---: |
| <1600 | 5,509 | 48.5% | 49.9% | 1.564 | 1.514 |
| 1600-1799 | 13,526 | 48.6% | 50.0% | 1.594 | 1.514 |
| 1800-1999 | 22,656 | 48.0% | 49.9% | 1.615 | 1.522 |
| 2000-2199 | 20,736 | 45.9% | 47.9% | 1.669 | 1.571 |
| 2200-2399 | 20,415 | 44.7% | 46.6% | 1.718 | 1.604 |
| 2400-2599 | 14,074 | 44.2% | 46.1% | 1.750 | 1.624 |
| 2600+ | 3,084 | 42.5% | 44.5% | 1.786 | 1.659 |
| **all** | 100,000 | **46.3%** | **48.1%** | **1.666** | **1.566** |

- Stock blitz is slightly worse than stock rapid (46.1%, NLL 1.698), so
  rapid is the base.
- The fine-tune is better in **every band**, on both measures. Resampling
  whole events (2,000 bootstrap draws): top-1 +1.82 points (95% interval
  +1.57 to +2.01), NLL −0.100 (−0.104 to −0.096). It has the lower NLL on
  95% of the 399 held-out events.
- Calibration improved too. Stock rapid is over-confident: its favourite
  gets 54.4% on average and is played 46.3% of the time. The pilot's gets
  51.8% and is played 48.1% of the time. Still over-confident, so the
  recalibration step in §6 is needed either way.
- Both models do worse as the rating goes up: strong players are less
  predictable move by move. Stock Maia-2 has no way to tell them apart
  above 2000; the widened bins are where most of the NLL gain is (−0.10
  to −0.13 above 2000, −0.05 to −0.09 below).

## 6. How it plugs into the statistics

Stockfish still decides what the best move was and how much a move lost.
The human model replaces the **expected** side of MM and EV:

- **MM.** Today `p` is the logistic model's chance of the engine's first
  choice. With the human model, `p = P_maia(best move | position, rating,
  opponent's rating)`, read off the move probabilities. The z-score formula
  is unchanged: `(Σ match − Σ p) / sqrt(Σ p(1−p))`.
- **EV.** `q = Σ P_maia(m)` over the moves within 0.01 of the best (from
  the MultiPV 4 Stockfish already gives).
- **ASD** stays as it is (the loss table per band and position type) in the
  first version. A human-model ASD needs Stockfish's loss for every move
  the model gives weight to, not just its top four; the top four plus "the
  rest at least the fourth's loss" is a lower bound, and the bias of that
  is not known yet.
- **Recalibration.** Network probabilities are not exactly calibrated.
  The fit (`mix alnasl.fair_play.calibrate fit`) gains one small step: a
  logistic regression of "played the engine's move" on
  `logit(P_maia)` and the rating, on the training events (two or three
  coefficients, the same Newton fit as now). Its output is the `p` the
  tests use. Then the covariance and the false-positive table on the
  held-out events, exactly as phase 2 does, so the "about 1 in N" on the
  report stays a measured number. The gate is unchanged.
- **One model file per engine AND network.** `model-sf19.json` gains a
  `human` section (network name, SHA-256, rating bins, the recalibration
  coefficients). Without the network installed, the report falls back to
  the phase 2 model; a report says which it used.
- The test of whether it is worth it is the same table phase 2 already
  produces: at equal held-out false-positive rates, does the human-model
  score separate better? Concretely, calibrate both on the same labels and
  compare the spread of normal player-events (the covariance diagonal) and
  the share at 2.5 and 3.0. Lower is better, at equal power to catch an
  engine-assisted player (to be measured by planting engine moves into
  held-out games: one move in five, one in ten).

## 7. Runtime in Alnasl: ONNX + Ortex

- **Export** (`tools/maia/export_onnx.py`): inputs `board` [N,18,8,8],
  `elo_self`/`elo_oppo` [N] (bin indices), `legal` [N,1880]; outputs
  `probs` [N,1880] (softmax over the legal moves) and `value` [N]. opset 17,
  dynamic batch. Checked against PyTorch.
- **Elixir side.** Alnasl already replays every game for Stockfish, so it
  has the position and the legal moves. New: the 18-plane encoding
  (mirror for Black), the move-vocabulary table (1,880 UCI strings, fixed),
  the bin function, and `Ortex.run/2` on a batch. Probabilities are stored
  per analysed ply (`p_best`, `p_ev`) next to Stockfish's numbers, so a
  report never re-runs the network.
- **Cost on CPU** (this PC, i7-10700, ONNX Runtime, one thread):
  11-15 ms per position one at a time, about 8 ms per position in
  batches of 32 (fp32, 85 MB file; int8 quantisation not tried yet).
  Against Stockfish's ~0.8 s per position it is noise; a
  whole round of an 80-board hall is a few seconds.
- **Ortex's catch.** It is a Rustler NIF built from source (0.1.10, last
  released November 2024, needs a Rust toolchain at build time, and the
  `ort` crate fetches ONNX Runtime binaries during the build). That is
  fine for the hosted server and the Linux release build; for the Windows
  and macOS desktop builds and the Pi, it is three more native builds in
  CI. **Decision for the user:** accept Ortex (and its build cost), or run
  the network the way Stockfish runs: a small separate program (ONNX
  Runtime's C API, or a Python-free Rust binary) downloaded at enable time
  with a pinned digest, talked to over a port. The second keeps Alnasl's
  build pure Elixir and matches how fair play already treats engines.

## 8. Pilot and full run

### The pilot (done, 2026-10-20)

| Step | Result |
| --- | --- |
| Data | 604,456 broadcast games read. Dropped: 132,836 not classical, 106,037 not both FIDE-rated, 39,072 without a result, and 892 duplicates. Kept: **309,201 games, 26.8 M positions** from 2,018 events. 58% of positions are by players rated 2000 or more. |
| Split | train 237,735 games / 1,619 events; held out 71,466 games / 399 events |
| Build | ~20 min on 4 worker processes, 6.3 GB on disk (3 GB of it the per-month cache, which can go) |
| Fine-tune | 35 minutes of GPU, 14 M positions (0.8 of an epoch), from stock rapid |
| Validation loss (training events held aside) | 1.633 at the start, 1.556 at 2 M positions, 1.532 at 10 M, then flat to the end of the cosine |
| Held-out events | §5: top-1 46.3% → 48.1%, NLL 1.666 → 1.566, better in every band |
| ONNX | 512 held-out positions: largest probability difference from PyTorch 2.4e-6, same favourite move on all 512 |

Reproduce, from the repository root, with the venv in
`C:\Users\jorian\maia-work\.venv` (Python 3.12, `torch==2.8.0+cu128`,
`maia2==0.11.0`, `onnx`, `onnxruntime`, `zstandard`):

```sh
python -I tools/maia/check_encoding.py
python -I tools/maia/build_dataset.py --raw maia-work/data/raw --out maia-work/data/otb --workers 4
python -I tools/maia/evaluate.py --data maia-work/data/otb --weights maia-work/weights --model stock-rapid --model stock-blitz
python -I tools/maia/finetune.py --data maia-work/data/otb --weights maia-work/weights --out maia-work/weights/otb-pilot.pt --minutes 35 --val-every 2000
python -I tools/maia/evaluate.py --data maia-work/data/otb --weights maia-work/weights --model stock-rapid --model maia-work/weights/otb-pilot.pt
python -I tools/maia/export_onnx.py --model maia-work/weights/otb-pilot.pt --weights maia-work/weights --out maia-work/onnx/otb-pilot.onnx --data maia-work/data/otb
```

### What the pilot says about a full run

The validation loss stopped improving after about 10 M positions, while
the learning rate was still decaying. So more of the same data, for
longer, will not buy much. The levers are:

1. **More data.** Add 2026-01 to 2026-09: nine more files, likely bigger
   than 2025's. Older months add little, because 2023 and early-2024
   files rarely carry FIDE IDs. Expected: roughly 1.5-2x the positions.
2. **A higher learning rate and 2 epochs** (1e-4, Maia-2's own rate),
   now that it is known not to blow up.
3. **The auxiliary head back in** (it needs legal masks, about 235
   bytes per position packed, so about 6 GB more disk for 25 M
   positions).

Projected cost at ~6,000 positions a second: 2 epochs over ~40 M
positions is **about 3.5-4 hours of GPU**, plus about 15 minutes to build
the extra months. That has to run when the PC is not needed, or on
another machine with a GPU. The VM has none. Expected gain over the
pilot: modest. Perhaps another 0.5-1 point of top-1. The pilot already
holds most of the improvement.

### Decisions for the user

1. **Weights licence.** Ask CSSLab to confirm the Maia-2 weights are
   MIT (or otherwise permissive), and whether they object to a published
   OTB fine-tune (§1). Without that, the fine-tune cannot be shipped or
   hosted, only used privately.
2. **Full run or not.** Run the full run above (3.5-4 h of GPU, PC
   busy), or settle for the pilot network for the statistics work and
   revisit later.
3. **Runtime.** Use Ortex (a Rust NIF and ONNX Runtime in every native
   build), or a separate pinned inference program downloaded at enable
   time like Stockfish (§7).
4. **Phase 2 fixes, independent of Maia** (§3): key the calibration's
   events on `BroadcastName`, not `Event`, and read free-text and
   clock-derived time controls. Without the first, phase 2's held-out
   false-positive table on 2024-2025 broadcasts rests mostly on the
   minority of broadcasts that still put the event's name in `Event`.

Next, whichever way 2 goes: the statistics side (§6). Add the
`p_best`/`p_ev` columns. Label the same games with Stockfish and the
network. Fit the recalibration. Compare the held-out false-positive
tables of the phase 2 model and the human model.

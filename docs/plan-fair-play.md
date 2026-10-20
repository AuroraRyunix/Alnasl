# Fair-play screening in Alnasl: plan

Status: phase 1 being built on branch `fairplay`, 2026-10-20.

Alnasl screens the games its boards record and shows the hall owner which
players' moves matched a strong engine more often, and lost less, than their
rating predicts. It is a reason to look closer: not evidence, not an
accusation, and not visible to anybody but the owner. It lives in Alnasl
alone. OpenPairings is not involved: any pairing program works, because
Alnasl already has the moves (after its tracker), the names, ratings and
FIDE IDs (from the pairing document or its own local tournaments), and halls
with owners.

## 1. What FIDE says, and what that forces on us

FIDE Fair Play Regulations, approved by Council 10/11/2024
(`handbook.fide.com/files/handbook/FPL_Regulations_2024.pdf`).

- **Art. 1.5**: a presumption of cheating comes only from "a FIDE-validated
  and approved algorithm".
- **Art. 1.6**: "Currently, only Prof. Kenneth W. Regan's methodology is
  approved". It uses three tests (Move-Matching, Equal-top-value, Average
  Scaled Difference). The over-the-board threshold is 5.00; 2.50 or more
  only in support of other evidence.
- **Art. 1.7**: a reckless or manifestly unfounded accusation is itself an
  offence. Reporting a suspicion privately to an arbiter is allowed.
- **Art. 3.1.2 a**: the Chief Arbiter or Chief Fair Play Officer may report
  to the FPL.
- **Art. 3.2.12**: strict confidentiality.

What this forces on us:

- Ours is **not** an approved method and must never look like one. The
  number is a "screening score". We never present 5.00 or 2.50 as our own
  cut-offs, and every report names Art. 1.6.
- What to do with an unusual score is in the manual: ask the FPL for a
  proper analysis (Art. 3.1.2 a), and tell nobody else (Art. 1.7, 3.2.12).
- We only flag unusually strong play. Weak play is nobody's business.

## 2. Decisions (2026-10-20)

- **Who sees it.** The hall owner only.
  - Not arbiters, not viewers.
  - Not the hosted service's admin either: `Scope.role/2` gives an admin
    "owner" everywhere, and fair play must not follow that. Somebody else's
    hall's reports are not the operator's business.
  - An open box (`open?`, the hall's own network, nobody signs in) counts as
    its owner, as everywhere else in Alnasl.
- **Off by default**, switched on per hall by its owner.
- **Engine.** Official Stockfish **19** (`sf_19`, 2026-09-05), the
  "universal" build for each platform.
  - **Downloaded, never shipped.** Alnasl's source holds only the URLs and
    GitHub's SHA256 digests (§3).
  - Downloaded when the owner switches fair play on, or chosen from a file
    (USB stick) when the hall has no internet. Same digest check either way.
  - After installing: `bench` must give sf_19's signature, so we know it is
    the calibrated build and nothing else.
- **Multi-engine in the code, one calibrated engine in practice.** The
  engine is a setting, and a calibration file belongs to exactly one engine
  version.
- **Retention.** Reports and per-move analysis are deleted 30 days after the
  tournament's last round (`ALNASL_FAIR_PLAY_RETENTION_DAYS`). The owner can
  extend one tournament up to 365 days, with a reason, for a case going to
  the FPL.
- **Calibration.** Approved. It runs on the VM when that is back, or on the
  lab. Until a model file exists, the report shows the raw counts and no
  score.
- **Licensing.** Alnasl stays Apache-2.0.
  - Stockfish (GPL-3) runs as a separate program over UCI and is never
    distributed by us, so no GPL obligations arise.
  - The hosted server runs it, which is not distribution, and Stockfish is
    GPL, not AGPL.
  - Credit on the About page and in NOTICE.

## 3. Stockfish 19, as pinned

| Platform | Asset | SHA256 (GitHub digest) |
| --- | --- | --- |
| Windows x86-64 | `stockfish-windows-x86-64-universal.zip` | `3c8bf1f9ea66a09350a40df4f632288285ac206d99f33ab5842c408fc30b48a7` |
| Windows arm64 | `stockfish-windows-arm64-universal.zip` | `8372ad3f0d7276deb2c70f801f541ec7db463219fc6d9c7592864e542aa4f401` |
| macOS | `stockfish-macos-universal.tar.gz` | `a1f0e3bcc5a6927a11fe6fc8e54a779754645f3c2bae2cf13420fd1957adaa77` |
| Linux x86-64 | `stockfish-linux-x86-64-universal.tar.gz` | `9defc0d4e55d49c65a6d042f3e571a39fcea499ade6dbe741b53b8c65e03611f` |
| Linux arm64 | `stockfish-linux-arm64-universal.tar.gz` | `fe26cfd1d9db4c8af3d21e24d9ff34cacb31c1f940085a7583da11796f2bac01` |

URL pattern:
`https://github.com/official-stockfish/Stockfish/releases/download/sf_19/<asset>`

Still to check: the macOS universal build's minimum macOS version. Intel
Macs on 10.13 may not be able to run it; the page must say so rather than
fail silently.

## 4. Analysis

- **Settings, fixed so every game is scored alike.** `Threads 1`,
  `Hash 64`, `MultiPV 4`, a fixed node count per position (start: 1,000,000;
  frozen at calibration). The engine name, version, bench signature and
  settings are stored with every analysis.
- **Live.** A position is analysed when the tracker has made its move final.
  Final means not orange and not red: the tracker's own flags in `plies`.
  The work goes through a queue with a few engines (desktop: cores − 1;
  hosted: 1 at low priority).
  - Cost: about 0.8 s per position on one desktop core.
  - An 80-board hall at 90+30 needs under half a core on average.
- **Moves that do not count** (each one counted by reason, and shown):
  - moves 1-8 for each side;
  - repeated positions;
  - decided positions, where the best eval is beyond ±3.00 before the move;
  - forced moves: only one legal move, or best ≥ 2.00 better than second;
  - time trouble: under 60 s on the mover's clock before the move, when the
    clock is known;
  - any ply the tracker guessed, and every ply after it in that game;
  - plies the tracker rewrote, until the arbiter has confirmed the game's
    result;
  - games with no rating for the player.

## 5. Statistics

Per player, over the moves that count. Losses are scaled as Regan does:
centipawn loss / (1 + |eval|/100), capped at 5.00.

- **Expected match.** A logistic model of the chance of playing the
  engine's first choice, from:
  - the rating,
  - the scaled gap from the best move to the second best,
  - the number of moves within 0.30 of the best,
  - the material left.
- **Expected scaled loss.** Its mean and variance per rating band and
  position type.
- **The three tests:**
  - **MM**: `(Σ match − Σ p) / sqrt(Σ p(1−p))`.
  - **EV**: the same, but a move within 0.01 of the best counts as a match.
  - **ASD**: `(Σ E[d] − Σ d) / sqrt(Σ Var[d])`.
- **Combined.** A weighted sum divided by its standard deviation, using the
  three tests' correlation measured in calibration.
- **Shown only with at least 40 counted moves** for that player in the
  event. Below that: "too few moves".
- **Calibration** (a mix task, run on the VM or the lab):
  - Corpus: Lichess broadcast games (database.lichess.org, CC BY-SA 4.0):
    real over-the-board events with FIDE Elo and clocks. Standard time
    controls, 2024-2025.
  - 5,000 games to fit, 2,000 held out.
  - We keep only derived parameters, in `priv/fair_play/model-sf19.json`,
    attributed and under CC BY-SA 4.0.
  - Gate: on the held-out games, more than about 1 in 700 normal
    player-events scoring over 3 means the model does not ship.

## 6. Data

| Table | Holds |
| --- | --- |
| `fair_play_settings` | per hall: on/off, engine path, installed version and bench, nodes |
| `fair_play_moves` | per analysed ply: game, ply, eval best, eval played, rank of played, gap, near-count, material, skip reason |
| `fair_play_keeps` | per tournament: extended retention date and reason |
| `fair_play_views` | who opened which report and when (the audit) |

The retention job deletes `fair_play_moves` and the keeps once their date
passes. Reports are computed on the fly from the moves, so a deleted move is
a deleted report.

## 7. Screens

- **Hall settings, owner only.** The "Fair-play screening" switch; engine
  status (missing, downloading, installed with its version and bench); the
  "choose a file" fallback.
- **The report: owner only, its own page per tournament and round.**
  - Players sorted by score, with counted moves, MM % against expected, loss
    against expected, the score and its interval, and the skip counts.
  - Wording: "worth a closer look" from 2, "statistically very unusual"
    above 5.
  - Always the line about Art. 1.6 and a link to the manual section.
- **Per player.** The key positions, with the played move and the engine's
  four.
- **Never** in the public results, the PGNs, the broadcast to Lichess or
  OpenResults, the arbiter's log, or the outbox.

## 8. Phases

1. **Phase 1, this branch:**
   - the engine installer (download/file, digest, bench);
   - the UCI port;
   - move selection, statistics, model loading and fitting, the calibration
     task;
   - live analysis;
   - owner-only access, view audit and retention;
   - screens, manual (EN + NL), CHANGELOG.
2. **Phase 2:** PGN upload for games without boards; analysis of a finished
   round on demand; a bigger calibration; rapid and blitz models.
3. **Phase 3:** Maia (the Lc0 network trained per rating) as the human
   expectation beside Stockfish.

Deliberately never: profiles of a player across events, any public signal,
any automatic report.

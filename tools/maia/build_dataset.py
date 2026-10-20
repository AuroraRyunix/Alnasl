"""Builds the OTB classical dataset for fine-tuning Maia-2.

    python -I tools/maia/build_dataset.py --raw DIR --out DIR [--workers 4]
        [--holdout 0.2]

Reads every lichess_db_broadcast_*.pgn.zst in --raw (the Lichess broadcast
database, CC BY-SA 4.0) and writes, to --out:

  months/<month>.npz   pass 1, one per input file (kept, so pass 2 is cheap)
  train.npz, test.npz  pass 2: deduplicated, split by event
  games.tsv            one line per kept game: key, split, event, month
  summary.json         what was kept and dropped, and why

A game is kept when:
  * the variant is standard and the result is 1-0, 0-1 or 1/2-1/2;
  * both players have a FIDE ID and a rating of 1000 or more, and neither
    is marked BOT;
  * the time control is classical (see `classical/1`), and the event is not
    a rapid, blitz or armageddon side event or tie-break;
  * it has at least 10 plies.
The same game broadcast twice (two broadcasts of one event, a mirror) is
kept once: same FIDE IDs and same moves. The split is by EVENT (the
broadcast's tournament name, groups of one tournament together), with the
same hash rule as Alnasl's calibration, so a player-event is never on both
sides. The PGN Event tag is NOT the event: since 2024 most broadcasts put
"Round 3: White - Black" there, one value per game.
"""

import argparse
import collections
import glob
import hashlib
import io
import json
import os
import re
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chess  # noqa: E402
import chess.pgn  # noqa: E402
import numpy as np  # noqa: E402
import zstandard  # noqa: E402

from common import MOVE_INDEX, encode, held_out  # noqa: E402

MAX_PLY = 300
FAST = re.compile(r"\b(rapid|blitz|bullet|armageddon|tie-?break|960|fischer|freestyle)\b", re.I)
CLK = re.compile(r"\[%clk (\d+):(\d+):(\d+)(?:\.\d+)?\]")


def seconds(comment):
    m = CLK.search(comment or "")
    if not m:
        return -1
    return int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3])


def classical(headers, first_clocks):
    """Classical, conservatively: the first clock either side shows is at
    least 50 minutes (60+30, 90+30, 90/40+30... all pass; 45+15 does not,
    which costs a little data and no correctness). Without clocks, a
    TimeControl whose first period is 50 minutes or more, written in
    seconds ("5400+30", "40/5400+30:1800+30") or in minutes ("90 min ...",
    "90'+30''"). Anything else is dropped."""
    text = " ".join(
        headers.get(k, "") for k in ("TimeControl", "BroadcastName", "Event", "StudyName")
    )
    if FAST.search(text):
        return False
    known = [c for c in first_clocks if c >= 0]
    if known:
        return max(known) >= 3000
    tc = headers.get("TimeControl", "")
    m = re.match(r"^\s*(?:\d+/)?(\d+)(?:\+\d+)?", tc)
    if m and int(m[1]) >= 3000:
        return True
    m = re.search(r"(\d+)\s*(?:min|mins|minutes|minuten|'|’)", tc, re.I)
    if m and int(m[1]) >= 50:
        return True
    m = re.match(r"^\s*(\d+)\.(\d\d)\b", tc)  # "1.30 + 30 sec"
    return bool(m and int(m[1]) * 60 + int(m[2]) >= 50)


def event_of(headers):
    name = headers.get("BroadcastName", "").strip()
    if name:
        # "Pertamina Indonesia 2024 | GM": keep a tournament's groups together.
        return "broadcast:" + name.split(" | ")[0].strip()
    return "event:" + headers.get("Event", "").strip()


def fide(headers, key):
    value = headers.get(key, "").strip()
    return value if value.isdigit() and int(value) > 0 else None


def rating(headers, key):
    value = headers.get(key, "").strip()
    return int(value) if value.isdigit() else 0


def pass1(args):
    path, out_dir = args
    month = re.search(r"(\d{4}-\d{2})", os.path.basename(path))[1]
    target = os.path.join(out_dir, "months", f"{month}.npz")
    if os.path.exists(target):
        return month, json.load(open(target + ".json"))

    why = collections.Counter()
    cols = collections.defaultdict(list)
    games = []
    with open(path, "rb") as raw:
        text = io.TextIOWrapper(
            zstandard.ZstdDecompressor().stream_reader(raw), encoding="utf-8", errors="replace"
        )
        while True:
            try:
                game = chess.pgn.read_game(text)
            except Exception:  # a broken game: skip it, not the month
                why["unreadable"] += 1
                continue
            if game is None:
                break
            why["seen"] += 1
            h = game.headers
            if h.get("Variant", "Standard") not in ("Standard", "", "From Position") or "FEN" in h:
                why["variant"] += 1
                continue
            result = h.get("Result", "*")
            if result not in ("1-0", "0-1", "1/2-1/2"):
                why["no_result"] += 1
                continue
            if "BOT" in (h.get("WhiteTitle", ""), h.get("BlackTitle", "")):
                why["bot"] += 1
                continue
            wf, bf = fide(h, "WhiteFideId"), fide(h, "BlackFideId")
            we, be = rating(h, "WhiteElo"), rating(h, "BlackElo")
            # (a FIDE ID typed into the rating tag happens: 5327130)
            if not (wf and bf and 1000 <= we <= 3000 and 1000 <= be <= 3000):
                why["not_both_fide_rated"] += 1
                continue
            nodes = list(game.mainline())
            if len(nodes) < 10:
                why["short"] += 1
                continue
            clocks = [seconds(n.comment) for n in nodes]
            if not classical(h, clocks[:2]):
                why["not_classical"] += 1
                continue
            if game.errors:
                why["illegal"] += 1
                continue

            white_score = {"1-0": 1, "0-1": -1, "1/2-1/2": 0}[result]
            ucis = [n.move.uci() for n in nodes]
            key = hashlib.sha1(f"{wf}|{bf}|{' '.join(ucis)}".encode()).hexdigest()[:16]
            gi = len(games)
            games.append((key, event_of(h), wf, bf))
            board = game.board()
            last = {chess.WHITE: -1, chess.BLACK: -1}
            for ply, node in enumerate(nodes[:MAX_PLY]):
                move = node.move
                white = board.turn == chess.WHITE
                view = board if white else board.mirror()
                uci = move.uci()
                if not white:
                    uci = uci[0] + str(9 - int(uci[1])) + uci[2] + str(9 - int(uci[3])) + uci[4:]
                if uci in MOVE_INDEX:
                    bbs, flags = encode(view)
                    cols["bbs"].append(bbs.tobytes())
                    cols["flags"].append(flags)
                    cols["move"].append(MOVE_INDEX[uci])
                    cols["elo_self"].append(we if white else be)
                    cols["elo_oppo"].append(be if white else we)
                    cols["ply"].append(ply)
                    cols["clock"].append(last[board.turn])
                    cols["result"].append(white_score if white else -white_score)
                    cols["game"].append(gi)
                last[board.turn] = clocks[ply]
                board.push(move)
            why["kept"] += 1

    os.makedirs(os.path.dirname(target), exist_ok=True)
    n = len(cols["move"])
    np.savez(
        target,
        bbs=np.frombuffer(b"".join(cols["bbs"]), dtype=np.int64).reshape(n, 12),
        flags=np.array(cols["flags"], dtype=np.int32),
        move=np.array(cols["move"], dtype=np.int16),
        elo_self=np.array(cols["elo_self"], dtype=np.int16),
        elo_oppo=np.array(cols["elo_oppo"], dtype=np.int16),
        ply=np.array(cols["ply"], dtype=np.int16),
        clock=np.array(cols["clock"], dtype=np.int32),
        result=np.array(cols["result"], dtype=np.int8),
        game=np.array(cols["game"], dtype=np.int32),
        game_key=np.array([g[0] for g in games]),
        game_event=np.array([g[1] for g in games]),
    )
    summary = dict(why, positions=n)
    json.dump(summary, open(target + ".json", "w"))
    return month, summary


def pass2(out_dir, months, holdout):
    seen = set()
    parts = {"train": collections.defaultdict(list), "test": collections.defaultdict(list)}
    events = {"train": set(), "test": set()}
    dupes = 0
    with open(os.path.join(out_dir, "games.tsv"), "w", encoding="utf-8") as tsv:
        for month in months:
            d = np.load(os.path.join(out_dir, "months", f"{month}.npz"))
            keep_game = np.zeros(len(d["game_key"]), dtype=bool)
            split_of = np.zeros(len(d["game_key"]), dtype=np.int8)
            for i, (key, event) in enumerate(zip(d["game_key"], d["game_event"])):
                if key in seen:
                    dupes += 1
                    continue
                seen.add(key)
                keep_game[i] = True
                test = held_out(str(event), holdout)
                split_of[i] = 1 if test else 0
                name = "test" if test else "train"
                events[name].add(str(event))
                tsv.write(f"{key}\t{name}\t{event}\t{month}\n")
            g = d["game"]
            # a stable 63-bit id of each game's event, for carving a
            # validation set out of the training events later
            event_ids = np.array(
                [
                    int.from_bytes(hashlib.sha1(str(e).encode("utf-8")).digest()[:8], "big") >> 1
                    for e in d["game_event"]
                ],
                dtype=np.int64,
            )
            for split, flag in (("train", 0), ("test", 1)):
                rows = keep_game[g] & (split_of[g] == flag)
                for col in ("bbs", "flags", "move", "elo_self", "elo_oppo", "ply", "clock", "result"):
                    parts[split][col].append(d[col][rows])
                # game ids made unique across months
                parts[split]["game"].append(g[rows].astype(np.int64) + (int(month.replace("-", "")) << 20))
                parts[split]["event"].append(event_ids[g[rows]])
    out = {"duplicates": dupes, "games": len(seen)}
    for split in ("train", "test"):
        arrays = {k: np.concatenate(v) for k, v in parts[split].items()}
        np.savez(os.path.join(out_dir, f"{split}.npz"), **arrays)
        out[split] = {
            "positions": int(len(arrays["move"])),
            "games": int(len(np.unique(arrays["game"]))),
            "events": len(events[split]),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--holdout", type=float, default=0.2)
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.raw, "lichess_db_broadcast_*.pgn.zst")))
    with Pool(a.workers) as pool:
        results = dict(pool.map(pass1, [(f, a.out) for f in files], chunksize=1))
    totals = collections.Counter()
    for summary in results.values():
        totals.update(summary)
    split = pass2(a.out, sorted(results), a.holdout)
    summary = {"pass1": dict(totals), "pass2": split, "holdout": a.holdout, "months": sorted(results)}
    json.dump(summary, open(os.path.join(a.out, "summary.json"), "w"), indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

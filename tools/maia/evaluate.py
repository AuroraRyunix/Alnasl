"""Move-matching of a Maia-2 network on held-out OTB events.

    python -I tools/maia/evaluate.py --data DIR --weights DIR
        --model stock-rapid|stock-blitz|PATH.pt [--sample 100000]

Positions: a fixed random sample of the held-out (test) split, counted the
way Alnasl's screening counts them: from move 9 on (ply >= 16), and not in
time trouble (the mover's clock 60 s or more, when it is known). The
sample and its legal-move masks are cached in DIR/eval-<n>.npz, so every
model is measured on the same positions.

Reported per FIDE band of the mover, and overall: top-1 accuracy (the
network's most likely move was played), top-3, the mean negative log
likelihood of the move played (what the screening statistics actually
use: a probability, not a guess), and the mean top probability (against
top-1 accuracy, a first look at calibration).
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
import torch  # noqa: E402

from common import MOVES, board_from, decode, legal_mask, otb_bins, stock_bins  # noqa: E402

BANDS = [(0, 1600), (1600, 1800), (1800, 2000), (2000, 2200), (2200, 2400), (2400, 2600), (2600, 4000)]


def band_name(lo, hi):
    if lo == 0:
        return f"<{hi}"
    if hi == 4000:
        return f">={lo}"
    return f"{lo}-{hi - 1}"


def eval_cache(data_dir, n, seed=1):
    path = os.path.join(data_dir, f"eval-{n}.npz")
    if os.path.exists(path):
        return dict(np.load(path))
    d = np.load(os.path.join(data_dir, "test.npz"))
    ok = (d["ply"] >= 16) & ((d["clock"] < 0) | (d["clock"] >= 60))
    idx = np.flatnonzero(ok)
    rng = np.random.default_rng(seed)
    idx = np.sort(rng.choice(idx, size=min(n, len(idx)), replace=False))
    cache = {k: d[k][idx] for k in ("bbs", "flags", "move", "elo_self", "elo_oppo", "ply", "game", "event")}
    masks = np.stack([legal_mask(board_from(b, f)) for b, f in zip(cache["bbs"], cache["flags"])])
    assert masks[np.arange(len(idx)), cache["move"].astype(np.int64)].all(), "a played move is not legal"
    cache["legal"] = np.packbits(masks, axis=1)
    cache["eligible"] = np.array(len(np.flatnonzero(ok)))
    np.savez(path, **cache)
    return cache


@torch.no_grad()
def predict(model, cache, bins_fn, batch=2048, device="cuda"):
    """Log-probabilities over legal moves, row by row: returns (played
    move log-prob, rank of the played move, top probability)."""
    model.eval().to(device)
    n = len(cache["move"])
    logp_played = np.zeros(n, dtype=np.float32)
    rank = np.zeros(n, dtype=np.int32)
    top = np.zeros(n, dtype=np.float32)
    for s in range(0, n, batch):
        sl = slice(s, s + batch)
        boards = decode(
            torch.from_numpy(cache["bbs"][sl]).to(device),
            torch.from_numpy(cache["flags"][sl].astype(np.int32)).to(device),
        )
        es = torch.from_numpy(bins_fn(cache["elo_self"][sl]).astype(np.int64)).to(device)
        eo = torch.from_numpy(bins_fn(cache["elo_oppo"][sl]).astype(np.int64)).to(device)
        legal = torch.from_numpy(np.unpackbits(cache["legal"][sl], axis=1)[:, : len(MOVES)]).to(device).bool()
        logits, _, _ = model(boards, es, eo)
        logp = torch.log_softmax(logits.float().masked_fill(~legal, float("-inf")), dim=-1)
        played = torch.from_numpy(cache["move"][sl].astype(np.int64)).to(device)
        lp = logp.gather(1, played.unsqueeze(1)).squeeze(1)
        logp_played[sl] = lp.cpu().numpy()
        rank[sl] = ((logp > lp.unsqueeze(1)).sum(dim=1) + 1).cpu().numpy()
        top[sl] = logp.max(dim=1).values.exp().cpu().numpy()
    return logp_played, rank, top


def summarise(cache, logp, rank, top):
    out = {}
    elo = cache["elo_self"].astype(np.int32)
    for lo, hi in BANDS + [(0, 9999)]:
        sel = (elo >= lo) & (elo < hi)
        if not sel.any():
            continue
        name = "all" if hi == 9999 else band_name(lo, hi)
        out[name] = {
            "n": int(sel.sum()),
            "top1": round(float((rank[sel] == 1).mean()), 4),
            "top3": round(float((rank[sel] <= 3).mean()), 4),
            "nll": round(float(-logp[sel].mean()), 4),
            "mean_top_p": round(float(top[sel].mean()), 4),
        }
    return out


def load(spec, weights_dir):
    import models

    if spec.startswith("stock-"):
        return models.stock(spec.removeprefix("stock-"), weights_dir), stock_bins
    model, _meta = models.otb(spec)
    return model, otb_bins


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--model", action="append", required=True)
    ap.add_argument("--sample", type=int, default=100000)
    ap.add_argument("--out")
    a = ap.parse_args()

    t = time.time()
    cache = eval_cache(a.data, a.sample)
    print(f"eval set: {len(cache['move'])} positions from {len(np.unique(cache['event']))} "
          f"held-out events ({time.time() - t:.0f}s)", flush=True)
    results = {}
    for spec in a.model:
        model, bins_fn = load(spec, a.weights)
        t = time.time()
        results[spec] = summarise(cache, *predict(model, cache, bins_fn))
        print(spec, f"({time.time() - t:.0f}s)", json.dumps(results[spec]["all"]), flush=True)
        for band, r in results[spec].items():
            print(f"  {band:>10} n={r['n']:>6} top1={r['top1']:.4f} top3={r['top3']:.4f} "
                  f"nll={r['nll']:.4f} p_top={r['mean_top_p']:.4f}")
        del model
        torch.cuda.empty_cache()
    if a.out:
        json.dump(results, open(a.out, "w"), indent=2)


if __name__ == "__main__":
    main()

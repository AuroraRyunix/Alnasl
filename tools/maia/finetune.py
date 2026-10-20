"""Fine-tunes Maia-2 on the OTB classical training split, with a time cap.

    python -I tools/maia/finetune.py --data DIR --weights DIR --out FILE.pt
        [--base rapid] [--minutes 30] [--batch 1024] [--lr 3e-5]

Sized for one 8 GB consumer GPU: the whole training split sits in host RAM
as compact bitboards (about 110 bytes a position), batches are decoded on
the GPU, bf16 autocast, no dataloader workers at all (the CPU stays free).

Recipe: start from stock Maia-2 with the rating embedding widened to 19
bins (models.widen); AdamW, linear warm-up then cosine decay to the time
cap; the rating embedding at 10x the base rate, since its new rows start
as copies and must learn to differ. Loss: maia2's own policy cross-entropy
plus its value head (mean squared error on the result from the mover's
side). maia2's third, auxiliary head (the moving piece, capture, check
and legal moves) is left out: it needs legal-move masks for every
training position, and the pilot shows whether it is missed.

Positions: from ply 10 on (maia2 skips the first ten plies too) and not
with the mover under 30 s (maia2's own clock threshold), when the clock is
known. A validation set is carved out of the TRAINING events (one event in
twenty, by its id), so the held-out test events are never looked at here.
"""

import argparse
import json
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402

import models  # noqa: E402
from common import decode, otb_bins  # noqa: E402


def load_split(path):
    d = np.load(path)
    keep = (d["ply"] >= 10) & ((d["clock"] < 0) | (d["clock"] > 30))
    out = {k: d[k][keep] for k in ("bbs", "flags", "move", "elo_self", "elo_oppo", "result", "event")}
    out["elo_self"] = otb_bins(out["elo_self"]).astype(np.int64)
    out["elo_oppo"] = otb_bins(out["elo_oppo"]).astype(np.int64)
    return out


def tensors(d, rows):
    return {
        "bbs": torch.from_numpy(d["bbs"][rows]),
        "flags": torch.from_numpy(d["flags"][rows].astype(np.int32)),
        "move": torch.from_numpy(d["move"][rows].astype(np.int64)),
        "es": torch.from_numpy(d["elo_self"][rows]),
        "eo": torch.from_numpy(d["elo_oppo"][rows]),
        "result": torch.from_numpy(d["result"][rows].astype(np.float32)),
    }


def batches(t, idx, size, device):
    for s in range(0, len(idx), size):
        rows = idx[s : s + size]
        yield (
            decode(t["bbs"][rows].to(device, non_blocking=True), t["flags"][rows].to(device)),
            t["es"][rows].to(device),
            t["eo"][rows].to(device),
            t["move"][rows].to(device),
            t["result"][rows].to(device),
        )


@torch.no_grad()
def validate(model, t, device, size=4096):
    model.eval()
    n, loss, correct = 0, 0.0, 0
    for boards, es, eo, move, _ in batches(t, torch.arange(len(t["move"])), size, device):
        with torch.autocast("cuda", dtype=torch.bfloat16):
            logits, _, _ = model(boards, es, eo)
        logits = logits.float()
        loss += F.cross_entropy(logits, move, reduction="sum").item()
        correct += (logits.argmax(1) == move).sum().item()
        n += len(move)
    model.train()
    return loss / n, correct / n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--base", default="rapid")
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--batch", type=int, default=1024)
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--elo-lr-scale", type=float, default=10.0)
    ap.add_argument("--wd", type=float, default=1e-5)
    ap.add_argument("--value-coef", type=float, default=1.0)
    ap.add_argument("--warmup", type=int, default=300)
    ap.add_argument("--val-every", type=int, default=1000)
    ap.add_argument("--val-size", type=int, default=100000)
    ap.add_argument("--steps-estimate", type=int, default=0,
                    help="cosine length in steps; 0 = measured from the first 200 steps and the cap")
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args()

    torch.manual_seed(a.seed)
    rng = np.random.default_rng(a.seed)
    device = "cuda"
    t0 = time.time()
    d = load_split(os.path.join(a.data, "train.npz"))
    is_val = (d["event"] % 20) == 0
    val_rows = np.flatnonzero(is_val)
    val_rows = np.sort(rng.choice(val_rows, size=min(a.val_size, len(val_rows)), replace=False))
    train_rows = np.flatnonzero(~is_val)
    train = tensors(d, train_rows)
    val = tensors(d, val_rows)
    del d
    print(f"train {len(train_rows):,} positions, val {len(val_rows):,} "
          f"(loaded in {time.time() - t0:.0f}s)", flush=True)

    model = models.widen(models.stock(a.base, a.weights)).to(device)
    model.train()
    elo_params = list(model.elo_embedding.parameters())
    elo_ids = {id(p) for p in elo_params}
    rest = [p for p in model.parameters() if id(p) not in elo_ids]
    opt = torch.optim.AdamW(
        [{"params": rest, "lr": a.lr}, {"params": elo_params, "lr": a.lr * a.elo_lr_scale}],
        lr=a.lr, weight_decay=a.wd,
    )
    base_lrs = [g["lr"] for g in opt.param_groups]

    vl, va = validate(model, val, device)
    log = [{"step": 0, "seconds": 0, "val_loss": vl, "val_top1": va}]
    print(f"step 0 val loss {vl:.4f} top1 {va:.4f}", flush=True)
    best = (vl, 0)
    models.save_otb(model, a.out, {"base": a.base, "step": 0})

    cap = a.minutes * 60
    start = time.time()
    step, total_steps = 0, a.steps_estimate
    run_loss, run_n, seen = 0.0, 0, 0
    done = False
    epoch = 0
    while not done:
        epoch += 1
        perm = torch.from_numpy(rng.permutation(len(train_rows)))
        for boards, es, eo, move, result in batches(train, perm, a.batch, device):
            if len(move) < a.batch:
                continue
            step += 1
            if step == 200 and not total_steps:
                per_step = (time.time() - start) / 200
                total_steps = int(cap / per_step)
                print(f"{per_step * 1000:.0f} ms/step, {a.batch / per_step:,.0f} positions/s; "
                      f"cosine over {total_steps:,} steps", flush=True)
            span = max(total_steps, step + 1) if total_steps else 10**9
            scale = (step / a.warmup if step < a.warmup
                     else 0.5 * (1 + math.cos(math.pi * min(1.0, (step - a.warmup) / max(1, span - a.warmup)))))
            for g, lr in zip(opt.param_groups, base_lrs):
                g["lr"] = lr * scale
            with torch.autocast("cuda", dtype=torch.bfloat16):
                logits, _, value = model(boards, es, eo)
            loss_p = F.cross_entropy(logits.float(), move)
            loss = loss_p + a.value_coef * F.mse_loss(value.float(), result)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            run_loss += loss_p.item()
            run_n += 1
            seen += len(move)
            elapsed = time.time() - start
            if step % a.val_every == 0 or elapsed > cap:
                vl, va = validate(model, val, device)
                entry = {"step": step, "seconds": round(elapsed), "epoch": epoch, "positions": seen,
                         "train_loss": run_loss / run_n, "val_loss": vl, "val_top1": va,
                         "lr": opt.param_groups[0]["lr"]}
                log.append(entry)
                print(json.dumps(entry), flush=True)
                run_loss, run_n = 0.0, 0
                if vl < best[0]:
                    best = (vl, step)
                    models.save_otb(model, a.out, {"base": a.base, "step": step, "val_loss": vl,
                                                   "val_top1": va, "positions": seen})
            if elapsed > cap:
                done = True
                break
    json.dump({"args": vars(a), "log": log, "best": {"val_loss": best[0], "step": best[1]}},
              open(a.out + ".log.json", "w"), indent=2)
    print(f"best val loss {best[0]:.4f} at step {best[1]}; saved {a.out}", flush=True)


if __name__ == "__main__":
    main()

"""Exports a Maia-2 network (stock or OTB) to ONNX and checks it.

    python -I tools/maia/export_onnx.py --model stock-rapid|PATH.pt
        --weights DIR --out FILE.onnx [--data DIR]

The ONNX graph is what Alnasl runs (via Ortex): inputs

    board      float32 [N, 18, 8, 8]   maia2's planes, from the mover's side
    elo_self   int64   [N]             rating bin of the mover (common.otb_bin)
    elo_oppo   int64   [N]             rating bin of the opponent
    legal      float32 [N, 1880]       1 for each legal move (mover's side)

and outputs

    probs      float32 [N, 1880]       move probabilities, 0 off the legal moves
    value      float32 [N]             the value head, maia2's scale (-1..1)

The check: for positions from the eval cache (or the start position and
a few fixed FENs without --data), ONNX Runtime and PyTorch must agree to
1e-4 on every probability; then the CPU cost per position on one thread,
one position at a time and in batches of 32.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chess  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402

from common import MOVES, board_from, decode, encode, legal_mask, otb_bins, stock_bins  # noqa: E402

FENS = [
    chess.STARTING_FEN,
    "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4",
    "r3k2r/pp1n1ppp/2p1pn2/q7/1bPP4/2N1PN2/PP1B1PPP/R2QKB1R b KQkq - 3 9",
    "8/5pk1/6p1/3P4/2K5/8/6PP/8 w - - 0 45",
    "rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3",
]


class Exported(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, board, elo_self, elo_oppo, legal):
        logits, _, value = self.model(board, elo_self, elo_oppo)
        logits = logits.masked_fill(legal < 0.5, -1.0e9)
        return torch.softmax(logits, dim=-1), value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--data")
    ap.add_argument("--check", type=int, default=512)
    a = ap.parse_args()

    import models

    if a.model.startswith("stock-"):
        model, bins_fn = models.stock(a.model.removeprefix("stock-"), a.weights), stock_bins
    else:
        model, bins_fn = models.otb(a.model)[0], otb_bins
    wrapped = Exported(model.eval()).eval()

    if a.data:
        cache = np.load(os.path.join(a.data, "eval-100000.npz"))
        n = min(a.check, len(cache["move"]))
        bbs, flags = cache["bbs"][:n], cache["flags"][:n].astype(np.int32)
        boards = decode(torch.from_numpy(bbs), torch.from_numpy(flags)).numpy()
        legal = np.unpackbits(cache["legal"][:n], axis=1)[:, : len(MOVES)].astype(np.float32)
        es = bins_fn(cache["elo_self"][:n]).astype(np.int64)
        eo = bins_fn(cache["elo_oppo"][:n]).astype(np.int64)
    else:
        rows = []
        for fen in FENS:
            b = chess.Board(fen)
            rows.append(encode(b if b.turn else b.mirror()))
        bbs = np.stack([r[0] for r in rows])
        flags = np.array([r[1] for r in rows], dtype=np.int32)
        boards = decode(torch.from_numpy(bbs), torch.from_numpy(flags)).numpy()
        legal = np.stack([legal_mask(board_from(b, f)) for b, f in zip(bbs, flags)]).astype(np.float32)
        es = bins_fn(np.full(len(FENS), 1800)).astype(np.int64)
        eo = bins_fn(np.full(len(FENS), 1900)).astype(np.int64)

    args = tuple(torch.from_numpy(x) for x in (boards[:2], es[:2], eo[:2], legal[:2]))
    torch.onnx.export(
        wrapped, args, a.out,
        input_names=["board", "elo_self", "elo_oppo", "legal"],
        output_names=["probs", "value"],
        dynamic_axes={k: {0: "n"} for k in ("board", "elo_self", "elo_oppo", "legal", "probs", "value")},
        opset_version=17, dynamo=False,
    )
    print(f"wrote {a.out} ({os.path.getsize(a.out) / 1e6:.1f} MB)")

    import onnxruntime as ort

    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 1
    opts.inter_op_num_threads = 1
    sess = ort.InferenceSession(a.out, opts, providers=["CPUExecutionProvider"])
    feed = {"board": boards, "elo_self": es, "elo_oppo": eo, "legal": legal}
    onnx_probs, onnx_value = sess.run(None, feed)
    with torch.no_grad():
        torch_probs, torch_value = wrapped(*(torch.from_numpy(x) for x in (boards, es, eo, legal)))
    diff = np.abs(onnx_probs - torch_probs.numpy()).max()
    vdiff = np.abs(onnx_value - torch_value.numpy()).max()
    same_top = (onnx_probs.argmax(1) == torch_probs.numpy().argmax(1)).mean()
    print(f"check on {len(boards)} positions: max |dp| {diff:.2e}, max |dvalue| {vdiff:.2e}, "
          f"same top move {same_top:.4f}")
    i = 0
    top = np.argsort(-onnx_probs[i])[:5]
    print("position 0, top 5 (onnx / torch):",
          ", ".join(f"{MOVES[j]} {onnx_probs[i, j]:.4f}/{torch_probs[i, j]:.4f}" for j in top))
    assert diff < 1e-4, "ONNX and PyTorch disagree"

    for size in (1, 32):
        sub = {k: v[:size] for k, v in feed.items()}
        size = len(sub["board"])  # fewer than asked without --data
        sess.run(None, sub)
        reps = max(1, 200 // size)
        t = time.perf_counter()
        for _ in range(reps):
            sess.run(None, sub)
        per = (time.perf_counter() - t) / (reps * size)
        print(f"CPU, 1 thread, batch {size}: {per * 1000:.1f} ms per position")


if __name__ == "__main__":
    main()

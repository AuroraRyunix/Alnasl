"""Loading stock Maia-2 and the OTB fine-tune.

The stock weights are maia2's own release (MIT code; fetched from the
package's Google Drive links, checked against the package's SHA-256), in
--weights (blitz_model.pt / rapid_model.pt). The OTB model is the same
network with a wider rating embedding (common.OTB_BINS rows instead of
11), saved as a plain state dict plus a small header.
"""

import os
from importlib.resources import as_file, files

import torch
from maia2.main import MAIA2Model
from maia2.utils import create_elo_dict, parse_args

from common import MOVES, OTB_BINS, STOCK_BINS


def config():
    with as_file(files("maia2.configs").joinpath("maia2-training.yaml")) as path:
        return parse_args(path)


def stock(kind, weights_dir):
    model = MAIA2Model(len(MOVES), create_elo_dict(), config())
    checkpoint = torch.load(
        os.path.join(weights_dir, f"{kind}_model.pt"), map_location="cpu", weights_only=True
    )
    state = {k.removeprefix("module."): v for k, v in checkpoint["model_state_dict"].items()}
    model.load_state_dict(state)
    assert model.elo_embedding.num_embeddings == STOCK_BINS
    return model


def widen(model):
    """The stock network with 19 rating bins: rows 0-9 as they were, and
    the old >=2000 row copied into 2000-2099 ... >=2800, so the widened
    network starts out predicting exactly what the stock one does."""
    old = model.elo_embedding.weight.data
    new = torch.nn.Embedding(OTB_BINS, old.shape[1])
    new.weight.data[:STOCK_BINS] = old
    new.weight.data[STOCK_BINS - 1 :] = old[STOCK_BINS - 1]
    model.elo_embedding = new
    return model


def otb(path):
    saved = torch.load(path, map_location="cpu", weights_only=True)
    model = widen(MAIA2Model(len(MOVES), create_elo_dict(), config()))
    model.load_state_dict(saved["state_dict"])
    return model, saved.get("meta", {})


def save_otb(model, path, meta):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    torch.save({"state_dict": model.state_dict(), "meta": meta}, path)

"""Checks that tools/maia/common.py encodes exactly as maia2 does: the move
vocabulary, the rating bins, and the 18 input planes for a set of random
positions from random games (both colours to move, castling, en passant,
promotions). Run it after touching common.py.

    python -I tools/maia/check_encoding.py
"""

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chess  # noqa: E402
import torch  # noqa: E402
from maia2 import utils  # noqa: E402

from common import MOVES, board_from, decode, encode, stock_bin  # noqa: E402

assert MOVES == utils.get_all_possible_moves(), "move vocabulary differs"
elo_dict = utils.create_elo_dict()
for elo in range(600, 3000, 7):
    assert stock_bin(elo) == utils.map_to_category(elo, elo_dict), elo

rng = random.Random(7)
checked = 0
for _ in range(300):
    board = chess.Board()
    for _ in range(rng.randint(0, 120)):
        moves = list(board.legal_moves)
        if not moves:
            break
        board.push(rng.choice(moves))
        # what maia2 sees: the FEN, mirrored when Black is to move
        fen = board.fen()
        theirs = chess.Board(fen) if board.turn else chess.Board(fen).mirror()
        expected = utils.board_to_tensor(theirs)
        view = board if board.turn else board.mirror()
        bbs, flags = encode(view)
        got = decode(torch.tensor(bbs).unsqueeze(0), torch.tensor([flags], dtype=torch.int32))[0]
        assert torch.equal(got, expected), fen
        assert board_from(bbs, flags).board_fen() == theirs.board_fen(), fen
        checked += 1
print(f"ok: vocabulary {len(MOVES)}, bins, {checked} positions")

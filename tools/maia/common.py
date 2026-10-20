"""Shared pieces of the Maia-2 OTB tools: the move vocabulary, the rating
bins, the compact position encoding and its decoding on the GPU.

The encoding reproduces maia2's own `board_to_tensor` (18 planes: 12 piece
planes, side to move, four castling rights, en passant), always from the
mover's side (a Black move is mirrored, as maia2 does), but stores it as
twelve 64-bit bitboards plus a flags byte, so the training loop never
touches python-chess.
"""

import hashlib

import chess
import numpy as np
import torch

# --- moves -----------------------------------------------------------------


def all_moves():
    """maia2's move vocabulary (utils.get_all_possible_moves), same order."""
    moves = []
    for rank in range(8):
        for file in range(8):
            square = chess.square(file, rank)
            for piece in (chess.QUEEN, chess.KNIGHT):
                board = chess.Board(None)
                board.set_piece_at(square, chess.Piece(piece, chess.WHITE))
                moves.extend(m.uci() for m in board.legal_moves)
    for file in "abcdefgh":
        for target in [file] + (
            [chr(ord(file) - 1)] if file != "a" else []
        ) + ([chr(ord(file) + 1)] if file != "h" else []):
            for piece in "qrbn":
                moves.append(f"{file}7{target}8{piece}")
    return moves


MOVES = all_moves()
MOVE_INDEX = {m: i for i, m in enumerate(MOVES)}

# --- ratings ---------------------------------------------------------------

# Stock maia2: <1100, 1100-1199 ... 1900-1999, >=2000 (11 bins). Over the
# board almost every broadcast player is in the last one, so the fine-tuned
# model splits it: 2000-2099 ... 2700-2799, >=2800 (19 bins). The new rows
# start as copies of the old >=2000 row.
STOCK_BINS = 11
OTB_BINS = 19


def stock_bin(elo):
    if elo < 1100:
        return 0
    if elo >= 2000:
        return 10
    return 1 + (elo - 1100) // 100


def otb_bin(elo):
    if elo < 1100:
        return 0
    if elo >= 2800:
        return 18
    return 1 + (elo - 1100) // 100


def stock_bins(elos):
    elos = np.asarray(elos)
    return np.where(elos < 1100, 0, np.where(elos >= 2000, 10, 1 + (elos - 1100) // 100))


def otb_bins(elos):
    elos = np.asarray(elos)
    return np.where(elos < 1100, 0, np.where(elos >= 2800, 18, 1 + (elos - 1100) // 100))


# --- positions -------------------------------------------------------------

PIECES = [chess.PAWN, chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN, chess.KING]


def encode(board):
    """A board (already from the mover's side, White to move) as
    (12 int64 bitboards, flags). Flags: bit 0 side to move is White,
    bits 1-4 castling WK WQ BK BQ, bits 8-15 en passant square + 1 (0 none)."""
    bbs = np.zeros(12, dtype=np.uint64)
    for i, piece in enumerate(PIECES):
        bbs[i] = board.pieces_mask(piece, chess.WHITE)
        bbs[i + 6] = board.pieces_mask(piece, chess.BLACK)
    flags = 1 if board.turn == chess.WHITE else 0
    for bit, has in enumerate(
        (
            board.has_kingside_castling_rights(chess.WHITE),
            board.has_queenside_castling_rights(chess.WHITE),
            board.has_kingside_castling_rights(chess.BLACK),
            board.has_queenside_castling_rights(chess.BLACK),
        )
    ):
        if has:
            flags |= 1 << (bit + 1)
    # maia2 builds its boards from FENs, and python-chess writes the en
    # passant square into a FEN only when the capture is legal.
    if board.ep_square is not None and board.has_legal_en_passant():
        flags |= (board.ep_square + 1) << 8
    return bbs.view(np.int64), flags


_BITS = None


def decode(bbs, flags):
    """GPU: (B,12) int64 bitboards and (B,) int32 flags -> (B,18,8,8) float."""
    global _BITS
    device = bbs.device
    if _BITS is None or _BITS.device != device:
        _BITS = torch.arange(64, device=device, dtype=torch.int64)
    b = bbs.shape[0]
    planes = ((bbs.unsqueeze(-1) >> _BITS) & 1).to(torch.float32)  # (B,12,64)
    extra = torch.zeros(b, 6, 64, device=device)
    extra[:, 0, :] = (flags & 1).unsqueeze(-1).float()
    for i in range(4):
        extra[:, 1 + i, :] = ((flags >> (i + 1)) & 1).unsqueeze(-1).float()
    ep = (flags >> 8) & 0xFF
    rows = torch.nonzero(ep > 0).flatten()
    if rows.numel():
        extra[rows, 5, ep[rows] - 1] = 1.0
    return torch.cat([planes, extra], dim=1).view(b, 18, 8, 8)


def legal_mask(board):
    """The legal moves of a board from the mover's side, as a bool vector."""
    mask = np.zeros(len(MOVES), dtype=bool)
    for move in board.legal_moves:
        mask[MOVE_INDEX[move.uci()]] = True
    return mask


def board_from(bbs, flags):
    """python-chess board back from the compact encoding (White to move)."""
    board = chess.Board(None)
    bbs = np.asarray(bbs, dtype=np.int64).view(np.uint64)
    for i, piece in enumerate(PIECES):
        for color, offset in ((chess.WHITE, 0), (chess.BLACK, 6)):
            for sq in chess.SquareSet(int(bbs[i + offset])):
                board.set_piece_at(sq, chess.Piece(piece, color))
    board.turn = bool(flags & 1)
    rights = 0
    for bit, sq in enumerate((chess.H1, chess.A1, chess.H8, chess.A8)):
        if flags & (1 << (bit + 1)):
            rights |= chess.BB_SQUARES[sq]
    board.castling_rights = rights
    ep = (flags >> 8) & 0xFF
    board.ep_square = ep - 1 if ep else None
    return board


# --- events ----------------------------------------------------------------


def held_out(key, fraction):
    """The same rule as Alnasl.FairPlay.Calibration.held_out?/2: sha256 of
    "holdout:" <> key, first four bytes, below the fraction."""
    digest = hashlib.sha256(("holdout:" + key).encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "big") / 4294967296 < fraction

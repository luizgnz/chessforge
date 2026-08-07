from __future__ import annotations

from typing import Any

import chess
import chess.engine
import chess.pgn


def classify(delta: int) -> str:
    if delta >= 200:
        return "blunder"
    if delta >= 100:
        return "mistake"
    if delta >= 50:
        return "inaccuracy"
    return "ok"


def game_id_from(headers: chess.pgn.Headers) -> str | None:
    site = headers.get("Site", "")
    if "lichess.org/" not in site:
        return None
    gid = site.rsplit("/", 1)[-1].strip()
    return gid or None


def analyze_game(
    engine: chess.engine.SimpleEngine,
    game: chess.pgn.Game,
    depth: int,
) -> tuple[dict[str, Any], list[tuple]]:
    """Return (summary, evals) for one game. CPU-bound."""
    board = game.board()
    evals: list[tuple] = []
    losses: dict[chess.Color, list[int]] = {chess.WHITE: [], chess.BLACK: []}
    first_blunder: int | None = None

    for ply, move in enumerate(game.mainline_moves(), start=1):
        mover = board.turn
        info = engine.analyse(board, chess.engine.Limit(depth=depth))
        best_score = info["score"].white().score(mate_score=10000)
        best_move = info.get("pv", [None])[0]

        board.push(move)
        info_after = engine.analyse(board, chess.engine.Limit(depth=depth))
        after_score = info_after["score"].white().score(mate_score=10000)

        if best_score is None or after_score is None:
            delta = 0
        else:
            raw = (
                (best_score - after_score)
                if mover == chess.WHITE
                else (after_score - best_score)
            )
            delta = max(0, int(raw))
        losses[mover].append(delta)

        cls = classify(delta)
        if cls == "blunder" and first_blunder is None:
            first_blunder = ply

        evals.append(
            (
                ply,
                int(after_score if after_score is not None else 0),
                delta,
                move.uci(),
                best_move.uci() if best_move else None,
                cls,
            )
        )

    def acpl(side: chess.Color) -> int:
        values = losses[side]
        return int(sum(values) / len(values)) if values else 0

    summary = {
        "ply_count": len(evals),
        "acpl_white": acpl(chess.WHITE),
        "acpl_black": acpl(chess.BLACK),
        "blunders_white": sum(
            1 for e in evals if e[5] == "blunder" and e[0] % 2 == 1
        ),
        "blunders_black": sum(
            1 for e in evals if e[5] == "blunder" and e[0] % 2 == 0
        ),
        "first_blunder_ply": first_blunder,
    }
    return summary, evals

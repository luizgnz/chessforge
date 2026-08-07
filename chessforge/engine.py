from __future__ import annotations

import os
import shutil
from pathlib import Path

import chess.engine

CANDIDATE_PATHS = (
    os.environ.get("STOCKFISH_PATH"),
    "/opt/homebrew/bin/stockfish",
    "/usr/local/bin/stockfish",
    "/usr/games/stockfish",
    "stockfish",
)


def find_stockfish() -> str:
    for candidate in CANDIDATE_PATHS:
        if not candidate:
            continue
        path = Path(candidate)
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
        found = shutil.which(candidate)
        if found:
            return found
    raise FileNotFoundError(
        "Stockfish not found. Install with `brew install stockfish` "
        "or set STOCKFISH_PATH."
    )


def open_engine(path: str | None = None) -> chess.engine.SimpleEngine:
    engine_path = path or find_stockfish()
    engine = chess.engine.SimpleEngine.popen_uci(engine_path)
    # Critical: Stockfish sees host cores, not container limits.
    engine.configure({"Threads": 1, "Hash": 64})
    return engine

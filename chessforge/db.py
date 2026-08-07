from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any, Iterable, Sequence

SCHEMA = """
CREATE TABLE IF NOT EXISTS games (
    game_id TEXT PRIMARY KEY,
    white TEXT,
    black TEXT,
    white_elo INT,
    black_elo INT,
    eco TEXT,
    opening TEXT,
    result TEXT,
    time_control TEXT,
    ply_count INT,
    acpl_white INT,
    acpl_black INT,
    blunders_white INT,
    blunders_black INT,
    first_blunder_ply INT,
    engine_version TEXT NOT NULL,
    analysis_depth INT NOT NULL,
    analyzed_at TEXT DEFAULT (datetime('now')),
    worker_pod TEXT
);

CREATE TABLE IF NOT EXISTS move_evals (
    game_id TEXT REFERENCES games(game_id) ON DELETE CASCADE,
    ply INT,
    score_cp INT,
    delta_cp INT,
    played_move TEXT,
    best_move TEXT,
    classification TEXT,
    PRIMARY KEY (game_id, ply)
);

CREATE TABLE IF NOT EXISTS ingest_runs (
    run_id TEXT PRIMARY KEY,
    source_file TEXT,
    games_enqueued INT,
    started_at TEXT DEFAULT (datetime('now')),
    finished_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_games_eco ON games(eco);
CREATE INDEX IF NOT EXISTS idx_games_elo ON games(white_elo, black_elo);
CREATE INDEX IF NOT EXISTS idx_evals_class ON move_evals(classification)
    WHERE classification = 'blunder';
"""


def connect(db_path: str | Path) -> sqlite3.Connection:
    path = Path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    conn.commit()


def persist_game(
    conn: sqlite3.Connection,
    *,
    game_id: str,
    headers: dict[str, Any],
    summary: dict[str, Any],
    evals: Sequence[tuple],
    engine_version: str,
    depth: int,
    worker_pod: str,
) -> bool:
    """Insert game + evals. Returns True if the game row was newly inserted."""
    cur = conn.execute(
        """
        INSERT INTO games (
            game_id, white, black, white_elo, black_elo,
            eco, opening, result, time_control, ply_count,
            acpl_white, acpl_black, blunders_white, blunders_black,
            first_blunder_ply, engine_version, analysis_depth, worker_pod
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (game_id) DO NOTHING
        """,
        (
            game_id,
            headers.get("White"),
            headers.get("Black"),
            int(headers.get("WhiteElo") or 0),
            int(headers.get("BlackElo") or 0),
            headers.get("ECO"),
            headers.get("Opening"),
            headers.get("Result"),
            headers.get("TimeControl"),
            summary["ply_count"],
            summary["acpl_white"],
            summary["acpl_black"],
            summary["blunders_white"],
            summary["blunders_black"],
            summary["first_blunder_ply"],
            engine_version,
            depth,
            worker_pod,
        ),
    )
    inserted = cur.rowcount > 0
    conn.executemany(
        """
        INSERT INTO move_evals
            (game_id, ply, score_cp, delta_cp, played_move, best_move, classification)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (game_id, ply) DO NOTHING
        """,
        [(game_id, *row) for row in evals],
    )
    conn.commit()
    return inserted


def record_ingest_run(
    conn: sqlite3.Connection,
    *,
    run_id: str,
    source_file: str,
    games_enqueued: int,
) -> None:
    conn.execute(
        """
        INSERT INTO ingest_runs (run_id, source_file, games_enqueued, finished_at)
        VALUES (?, ?, ?, datetime('now'))
        """,
        (run_id, source_file, games_enqueued),
    )
    conn.commit()


def count_games(conn: sqlite3.Connection) -> int:
    row = conn.execute("SELECT COUNT(*) AS n FROM games").fetchone()
    return int(row["n"])


def latest_run(conn: sqlite3.Connection) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM ingest_runs ORDER BY started_at DESC LIMIT 1"
    ).fetchone()


def games_for_eco(conn: sqlite3.Connection, eco: str) -> list[sqlite3.Row]:
    return list(
        conn.execute(
            "SELECT * FROM games WHERE eco = ? ORDER BY game_id",
            (eco,),
        )
    )


def elo_band(elo: int) -> str:
    if elo < 1000:
        return "<1000"
    low = (elo // 200) * 200
    if low >= 2400:
        return "2400+"
    return f"{low}-{low + 200}"

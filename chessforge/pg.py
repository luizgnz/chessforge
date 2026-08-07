from __future__ import annotations

import os
from typing import Any, Sequence

import psycopg
from psycopg.rows import dict_row

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
    analyzed_at TIMESTAMPTZ DEFAULT NOW(),
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
    started_at TIMESTAMPTZ DEFAULT NOW(),
    finished_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_games_eco ON games(eco);
CREATE INDEX IF NOT EXISTS idx_games_elo ON games(white_elo, black_elo);
CREATE INDEX IF NOT EXISTS idx_evals_class ON move_evals(classification)
    WHERE classification = 'blunder';
"""


def database_url() -> str:
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL is required")
    return url


def connect(url: str | None = None) -> psycopg.Connection:
    return psycopg.connect(url or database_url(), row_factory=dict_row)


def init_db(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(SCHEMA)
    conn.commit()


def persist_game(
    conn: psycopg.Connection,
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
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO games (
                game_id, white, black, white_elo, black_elo,
                eco, opening, result, time_control, ply_count,
                acpl_white, acpl_black, blunders_white, blunders_black,
                first_blunder_ply, engine_version, analysis_depth, worker_pod
            ) VALUES (
                %(game_id)s, %(white)s, %(black)s, %(white_elo)s, %(black_elo)s,
                %(eco)s, %(opening)s, %(result)s, %(time_control)s, %(ply_count)s,
                %(acpl_white)s, %(acpl_black)s, %(blunders_white)s, %(blunders_black)s,
                %(first_blunder_ply)s, %(engine_version)s, %(analysis_depth)s, %(worker_pod)s
            )
            ON CONFLICT (game_id) DO NOTHING
            """,
            {
                "game_id": game_id,
                "white": headers.get("White"),
                "black": headers.get("Black"),
                "white_elo": int(headers.get("WhiteElo") or 0),
                "black_elo": int(headers.get("BlackElo") or 0),
                "eco": headers.get("ECO"),
                "opening": headers.get("Opening"),
                "result": headers.get("Result"),
                "time_control": headers.get("TimeControl"),
                "ply_count": summary["ply_count"],
                "acpl_white": summary["acpl_white"],
                "acpl_black": summary["acpl_black"],
                "blunders_white": summary["blunders_white"],
                "blunders_black": summary["blunders_black"],
                "first_blunder_ply": summary["first_blunder_ply"],
                "engine_version": engine_version,
                "analysis_depth": depth,
                "worker_pod": worker_pod,
            },
        )
        inserted = cur.rowcount > 0
        cur.executemany(
            """
            INSERT INTO move_evals
                (game_id, ply, score_cp, delta_cp, played_move, best_move, classification)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (game_id, ply) DO NOTHING
            """,
            [(game_id, *row) for row in evals],
        )
    conn.commit()
    return inserted


def record_ingest_run(
    conn: psycopg.Connection,
    *,
    run_id: str,
    source_file: str,
    games_enqueued: int,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO ingest_runs (run_id, source_file, games_enqueued, finished_at)
            VALUES (%s, %s, %s, NOW())
            ON CONFLICT (run_id) DO NOTHING
            """,
            (run_id, source_file, games_enqueued),
        )
    conn.commit()


def count_games(conn: psycopg.Connection) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS n FROM games")
        row = cur.fetchone()
    return int(row["n"])

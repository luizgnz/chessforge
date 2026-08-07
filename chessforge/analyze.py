from __future__ import annotations

import argparse
import io
import socket
import sys
import time
import uuid
from pathlib import Path

import chess.pgn
import zstandard as zstd

from chessforge.analyze_game import analyze_game, game_id_from
from chessforge.db import (
    connect,
    count_games,
    init_db,
    persist_game,
    record_ingest_run,
)
from chessforge.engine import open_engine


def open_pgn(path: Path):
    fh = path.open("rb")
    if path.name.endswith(".zst"):
        return io.TextIOWrapper(
            zstd.ZstdDecompressor().stream_reader(fh), encoding="utf-8"
        )
    return io.TextIOWrapper(fh, encoding="utf-8")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Analyze PGN games with Stockfish")
    p.add_argument("--source", required=True, help="Path to .pgn or .pgn.zst")
    p.add_argument("--depth", type=int, default=10)
    p.add_argument("--max-games", type=int, default=0, help="0 = no limit")
    p.add_argument("--db", default="data/chessforge.db")
    p.add_argument("--stockfish", default=None, help="Override Stockfish path")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    source = Path(args.source)
    if not source.is_file():
        print(f"source not found: {source}", file=sys.stderr)
        return 1

    run_id = str(uuid.uuid4())
    worker = socket.gethostname()
    conn = connect(args.db)
    init_db(conn)

    before = count_games(conn)
    engine = open_engine(args.stockfish)
    engine_version = engine.id.get("name", "stockfish")

    enqueued = 0
    analyzed = 0
    failed = 0
    t0 = time.perf_counter()

    print(
        f"RUN {run_id} starting | depth={args.depth} | source={source}",
        flush=True,
    )

    try:
        with open_pgn(source) as fh:
            while True:
                game = chess.pgn.read_game(fh)
                if game is None:
                    break
                gid = game_id_from(game.headers)
                if not gid:
                    continue

                enqueued += 1
                try:
                    summary, evals = analyze_game(engine, game, args.depth)
                    persist_game(
                        conn,
                        game_id=gid,
                        headers=dict(game.headers),
                        summary=summary,
                        evals=evals,
                        engine_version=engine_version,
                        depth=args.depth,
                        worker_pod=worker,
                    )
                    analyzed += 1
                    print(
                        f"game {gid}  acpl={summary['acpl_white']}/{summary['acpl_black']}  "
                        f"blunders={summary['blunders_white']}/{summary['blunders_black']}  "
                        f"first_blunder={summary['first_blunder_ply']}",
                        flush=True,
                    )
                except Exception as exc:  # noqa: BLE001 — draft CLI keeps going
                    failed += 1
                    print(f"error game={gid}: {exc}", flush=True)

                if args.max_games and enqueued >= args.max_games:
                    break
    finally:
        engine.quit()

    record_ingest_run(
        conn,
        run_id=run_id,
        source_file=str(source),
        games_enqueued=enqueued,
    )
    after = count_games(conn)
    elapsed = time.perf_counter() - t0
    per_game = elapsed / analyzed if analyzed else 0.0
    # Integrity vs this run: newly stored rows may be 0 on re-run (idempotent).
    stored_now = after  # total in DB
    lost = max(0, enqueued - analyzed - failed)

    print(
        f"DONE  RUN {run_id}  enqueued={enqueued}  analyzed={analyzed}  "
        f"failed={failed}  lost={lost}  db_games={stored_now}  "
        f"(was {before})  ~{per_game:.2f}s/game",
        flush=True,
    )
    conn.close()
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())

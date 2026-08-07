from __future__ import annotations

import argparse
import asyncio
import io
import os
import socket
import sys
import time

import chess.pgn
from nats.errors import TimeoutError as NatsTimeoutError

from chessforge.analyze_game import analyze_game, game_id_from
from chessforge.engine import open_engine
from chessforge.messaging import (
    connect_nats,
    decode_job,
    ensure_stream_and_consumer,
    pull_subscribe,
)
from chessforge.metrics import (
    ANALYZE_DURATION,
    GAMES_ANALYZED,
    GAMES_FAILED,
    start_metrics_server,
)
from chessforge.pg import connect as pg_connect
from chessforge.pg import count_games, init_db, persist_game


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="NATS worker: analyze games with Stockfish")
    p.add_argument("--stockfish", default=None, help="Override Stockfish path")
    p.add_argument(
        "--idle-exit-seconds",
        type=float,
        default=0.0,
        help="If >0, exit after this many seconds with no messages (Job-friendly smoke)",
    )
    return p.parse_args(argv)


async def run(args: argparse.Namespace) -> int:
    worker = socket.gethostname()
    metrics_port = int(os.environ.get("METRICS_PORT", "9090"))
    start_metrics_server(metrics_port)

    conn = pg_connect()
    init_db(conn)
    before = count_games(conn)

    engine = open_engine(args.stockfish)
    engine_version = engine.id.get("name", "stockfish")

    nc = await connect_nats()
    js = nc.jetstream()
    await ensure_stream_and_consumer(js)
    sub = await pull_subscribe(js)

    analyzed = 0
    failed = 0
    skipped = 0
    last_msg_at = time.perf_counter()

    print(
        f"WORKER {worker} starting | engine={engine_version} | metrics=:{metrics_port}",
        flush=True,
    )

    try:
        while True:
            try:
                msgs = await sub.fetch(1, timeout=2)
            except NatsTimeoutError:
                if args.idle_exit_seconds > 0:
                    idle = time.perf_counter() - last_msg_at
                    if idle >= args.idle_exit_seconds and analyzed + failed + skipped > 0:
                        break
                    if idle >= args.idle_exit_seconds and analyzed + failed + skipped == 0:
                        # Wait a bit longer for ingest to publish on fresh clusters.
                        if idle >= max(args.idle_exit_seconds, 60):
                            break
                continue

            for msg in msgs:
                last_msg_at = time.perf_counter()
                try:
                    job = decode_job(msg.data)
                    gid = job["game_id"]
                    depth = int(job.get("depth") or 10)
                    game = chess.pgn.read_game(io.StringIO(job["pgn"]))
                    if game is None:
                        raise ValueError("empty PGN in message")
                    if game_id_from(game.headers) != gid:
                        # Still analyze; trust payload game_id for persistence key.
                        pass

                    t0 = time.perf_counter()
                    summary, evals = analyze_game(engine, game, depth)
                    ANALYZE_DURATION.observe(time.perf_counter() - t0)
                    inserted = persist_game(
                        conn,
                        game_id=gid,
                        headers=dict(game.headers),
                        summary=summary,
                        evals=evals,
                        engine_version=engine_version,
                        depth=depth,
                        worker_pod=worker,
                    )
                    if inserted:
                        analyzed += 1
                        GAMES_ANALYZED.inc()
                    else:
                        skipped += 1
                    print(
                        f"game {gid}  inserted={inserted}  "
                        f"acpl={summary['acpl_white']}/{summary['acpl_black']}  "
                        f"blunders={summary['blunders_white']}/{summary['blunders_black']}",
                        flush=True,
                    )
                    await msg.ack()
                except Exception as exc:  # noqa: BLE001
                    failed += 1
                    GAMES_FAILED.inc()
                    print(f"error game: {exc}", flush=True)
                    # Nak for redelivery; terminal poison would need a DLQ (later).
                    try:
                        await msg.nak()
                    except Exception:  # noqa: BLE001
                        pass
    finally:
        engine.quit()
        await nc.drain()
        after = count_games(conn)
        conn.close()

    # lost is inferred by ops from ingest.games_enqueued vs db; worker prints local stats.
    print(
        f"WORKER DONE  host={worker}  analyzed={analyzed}  skipped={skipped}  "
        f"failed={failed}  db_games={after}  (was {before})",
        flush=True,
    )
    return 0 if failed == 0 else 2


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    # Default idle exit for Deployment is 0 (run forever). Jobs/smoke can set env.
    if args.idle_exit_seconds == 0.0:
        env_idle = os.environ.get("IDLE_EXIT_SECONDS")
        if env_idle:
            args.idle_exit_seconds = float(env_idle)
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())

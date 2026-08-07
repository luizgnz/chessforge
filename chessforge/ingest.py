from __future__ import annotations

import argparse
import asyncio
import io
import sys
import uuid
from pathlib import Path

import chess.pgn
import zstandard as zstd

from chessforge.analyze_game import game_id_from
from chessforge.messaging import (
    connect_nats,
    ensure_stream_and_consumer,
    publish_game,
)
from chessforge.pg import connect as pg_connect
from chessforge.pg import init_db, record_ingest_run


def open_pgn(path: Path):
    fh = path.open("rb")
    if path.name.endswith(".zst"):
        return io.TextIOWrapper(
            zstd.ZstdDecompressor().stream_reader(fh), encoding="utf-8"
        )
    return io.TextIOWrapper(fh, encoding="utf-8")


def game_to_pgn(game: chess.pgn.Game) -> str:
    buf = io.StringIO()
    print(game, file=buf, end="\n\n")
    return buf.getvalue()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Ingest PGN games into NATS JetStream")
    p.add_argument("--source", required=True, help="Path to .pgn or .pgn.zst")
    p.add_argument("--depth", type=int, default=10)
    p.add_argument("--max-games", type=int, default=0, help="0 = no limit")
    return p.parse_args(argv)


async def run(args: argparse.Namespace) -> int:
    source = Path(args.source)
    if not source.is_file():
        print(f"source not found: {source}", file=sys.stderr)
        return 1

    run_id = str(uuid.uuid4())
    conn = pg_connect()
    init_db(conn)

    nc = await connect_nats()
    js = nc.jetstream()
    await ensure_stream_and_consumer(js)

    enqueued = 0
    print(f"INGEST {run_id} starting | depth={args.depth} | source={source}", flush=True)

    try:
        with open_pgn(source) as fh:
            while True:
                game = chess.pgn.read_game(fh)
                if game is None:
                    break
                gid = game_id_from(game.headers)
                if not gid:
                    continue

                payload = {
                    "run_id": run_id,
                    "game_id": gid,
                    "pgn": game_to_pgn(game),
                    "depth": args.depth,
                }
                await publish_game(js, payload)
                enqueued += 1
                print(f"enqueued game_id={gid}", flush=True)

                if args.max_games and enqueued >= args.max_games:
                    break
    finally:
        await nc.drain()

    record_ingest_run(
        conn,
        run_id=run_id,
        source_file=str(source),
        games_enqueued=enqueued,
    )
    conn.close()
    print(f"INGEST DONE  run_id={run_id}  enqueued={enqueued}", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())

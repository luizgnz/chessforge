from __future__ import annotations

import argparse
import os
import statistics
import sys
from collections import defaultdict
from typing import Any, Mapping, Sequence

from chessforge.db import connect as sqlite_connect
from chessforge.db import elo_band
from chessforge.db import games_for_eco as sqlite_games_for_eco


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Report blunder stats by opening")
    p.add_argument("--eco", required=True, help="ECO code, e.g. C50")
    p.add_argument(
        "--db",
        default="data/chessforge.db",
        help="SQLite path (ignored when DATABASE_URL is set)",
    )
    return p.parse_args(argv)


def _load_rows(eco: str, db_path: str) -> tuple[Sequence[Mapping[str, Any]], str]:
    """Return (rows, source_label). Prefers Postgres when DATABASE_URL is set."""
    if os.environ.get("DATABASE_URL"):
        from chessforge import pg

        conn = pg.connect()
        try:
            return pg.games_for_eco(conn, eco), "postgres"
        finally:
            conn.close()

    conn = sqlite_connect(db_path)
    try:
        return sqlite_games_for_eco(conn, eco), db_path
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    eco = args.eco.upper()
    rows, source = _load_rows(eco, args.db)

    if not rows:
        print(f"No games for ECO {eco} in {source}", file=sys.stderr)
        return 1

    opening = rows[0]["opening"] or "(unknown)"
    first_blunders = [
        r["first_blunder_ply"] for r in rows if r["first_blunder_ply"] is not None
    ]
    median_fb = (
        int(statistics.median(first_blunders)) if first_blunders else None
    )

    # Blunder rate: fraction of games where that side blundered at least once,
    # bucketed by average Elo of the two players.
    by_band: dict[str, list[float]] = defaultdict(list)
    for r in rows:
        avg_elo = int(((r["white_elo"] or 0) + (r["black_elo"] or 0)) / 2)
        band = elo_band(avg_elo)
        had_blunder = (r["blunders_white"] or 0) + (r["blunders_black"] or 0) > 0
        by_band[band].append(1.0 if had_blunder else 0.0)

    print(f"ECO {eco} — {opening}")
    print(f"games_analyzed: {len(rows)}")
    print(f"median_first_blunder_ply: {median_fb}")
    print("blunder_rate_by_elo:")
    for band in sorted(by_band.keys()):
        vals = by_band[band]
        rate = sum(vals) / len(vals)
        print(f"  {band}: {rate:.2f}  (n={len(vals)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import argparse
import statistics
import sys
from collections import defaultdict

from chessforge.db import connect, elo_band, games_for_eco


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Report blunder stats by opening")
    p.add_argument("--eco", required=True, help="ECO code, e.g. C50")
    p.add_argument("--db", default="data/chessforge.db")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    conn = connect(args.db)
    rows = games_for_eco(conn, args.eco.upper())
    conn.close()

    if not rows:
        print(f"No games for ECO {args.eco.upper()} in {args.db}")
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

    print(f"ECO {args.eco.upper()} — {opening}")
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

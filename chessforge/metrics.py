"""Minimal Prometheus metrics for the analyzer worker (ADR-015)."""

from __future__ import annotations

from prometheus_client import Counter, Histogram, start_http_server

GAMES_ANALYZED = Counter(
    "chessforge_games_analyzed_total",
    "Games successfully analyzed and newly inserted into Postgres",
)
GAMES_FAILED = Counter(
    "chessforge_games_failed_total",
    "Games that failed analysis or persistence",
)
ANALYZE_DURATION = Histogram(
    "chessforge_analyze_duration_seconds",
    "Wall time to analyze one game with Stockfish",
    buckets=(0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0),
)


def start_metrics_server(port: int = 9090) -> None:
    """Serve /metrics on the given port (blocking HTTP server in a daemon thread)."""
    start_http_server(port)

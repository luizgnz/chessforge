from prometheus_client import generate_latest

from chessforge.metrics import ANALYZE_DURATION, GAMES_ANALYZED, GAMES_FAILED


def test_metric_names_exported():
    GAMES_ANALYZED.inc()
    GAMES_FAILED.inc()
    ANALYZE_DURATION.observe(0.1)
    text = generate_latest().decode()
    assert "chessforge_games_analyzed_total" in text
    assert "chessforge_games_failed_total" in text
    assert "chessforge_analyze_duration_seconds_bucket" in text

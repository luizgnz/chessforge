from chessforge.db import connect, init_db, persist_game
from chessforge.report import main


def _seed(db_path):
    conn = connect(db_path)
    init_db(conn)
    summary = {
        "ply_count": 2,
        "acpl_white": 10,
        "acpl_black": 12,
        "blunders_white": 0,
        "blunders_black": 1,
        "first_blunder_ply": 6,
    }
    persist_game(
        conn,
        game_id="cf01italian",
        headers={
            "White": "A",
            "Black": "B",
            "WhiteElo": "1500",
            "BlackElo": "1400",
            "ECO": "C50",
            "Opening": "Italian Game",
            "Result": "1-0",
            "TimeControl": "600+0",
        },
        summary=summary,
        evals=[(1, 20, 0, "e2e4", "e2e4", "ok")],
        engine_version="Stockfish",
        depth=10,
        worker_pod="local",
    )
    conn.close()


def test_report_sqlite(tmp_path, capsys, monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    db = tmp_path / "t.db"
    _seed(db)
    assert main(["--eco", "C50", "--db", str(db)]) == 0
    out = capsys.readouterr().out
    assert "ECO C50 — Italian Game" in out
    assert "games_analyzed: 1" in out
    assert "median_first_blunder_ply: 6" in out
    assert "blunder_rate_by_elo:" in out


def test_report_missing_eco(tmp_path, monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    db = tmp_path / "t.db"
    _seed(db)
    assert main(["--eco", "B20", "--db", str(db)]) == 1

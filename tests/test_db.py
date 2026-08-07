from chessforge.db import connect, count_games, init_db, persist_game


def test_persist_game_is_idempotent(tmp_path):
    db = tmp_path / "t.db"
    conn = connect(db)
    init_db(conn)

    summary = {
        "ply_count": 2,
        "acpl_white": 10,
        "acpl_black": 12,
        "blunders_white": 0,
        "blunders_black": 0,
        "first_blunder_ply": None,
    }
    evals = [(1, 20, 0, "e2e4", "e2e4", "ok")]
    headers = {
        "White": "A",
        "Black": "B",
        "WhiteElo": "1500",
        "BlackElo": "1400",
        "ECO": "C50",
        "Opening": "Italian Game",
        "Result": "1-0",
        "TimeControl": "600+0",
    }

    assert persist_game(
        conn,
        game_id="abc",
        headers=headers,
        summary=summary,
        evals=evals,
        engine_version="Stockfish",
        depth=10,
        worker_pod="local",
    )
    assert not persist_game(
        conn,
        game_id="abc",
        headers=headers,
        summary=summary,
        evals=evals,
        engine_version="Stockfish",
        depth=10,
        worker_pod="local",
    )
    assert count_games(conn) == 1
    conn.close()

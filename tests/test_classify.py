from chessforge.analyze_game import classify, game_id_from
import chess.pgn


def test_classify_thresholds():
    assert classify(0) == "ok"
    assert classify(49) == "ok"
    assert classify(50) == "inaccuracy"
    assert classify(99) == "inaccuracy"
    assert classify(100) == "mistake"
    assert classify(199) == "mistake"
    assert classify(200) == "blunder"


def test_game_id_from_lichess_site():
    headers = chess.pgn.Headers()
    headers["Site"] = "https://lichess.org/abcdef12"
    assert game_id_from(headers) == "abcdef12"


def test_game_id_from_rejects_non_lichess():
    headers = chess.pgn.Headers()
    headers["Site"] = "https://example.com/game/1"
    assert game_id_from(headers) is None

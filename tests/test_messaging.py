from chessforge.messaging import decode_job, encode_job


def test_encode_decode_roundtrip():
    payload = {
        "run_id": "r1",
        "game_id": "g1",
        "pgn": '[Site "https://lichess.org/g1"]\n\n1. e4 e5 *\n',
        "depth": 10,
    }
    assert decode_job(encode_job(payload)) == payload

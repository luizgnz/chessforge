# chessforge (local draft)

Local draft without Kubernetes: analyze PGN games with Stockfish, store results in SQLite, and query blunders by opening.

## Requirements

- Python 3.12+
- Stockfish (`brew install stockfish`) — only for local runs without Docker
- Docker (optional) — image includes Stockfish

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Local usage

```bash
# Analyze the sample (depth 10, 1 Stockfish thread)
python -m chessforge.analyze --source data/sample.pgn --depth 10 --max-games 5

# Report by opening (ECO)
python -m chessforge.report --eco C50
```

When finished, `analyze` prints an integrity summary:

```text
DONE  RUN …  enqueued=5  analyzed=5  failed=0  lost=0  …
```

## Docker (Phase 1)

Multi-stage `python:3.12-slim-bookworm` image + Stockfish via `apt` (no compile from source).

```bash
docker build -t chessforge:local .
docker run --rm chessforge:local
```

By default it analyzes 1 sample game and writes the DB to `/tmp/chessforge.db`.

## CI / GHCR

GitHub Actions (`.github/workflows/ci.yml`):

- On PR and `main`: `pytest` + `docker build` + smoke (`docker run`, 1 game).
- On push to `main` only: publish `ghcr.io/<owner>/<repo>:<sha>` and `:latest` **after** smoke.

This is **not** GitOps yet (no Argo CD / cluster reconciliation).

## What this demonstrates

1. Real CPU-bound analysis at a fixed depth (reproducible).
2. Idempotent persistence (`ON CONFLICT DO NOTHING`).
3. Verifiable counts (`enqueued` vs analyzed).
4. Queries like “blunders by opening / Elo”.
5. Reproducible image + CI that publishes to GHCR.

Next: NATS, Kubernetes, KEDA, observability, Chaos Mesh, GitOps with **Argo CD**.

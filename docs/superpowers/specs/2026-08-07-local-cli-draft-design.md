# Chessforge local CLI draft — design

**Date:** 2026-08-07  
**Status:** approved  
**GitOps later:** Argo CD (not Flux)

## Goal

Prove the core product loop without Kubernetes: ingest PGN games, analyze them with Stockfish, persist results, verify counts, and query blunder stats by opening.

## Scope

**In**

- Python package with two CLIs: `analyze` and `report`
- Stockfish analysis at fixed depth (default 10), one thread
- SQLite persistence (`games`, `move_evals`, `ingest_runs`)
- Idempotent inserts (`ON CONFLICT DO NOTHING`)
- Bundled `data/sample.pgn` (small)
- Integrity printout: `enqueued`, `analyzed`, `lost`

**Out**

- Kubernetes, NATS, KEDA, Postgres, Argo, Chaos Mesh, HTTP API

## Architecture

```text
data/sample.pgn
       │
       ▼
chessforge.analyze  ──► Stockfish (depth=10, Threads=1)
       │
       ▼
data/chessforge.db  (games, move_evals, ingest_runs)
       │
       ▼
chessforge.report --eco C50
```

## Components

| Module | Responsibility |
|---|---|
| `chessforge/engine.py` | Open Stockfish, configure Threads/Hash, expose analyse helper |
| `chessforge/analyze_game.py` | Pure analysis: game → summary + move evals + classification |
| `chessforge/db.py` | Schema, connect, persist, integrity queries |
| `chessforge/analyze.py` | CLI entry: read PGN, analyze, persist, print run summary |
| `chessforge/report.py` | CLI entry: blunders / first-blunder stats by ECO and Elo bands |

## Data model

Same spirit as the full platform:

- `games` — identity, headers, ACPL, blunder counts, `engine_version`, `analysis_depth`, `worker_pod` (hostname)
- `move_evals` — per-ply score/delta/classification
- `ingest_runs` — `run_id`, `source_file`, `games_enqueued`, timestamps

Classification thresholds (centipawn loss vs best move):

| delta_cp | classification |
|---|---|
| < 50 | ok |
| 50–99 | inaccuracy |
| 100–199 | mistake |
| ≥ 200 | blunder |

## CLI

```bash
python -m chessforge.analyze --source data/sample.pgn --depth 10 --max-games 5
python -m chessforge.report --eco C50
```

Defaults:

- `--depth 10`
- `--max-games 0` (no limit; sample file is small)
- DB path: `data/chessforge.db`
- Stockfish: `STOCKFISH_PATH` env, else common Homebrew paths, else `stockfish` on `PATH`

## Success criteria

1. `analyze` finishes without hanging the machine (1 thread, small N).
2. Summary shows `lost=0`.
3. `report --eco <code>` prints games analyzed, median first-blunder ply, blunder rate by Elo band when data exists.
4. Re-running `analyze` on the same file does not duplicate rows.

## Error handling

- Games without a Lichess-style `Site` id are skipped (not enqueued).
- Per-game analysis failures are logged; run continues.
- Re-delivery / re-run absorbed by primary-key conflicts.

## Dependencies

- Python 3.12+
- `chess`, `zstandard`
- Host Stockfish (`brew install stockfish`)

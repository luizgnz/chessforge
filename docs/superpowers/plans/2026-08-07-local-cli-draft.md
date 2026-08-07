# Local CLI Draft Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a local Python CLI that analyzes sample PGN games with Stockfish, stores results in SQLite, verifies counts, and reports blunders by ECO.

**Architecture:** Small package with pure analysis, SQLite persistence, and two `__main__` CLIs. No queue, no HTTP, no Kubernetes.

**Tech Stack:** Python 3.12, `chess`, `zstandard`, host Stockfish, SQLite stdlib.

## Global Constraints

- Default analysis depth: 10
- Stockfish Threads: 1, Hash: 64
- SQLite path default: `data/chessforge.db`
- Idempotent inserts via `ON CONFLICT DO NOTHING`
- Skip games without Lichess `Site` game id
- GitOps tool later: Argo CD (out of scope here)

---

### Task 1: Scaffold + DB schema

**Files:**
- Create: `requirements.txt`
- Create: `chessforge/__init__.py`
- Create: `chessforge/db.py`
- Create: `tests/test_db.py`
- Create: `data/.gitkeep`

- [ ] **Step 1:** Add `requirements.txt` with `chess` and `zstandard`
- [ ] **Step 2:** Implement `db.init_db`, `persist_game`, `record_ingest_run`, `count_games`
- [ ] **Step 3:** Test schema + idempotent insert
- [ ] **Step 4:** Commit if user asks

### Task 2: Analysis core

**Files:**
- Create: `chessforge/engine.py`
- Create: `chessforge/analyze_game.py`
- Create: `tests/test_analyze_game.py`
- Create: `tests/fixtures/mini.pgn`

- [ ] **Step 1:** Implement `classify`, `analyze_game`, Stockfish wrapper
- [ ] **Step 2:** Unit-test classification + analysis with mocked engine or tiny fixture
- [ ] **Step 3:** Commit if user asks

### Task 3: Analyze CLI

**Files:**
- Create: `chessforge/analyze.py`
- Create: `data/sample.pgn`
- Create: `tests/test_analyze_cli.py`

- [ ] **Step 1:** CLI args: `--source`, `--depth`, `--max-games`, `--db`
- [ ] **Step 2:** End-to-end on sample (or skip if no Stockfish with clear message)
- [ ] **Step 3:** Print integrity summary

### Task 4: Report CLI + README

**Files:**
- Create: `chessforge/report.py`
- Create: `README.md`
- Create: `tests/test_report.py`

- [ ] **Step 1:** `report --eco` with median first blunder + Elo bands
- [ ] **Step 2:** README with install + run commands
- [ ] **Step 3:** Smoke-run both CLIs

#!/usr/bin/env bash
# Phase 0 smoke: unit tests (+ optional Stockfish analyze of sample.pgn).
# Expected: pytest green; if RUN_ANALYZE=1 then DONE line with lost=0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -f .venv/bin/activate ]]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

export PYTHONPATH="${PYTHONPATH:-.}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need python3

echo "==> pytest"
python3 -m pytest -q

if [[ "${RUN_ANALYZE:-0}" == "1" ]]; then
  need stockfish
  echo "==> analyze sample.pgn (depth 10, max 5)"
  out="$(mktemp)"
  trap 'rm -f "$out"' EXIT
  python3 -m chessforge.analyze \
    --source data/sample.pgn \
    --depth 10 \
    --max-games 5 \
    --db /tmp/chessforge-smoke-local.db | tee "$out"
  if ! grep -qE 'lost=0' "$out"; then
    echo "==> FAILED: expected lost=0 in analyze output" >&2
    exit 1
  fi
  echo "==> SUCCESS local smoke (pytest + analyze lost=0)"
else
  echo "==> SUCCESS local smoke (pytest only; set RUN_ANALYZE=1 for Stockfish sample)"
fi

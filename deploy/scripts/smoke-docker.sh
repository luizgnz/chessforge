#!/usr/bin/env bash
# Phase 1 smoke: build image and run the same analyze command as CI.
# Expected: container exits 0 and prints lost=0 (1 game).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${IMAGE:-chessforge:smoke}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need docker

echo "==> docker build $IMAGE"
DOCKER_BUILDKIT=1 docker build -t "$IMAGE" "$ROOT"

echo "==> docker smoke (analyze 1 game)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
docker run --rm "$IMAGE" \
  python -m chessforge.analyze \
    --source /app/data/sample.pgn \
    --depth 10 \
    --max-games 1 \
    --db /tmp/chessforge.db | tee "$out"

if ! grep -qE 'lost=0' "$out"; then
  echo "==> FAILED: expected lost=0 in docker analyze output" >&2
  exit 1
fi

echo "==> SUCCESS docker smoke (lost=0)"

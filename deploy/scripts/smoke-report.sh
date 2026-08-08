#!/usr/bin/env bash
# Phase 7 (optional): ECO report Job against cluster Postgres (ADR-017).
# Requires pipeline data already present (kind-up or smoke-pipeline). Read-only.
# Success: Job complete; logs contain games_analyzed / median_first_blunder_ply / blunder_rate_by_elo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS="${NS:-chessforge}"
ECO="${ECO:-C50}"
PG_PASS="${CHESSFORGE_DB_PASSWORD:-chessforge}"
MIN_ECO_GAMES="${MIN_ECO_GAMES:-1}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kubectl

if ! [[ "$ECO" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "invalid ECO='${ECO}' (use letters/digits only)" >&2
  exit 1
fi

echo "==> prerequisites"
if ! kubectl -n "$NS" get secret chessforge-db >/dev/null 2>&1; then
  echo "secret chessforge-db missing — run kind-up / Vault bootstrap first" >&2
  exit 1
fi

eco_count="$(kubectl -n "$NS" exec chessforge-postgresql-0 -- \
  env PGPASSWORD="$PG_PASS" psql -U chessforge -d chessforge -tAc \
  "SELECT COUNT(*) FROM games WHERE eco = '${ECO}';" 2>/dev/null | tr -d '[:space:]' || echo 0)"
echo "postgres games for ECO ${ECO}: ${eco_count}"
if ! [[ "$eco_count" =~ ^[0-9]+$ ]] || [[ "$eco_count" -lt "$MIN_ECO_GAMES" ]]; then
  echo "need >=${MIN_ECO_GAMES} games with ECO ${ECO}; run ./deploy/scripts/smoke-pipeline.sh first" >&2
  exit 1
fi

echo "==> report-eco Job (ECO=${ECO})"
# Patch ECO into the Job without editing the committed default permanently.
tmp="$(mktemp)"
sed "s/value: \"C50\"/value: \"${ECO}\"/" "$ROOT/deploy/k8s/jobs/report-eco.yaml" >"$tmp"
kubectl -n "$NS" delete job report-eco --ignore-not-found
kubectl apply -f "$tmp"
rm -f "$tmp"

kubectl -n "$NS" wait --for=condition=complete job/report-eco --timeout=120s

echo "==> Job logs"
logs="$(kubectl -n "$NS" logs job/report-eco)"
echo "$logs"

for needle in games_analyzed median_first_blunder_ply blunder_rate_by_elo; do
  if ! grep -q "$needle" <<<"$logs"; then
    echo "==> FAILED: logs missing '${needle}'" >&2
    exit 1
  fi
done

if grep -qi "No games for ECO" <<<"$logs"; then
  echo "==> FAILED: report found no games" >&2
  exit 1
fi

echo "==> SUCCESS report smoke: ECO=${ECO} games_in_db=${eco_count}"
exit 0

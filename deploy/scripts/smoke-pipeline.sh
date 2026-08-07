#!/usr/bin/env bash
# Phase 2/3 pipeline smoke on an existing kind cluster (after kind-up or Argo sync).
# Re-runs ingest-sample Job and waits for Postgres games >= EXPECTED_GAMES (default 5).
# Also checks Vault→ESO Secret and Argo app health when present.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS="${NS:-chessforge}"
EXPECTED_GAMES="${EXPECTED_GAMES:-5}"
PG_PASS="${CHESSFORGE_DB_PASSWORD:-chessforge}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kubectl

echo "==> GitOps / secrets quick check"
if kubectl -n argocd get application vault eso nats postgres chessforge >/dev/null 2>&1; then
  kubectl -n argocd get application vault eso nats postgres chessforge keda 2>/dev/null \
    || kubectl -n argocd get application vault eso nats postgres chessforge
else
  echo "Argo applications not found (ok for Phase 2 imperative cluster)"
fi

if kubectl -n "$NS" get secret chessforge-db >/dev/null 2>&1; then
  echo "secret chessforge-db present (Vault/ESO or bootstrap)"
else
  echo "WARN: secret chessforge-db missing — ingest will fail" >&2
fi

echo "==> ingest smoke Job"
kubectl -n "$NS" delete job ingest-sample --ignore-not-found
kubectl apply -f "$ROOT/deploy/k8s/jobs/ingest-sample.yaml"
kubectl -n "$NS" wait --for=condition=complete job/ingest-sample --timeout=180s

echo "==> wait for >=${EXPECTED_GAMES} games in Postgres"
count=0
for i in $(seq 1 72); do
  count="$(kubectl -n "$NS" exec chessforge-postgresql-0 -- \
    env PGPASSWORD="$PG_PASS" psql -U chessforge -d chessforge -tAc \
    'SELECT COUNT(*) FROM games;' 2>/dev/null || echo 0)"
  count="$(echo "$count" | tr -d '[:space:]')"
  echo "poll $i: postgres games=${count}"
  if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge "$EXPECTED_GAMES" ]]; then
    echo "==> SUCCESS pipeline smoke: games=${count}"
    exit 0
  fi
  sleep 5
done

echo "==> FAILED: expected >=${EXPECTED_GAMES} games, got ${count}" >&2
kubectl -n "$NS" logs job/ingest-sample --tail=50 || true
kubectl -n "$NS" logs -l app=analyzer --tail=80 || true
exit 1

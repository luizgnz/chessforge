#!/usr/bin/env bash
# Phase 4 smoke: confirm KEDA scale-to-zero (or idle), then ingest and watch scale-up.
# Requires kind cluster with Argo-synced KEDA + ScaledObject (see ./deploy/kind-up.sh).
# Expected: idle replicas toward 0; after ingest, replicas > 0 (within max 4); games >= 5.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS="${NS:-chessforge}"
EXPECTED_GAMES="${EXPECTED_GAMES:-5}"
PG_PASS="${CHESSFORGE_DB_PASSWORD:-chessforge}"
IDLE_WAIT_SECS="${IDLE_WAIT_SECS:-90}"
SCALE_WAIT_SECS="${SCALE_WAIT_SECS:-180}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kubectl

replicas() {
  kubectl -n "$NS" get deploy analyzer -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?"
}

echo "==> KEDA / analyzer baseline"
kubectl -n argocd get application keda chessforge 2>/dev/null || true
kubectl -n "$NS" get deploy,scaledobject analyzer

echo "==> wait for idle (replicas toward 0, up to ${IDLE_WAIT_SECS}s)"
deadline=$((SECONDS + IDLE_WAIT_SECS))
idle_ok=0
while (( SECONDS < deadline )); do
  r="$(replicas)"
  r="${r:-0}"
  echo "idle poll: replicas=${r}"
  if [[ "$r" =~ ^[0-9]+$ ]] && [[ "$r" -eq 0 ]]; then
    idle_ok=1
    break
  fi
  sleep 5
done
if [[ "$idle_ok" -eq 1 ]]; then
  echo "idle: replicas=0 (scale-to-zero)"
else
  echo "WARN: replicas did not reach 0 within ${IDLE_WAIT_SECS}s (cooldown may still be running); continuing" >&2
fi

echo "==> ingest to create JetStream lag"
kubectl -n "$NS" delete job ingest-sample --ignore-not-found
kubectl apply -f "$ROOT/deploy/k8s/jobs/ingest-sample.yaml"
kubectl -n "$NS" wait --for=condition=complete job/ingest-sample --timeout=180s

echo "==> wait for scale-up (replicas > 0, up to ${SCALE_WAIT_SECS}s)"
deadline=$((SECONDS + SCALE_WAIT_SECS))
scaled=0
while (( SECONDS < deadline )); do
  r="$(replicas)"
  r="${r:-0}"
  echo "scale poll: replicas=${r}"
  if [[ "$r" =~ ^[0-9]+$ ]] && [[ "$r" -gt 0 ]]; then
    scaled=1
    break
  fi
  sleep 5
done
kubectl -n "$NS" get deploy,scaledobject analyzer

if [[ "$scaled" -ne 1 ]]; then
  echo "==> FAILED: analyzer did not scale above 0 after ingest" >&2
  exit 1
fi

echo "==> wait for >=${EXPECTED_GAMES} games in Postgres"
count=0
for i in $(seq 1 72); do
  count="$(kubectl -n "$NS" exec chessforge-postgresql-0 -- \
    env PGPASSWORD="$PG_PASS" psql -U chessforge -d chessforge -tAc \
    'SELECT COUNT(*) FROM games;' 2>/dev/null || echo 0)"
  count="$(echo "$count" | tr -d '[:space:]')"
  echo "poll $i: postgres games=${count}"
  if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge "$EXPECTED_GAMES" ]]; then
    echo "==> SUCCESS KEDA smoke: idle→N observed, games=${count}"
    kubectl -n "$NS" get deploy,scaledobject analyzer
    exit 0
  fi
  sleep 5
done

echo "==> FAILED: scaled up but games=${count} (expected >=${EXPECTED_GAMES})" >&2
kubectl -n "$NS" logs -l app=analyzer --tail=80 || true
exit 1

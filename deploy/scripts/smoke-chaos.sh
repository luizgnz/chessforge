#!/usr/bin/env bash
# Phase 6 smoke: Chaos Mesh PodChaos on analyzer mid-run → NATS redelivery → integrity.
# Requires kind cluster with Argo-synced chaos-mesh (see ./deploy/kind-up.sh).
# Success (ADR-001 / ADR-016): games >= EXPECTED, lost=0 vs latest ingest, no duplicate game_ids.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NS="${NS:-chessforge}"
EXPECTED_GAMES="${EXPECTED_GAMES:-5}"
PG_PASS="${CHESSFORGE_DB_PASSWORD:-chessforge}"
CHAOS_WAIT_SECS="${CHAOS_WAIT_SECS:-120}"
SCALE_WAIT_SECS="${SCALE_WAIT_SECS:-180}"
DRAIN_WAIT_SECS="${DRAIN_WAIT_SECS:-360}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kubectl

psql() {
  kubectl -n "$NS" exec chessforge-postgresql-0 -- \
    env PGPASSWORD="$PG_PASS" psql -U chessforge -d chessforge -tAc "$1" 2>/dev/null \
    | tr -d '[:space:]'
}

replicas() {
  kubectl -n "$NS" get deploy analyzer -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0"
}

running_analyzers() {
  kubectl -n "$NS" get pods -l app=analyzer --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d '[:space:]'
}

echo "==> Chaos Mesh / analyzer baseline"
kubectl -n argocd get application chaos-mesh chessforge 2>/dev/null || {
  echo "Argo Application chaos-mesh missing — sync Git / kind-up first" >&2
  exit 1
}

cm_sync="$(kubectl -n argocd get application chaos-mesh -o jsonpath='{.status.sync.status}' 2>/dev/null || echo missing)"
cm_health="$(kubectl -n argocd get application chaos-mesh -o jsonpath='{.status.health.status}' 2>/dev/null || echo missing)"
echo "chaos-mesh: sync=${cm_sync} health=${cm_health}"
if [[ "$cm_sync" != "Synced" ]]; then
  echo "==> FAILED: chaos-mesh Application not Synced" >&2
  exit 1
fi

# Controllers + daemon must be Ready before PodChaos can inject.
kubectl -n chaos-mesh wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller-manager --timeout=180s
kubectl -n chaos-mesh wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=chaos-daemon --timeout=180s
kubectl get crd podchaos.chaos-mesh.org >/dev/null

echo "==> clear prior PodChaos (if any)"
kubectl -n "$NS" delete podchaos analyzer-pod-kill --ignore-not-found --wait=true

# Fresh tables so success cannot ride on games already persisted by earlier smokes.
echo "==> truncate games / move_evals / ingest_runs for a clean chaos run"
kubectl -n "$NS" exec chessforge-postgresql-0 -- \
  env PGPASSWORD="$PG_PASS" psql -U chessforge -d chessforge -v ON_ERROR_STOP=1 -c \
  'TRUNCATE move_evals, games, ingest_runs RESTART IDENTITY;'

echo "==> ingest to create JetStream backlog"
kubectl -n "$NS" delete job ingest-sample --ignore-not-found
kubectl apply -f "$ROOT/deploy/k8s/jobs/ingest-sample.yaml"
kubectl -n "$NS" wait --for=condition=complete job/ingest-sample --timeout=180s

enqueued="$(psql 'SELECT games_enqueued FROM ingest_runs ORDER BY started_at DESC LIMIT 1;' || echo 0)"
echo "latest ingest enqueued=${enqueued}"
if [[ ! "$enqueued" =~ ^[0-9]+$ ]] || [[ "$enqueued" -lt "$EXPECTED_GAMES" ]]; then
  echo "==> FAILED: ingest did not enqueue >=${EXPECTED_GAMES} games (got ${enqueued})" >&2
  kubectl -n "$NS" logs job/ingest-sample --tail=50 || true
  exit 1
fi

echo "==> wait for analyzer pods (KEDA scale-up, up to ${SCALE_WAIT_SECS}s)"
deadline=$((SECONDS + SCALE_WAIT_SECS))
scaled=0
while (( SECONDS < deadline )); do
  r="$(replicas)"
  r="${r:-0}"
  alive="$(running_analyzers)"
  echo "scale poll: replicas=${r} running=${alive}"
  if [[ "$alive" =~ ^[0-9]+$ ]] && [[ "$alive" -gt 0 ]]; then
    scaled=1
    break
  fi
  sleep 5
done
if [[ "$scaled" -ne 1 ]]; then
  echo "==> FAILED: no Running analyzer pods after ingest (cannot inject PodChaos)" >&2
  kubectl -n "$NS" get deploy,scaledobject,pods -l app=analyzer || true
  exit 1
fi

echo "==> inject PodChaos (kill analyzers mid-run)"
kubectl apply -f "$ROOT/deploy/k8s/chaos/analyzer-pod-kill.yaml"
kubectl -n "$NS" get podchaos analyzer-pod-kill -o wide

# Give the controller time to kill; observe restarts / new pods.
deadline=$((SECONDS + CHAOS_WAIT_SECS))
saw_kill=0
while (( SECONDS < deadline )); do
  phase="$(kubectl -n "$NS" get podchaos analyzer-pod-kill -o jsonpath='{.status.experiment.desiredPhase}' 2>/dev/null || echo "?")"
  alive="$(running_analyzers)"
  echo "chaos poll: desiredPhase=${phase} running_analyzers=${alive}"
  # desiredPhase Run/Stop or a dip in Running pods counts as injection progress.
  if [[ "$phase" == "Run" || "$phase" == "Stop" ]]; then
    saw_kill=1
  fi
  if [[ "$alive" =~ ^[0-9]+$ ]] && [[ "$alive" -eq 0 ]]; then
    saw_kill=1
    break
  fi
  sleep 3
done
if [[ "$saw_kill" -ne 1 ]]; then
  echo "WARN: did not clearly observe kill phase; continuing to integrity wait" >&2
  kubectl -n "$NS" describe podchaos analyzer-pod-kill || true
  kubectl -n chaos-mesh logs -l app.kubernetes.io/component=controller-manager --tail=40 || true
fi

echo "==> wait for drain: games>=${EXPECTED_GAMES}, lost=0, no duplicate game_ids (up to ${DRAIN_WAIT_SECS}s)"
deadline=$((SECONDS + DRAIN_WAIT_SECS))
games=0
distinct=0
lost=0
dups=0
while (( SECONDS < deadline )); do
  games="$(psql 'SELECT COUNT(*) FROM games;' || echo 0)"
  distinct="$(psql 'SELECT COUNT(DISTINCT game_id) FROM games;' || echo 0)"
  # lost vs *latest* ingest run (SUM across re-runs falsely inflates lost after idempotent smokes).
  lost="$(psql "
    SELECT GREATEST(
      0,
      COALESCE((SELECT games_enqueued FROM ingest_runs ORDER BY started_at DESC LIMIT 1), 0)
      - (SELECT COUNT(*)::bigint FROM games)
    );
  " || echo 1)"
  dups="$(psql 'SELECT COUNT(*) - COUNT(DISTINCT game_id) FROM games;' || echo 1)"
  echo "integrity poll: games=${games} distinct=${distinct} dups=${dups} lost=${lost}"
  if [[ "$games" =~ ^[0-9]+$ ]] && [[ "$games" -ge "$EXPECTED_GAMES" ]] \
    && [[ "$dups" == "0" ]] && [[ "$lost" == "0" ]] \
    && [[ "$games" == "$distinct" ]]; then
    echo "==> SUCCESS chaos smoke: PodChaos applied; games=${games} lost=0 no duplicate game_ids"
    kubectl -n "$NS" get podchaos analyzer-pod-kill || true
    kubectl -n "$NS" get deploy,scaledobject analyzer || true
    # Leave experiment deleted so Argo/kind stay quiet between smokes.
    kubectl -n "$NS" delete podchaos analyzer-pod-kill --ignore-not-found
    exit 0
  fi
  sleep 5
done

echo "==> FAILED: after chaos games=${games} distinct=${distinct} dups=${dups} lost=${lost}" >&2
kubectl -n "$NS" get podchaos analyzer-pod-kill -o yaml || true
kubectl -n "$NS" logs -l app=analyzer --tail=80 || true
kubectl -n "$NS" delete podchaos analyzer-pod-kill --ignore-not-found || true
exit 1

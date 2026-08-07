#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-chessforge}"
IMAGE="${IMAGE:-chessforge:phase2}"
NS=chessforge

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kind
need helm
need kubectl
need docker

echo "==> kind cluster: $CLUSTER"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER"
else
  echo "cluster already exists"
fi
kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null

echo "==> namespace"
kubectl apply -f "$ROOT/deploy/k8s/namespace.yaml"

echo "==> helm repos"
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null 2>&1 || true
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> NATS (JetStream)"
helm upgrade --install chessforge-nats nats/nats \
  --namespace "$NS" \
  --create-namespace \
  -f "$ROOT/deploy/helm/nats-values.yaml" \
  --wait --timeout 5m

echo "==> Postgres"
helm upgrade --install chessforge bitnami/postgresql \
  --namespace "$NS" \
  -f "$ROOT/deploy/helm/postgres-values.yaml" \
  --wait --timeout 5m

echo "==> build + load image $IMAGE"
DOCKER_BUILDKIT=1 docker build -t "$IMAGE" "$ROOT"
kind load docker-image "$IMAGE" --name "$CLUSTER"

echo "==> app manifests"
kubectl apply -f "$ROOT/deploy/k8s/secret.yaml"
kubectl apply -f "$ROOT/deploy/k8s/analyzer-deployment.yaml"
kubectl rollout status deployment/analyzer -n "$NS" --timeout=180s

echo "==> ingest Job"
kubectl delete job ingest-sample -n "$NS" --ignore-not-found
kubectl apply -f "$ROOT/deploy/k8s/ingest-job.yaml"
kubectl wait --for=condition=complete job/ingest-sample -n "$NS" --timeout=180s

echo "==> wait for analyzers to persist sample games (expect 5)"
count=0
for i in $(seq 1 72); do
  count="$(kubectl exec -n "$NS" chessforge-postgresql-0 -- \
    env PGPASSWORD=chessforge psql -U chessforge -d chessforge -tAc 'SELECT COUNT(*) FROM games;' 2>/dev/null || echo 0)"
  count="$(echo "$count" | tr -d '[:space:]')"
  echo "poll $i: postgres games=${count}"
  if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge 5 ]]; then
    break
  fi
  sleep 5
done

echo "==> ingest logs"
kubectl logs job/ingest-sample -n "$NS" --tail=50 || true
echo "==> analyzer logs"
kubectl logs -l app=analyzer -n "$NS" --tail=100 || true

if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge 5 ]]; then
  echo "==> SUCCESS: postgres games=${count}"
  exit 0
fi
echo "==> FAILED: expected >=5 games, got ${count}" >&2
exit 1

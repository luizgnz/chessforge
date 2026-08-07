#!/usr/bin/env bash
# Phase 3 bootstrap: kind + Argo CD + root Application. Argo owns the rest.
# Then: vault bootstrap (demo), wait for stack, load GHCR image into kind, run ingest smoke.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-chessforge}"
IMAGE="${IMAGE:-ghcr.io/luizgnz/chessforge:latest}"
NS=chessforge
CTX="kind-${CLUSTER}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kind
need helm
need kubectl
need docker
need jq

echo "==> kind cluster: $CLUSTER"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER"
else
  echo "cluster already exists"
fi
kubectl config use-context "$CTX" >/dev/null

echo "==> install Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set notifications.enabled=false \
  --set dex.enabled=false \
  --wait --timeout 10m

echo "==> root Application (app-of-apps)"
kubectl apply -f "$ROOT/deploy/gitops/root-app.yaml"

echo "==> wait for Vault + ESO apps"
for i in $(seq 1 90); do
  v="$(kubectl -n argocd get application vault -o jsonpath='{.status.sync.status}' 2>/dev/null || echo missing)"
  e="$(kubectl -n argocd get application eso -o jsonpath='{.status.sync.status}' 2>/dev/null || echo missing)"
  echo "poll $i: vault=$v eso=$e"
  if [[ "$v" == "Synced" && "$e" == "Synced" ]]; then
    break
  fi
  sleep 10
done

kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=300s || true

echo "==> vault bootstrap (demo init/unseal/seed)"
chmod +x "$ROOT/deploy/scripts/vault-bootstrap.sh"
"$ROOT/deploy/scripts/vault-bootstrap.sh"

echo "==> wait for ExternalSecret chessforge-db"
for i in $(seq 1 60); do
  if kubectl -n "$NS" get secret chessforge-db >/dev/null 2>&1; then
    echo "secret chessforge-db present"
    break
  fi
  echo "poll $i: waiting for chessforge-db from ESO"
  sleep 5
done
kubectl -n "$NS" get secret chessforge-db >/dev/null

# GHCR :latest from CI is linux/amd64; kind on Apple Silicon needs a native image.
echo "==> build + kind load $IMAGE (node-native platform)"
DOCKER_BUILDKIT=1 docker build -t "$IMAGE" "$ROOT"
kind load docker-image "$IMAGE" --name "$CLUSTER"
kubectl -n "$NS" rollout restart deployment/analyzer 2>/dev/null || true

echo "==> wait for nats + postgres + analyzer"
for i in $(seq 1 90); do
  n="$(kubectl -n argocd get application nats -o jsonpath='{.status.health.status}' 2>/dev/null || echo missing)"
  p="$(kubectl -n argocd get application postgres -o jsonpath='{.status.health.status}' 2>/dev/null || echo missing)"
  c="$(kubectl -n argocd get application chessforge -o jsonpath='{.status.health.status}' 2>/dev/null || echo missing)"
  echo "poll $i: nats=$n postgres=$p chessforge=$c"
  if [[ "$n" == "Healthy" && "$p" == "Healthy" && "$c" == "Healthy" ]]; then
    break
  fi
  sleep 10
done

kubectl -n "$NS" rollout status deployment/analyzer --timeout=300s

echo "==> ingest smoke Job"
kubectl -n "$NS" delete job ingest-sample --ignore-not-found
kubectl apply -f "$ROOT/deploy/k8s/jobs/ingest-sample.yaml"
kubectl -n "$NS" wait --for=condition=complete job/ingest-sample --timeout=180s

echo "==> wait for 5 games in Postgres"
count=0
for i in $(seq 1 72); do
  count="$(kubectl -n "$NS" exec chessforge-postgresql-0 -- \
    env PGPASSWORD=chessforge psql -U chessforge -d chessforge -tAc 'SELECT COUNT(*) FROM games;' 2>/dev/null || echo 0)"
  count="$(echo "$count" | tr -d '[:space:]')"
  echo "poll $i: postgres games=${count}"
  if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge 5 ]]; then
    break
  fi
  sleep 5
done

echo "==> Argo applications"
kubectl -n argocd get applications

if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge 5 ]]; then
  echo "==> SUCCESS Phase 3 smoke: games=${count} (GitOps + Vault/ESO path)"
  exit 0
fi
echo "==> FAILED: expected >=5 games, got ${count}" >&2
kubectl -n "$NS" logs job/ingest-sample --tail=50 || true
kubectl -n "$NS" logs -l app=analyzer --tail=80 || true
exit 1

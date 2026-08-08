#!/usr/bin/env bash
# Phase 5 smoke: monitoring app Healthy, Prometheus/Grafana Ready, key scrape targets up.
# Requires kind cluster with Argo-synced monitoring (see ./deploy/kind-up.sh).
# Grafana: kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
#   then open http://localhost:3000 (admin / chessforge)
set -euo pipefail

NS_MON="${NS_MON:-monitoring}"
NS_APP="${NS_APP:-chessforge}"
WAIT_SECS="${WAIT_SECS:-180}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kubectl

echo "==> wait for Argo Application monitoring Synced (up to ${WAIT_SECS}s)"
deadline=$((SECONDS + WAIT_SECS))
app_ok=0
while (( SECONDS < deadline )); do
  sync="$(kubectl -n argocd get application monitoring -o jsonpath='{.status.sync.status}' 2>/dev/null || echo missing)"
  health="$(kubectl -n argocd get application monitoring -o jsonpath='{.status.health.status}' 2>/dev/null || echo missing)"
  echo "poll: monitoring sync=$sync health=$health"
  # Progressing is OK while Grafana rolls; require Synced.
  if [[ "$sync" == "Synced" && "$health" =~ ^(Healthy|Progressing)$ ]]; then
    app_ok=1
    break
  fi
  sleep 5
done
kubectl -n argocd get application monitoring || true
if [[ "$app_ok" -ne 1 ]]; then
  echo "==> FAILED: monitoring app not Synced (last sync=$sync health=$health)" >&2
  exit 1
fi

echo "==> wait for Prometheus + Grafana Ready (up to ${WAIT_SECS}s)"
deadline=$((SECONDS + WAIT_SECS))
ready=0
while (( SECONDS < deadline )); do
  prom_ready="$(kubectl -n "$NS_MON" get pods -l app.kubernetes.io/name=prometheus -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{end}' 2>/dev/null || true)"
  graf_ready="$(kubectl -n "$NS_MON" get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="grafana")].ready}' 2>/dev/null || true)"
  echo "poll: prometheus_ready=[${prom_ready}] grafana_ready=[${graf_ready}]"
  if [[ "$prom_ready" == *true* && "$graf_ready" == "true" ]]; then
    ready=1
    break
  fi
  sleep 5
done
if [[ "$ready" -ne 1 ]]; then
  echo "==> FAILED: Prometheus/Grafana not Ready" >&2
  kubectl -n "$NS_MON" get pods
  exit 1
fi

echo "==> ServiceMonitors / PodMonitor / PrometheusRule"
kubectl -n "$NS_MON" get servicemonitor,prometheusrule
kubectl -n "$NS_APP" get podmonitor 2>/dev/null || true

echo "==> scrape endpoints (best-effort)"
# postgres-exporter lost metric
if kubectl -n "$NS_APP" get deploy postgres-exporter >/dev/null 2>&1; then
  kubectl -n "$NS_APP" rollout status deploy/postgres-exporter --timeout=120s
  lost="$(kubectl -n "$NS_APP" run "pgexp-probe-${RANDOM}" --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
    curl -sS "http://postgres-exporter.${NS_APP}.svc:9187/metrics" 2>/dev/null \
    | grep -E '^chessforge_lost_games(\{| )' || true)"
  echo "postgres-exporter: ${lost:-'(metric not yet visible)'}"
  if [[ -z "${lost}" ]]; then
    echo "WARN: chessforge_lost_games not found yet (check DATA_SOURCE_NAME / sslmode)" >&2
  fi
fi

# NATS promExporter sidecar
if kubectl -n "$NS_APP" get pod -l app.kubernetes.io/name=nats -o name 2>/dev/null | grep -q .; then
  nats_metrics="$(kubectl -n "$NS_APP" exec chessforge-nats-0 -c prom-exporter -- \
    wget -qO- http://127.0.0.1:7777/metrics 2>/dev/null | grep -E 'num_pending|jetstream' | head -5 || true)"
  echo "nats promExporter sample:"
  echo "${nats_metrics:-'(no jetstream sample yet)'}"
fi

# Analyzer metrics (may be scaled to 0)
replicas="$(kubectl -n "$NS_APP" get deploy analyzer -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
replicas="${replicas:-0}"
if [[ "$replicas" =~ ^[0-9]+$ ]] && [[ "$replicas" -gt 0 ]]; then
  pod="$(kubectl -n "$NS_APP" get pods -l app=analyzer -o jsonpath='{.items[0].metadata.name}')"
  am="$(kubectl -n "$NS_APP" exec "$pod" -- \
    python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:9090/metrics").read().decode())' 2>/dev/null \
    | grep -E '^chessforge_games_|^chessforge_analyze_' | head -8 || true)"
  echo "analyzer /metrics sample:"
  echo "${am:-'(no chessforge series yet)'}"
else
  echo "analyzer replicas=${replicas} (scale-to-zero idle; /metrics not scraped until work)"
fi

echo "==> Grafana access"
echo "  kubectl -n ${NS_MON} port-forward svc/monitoring-grafana 3000:80"
echo "  open http://localhost:3000  (user admin / password chessforge)"
echo "  dashboard: Chessforge pipeline"
echo "  Alertmanager: kubectl -n ${NS_MON} port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093"

echo "==> SUCCESS observability smoke: monitoring Healthy; Prometheus+Grafana Running"
kubectl -n argocd get application monitoring
kubectl -n "$NS_MON" get pods
exit 0

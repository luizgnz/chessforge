# Smoke tests — cheatsheet

Reproducible verification paths used across phases. Scripts live next to this file; full cluster bring-up stays in `deploy/kind-up.sh`.

| Path | Script / command | Expected result |
|------|------------------|-----------------|
| Phase 0 — local unit tests | `./deploy/scripts/smoke-local.sh` | pytest green |
| Phase 0 — local + Stockfish | `RUN_ANALYZE=1 ./deploy/scripts/smoke-local.sh` | pytest green; `lost=0` |
| Phase 1 — Docker image | `./deploy/scripts/smoke-docker.sh` | `lost=0` (1 game) |
| Phase 1 — CI (same as Docker) | GitHub Actions `image` job Smoke step | container exit 0 |
| Phase 3–6 — full bring-up | `./deploy/kind-up.sh` | Argo Healthy; Vault→ESO Secret; monitoring; chaos-mesh; `games>=5` |
| Phase 2/3 — pipeline only | `./deploy/scripts/smoke-pipeline.sh` | ingest Job complete; `games>=5` |
| Phase 4 — KEDA scale | `./deploy/scripts/smoke-keda.sh` | idle `0` (or warn); after ingest replicas `>0`; `games>=5` |
| Phase 5 — Observability | `./deploy/scripts/smoke-observability.sh` | monitoring Synced/Healthy; Prometheus+Grafana Running |
| Phase 6 — Chaos | `./deploy/scripts/smoke-chaos.sh` | PodChaos on analyzers; `games>=5`; `lost=0`; no duplicate `game_id`s |
| Teardown | `./deploy/kind-down.sh` | kind cluster deleted |

All script text is English-only. Prefer these focused smokes after `kind-up` rather than inventing longer e2e suites.

---

## Prerequisites

- **Local:** Python 3.12+, `pip install -r requirements.txt` (+ `pytest`). Stockfish on PATH for `RUN_ANALYZE=1`.
- **Docker:** Docker Engine / OrbStack.
- **Cluster:** `kind`, `helm`, `kubectl`, `jq`, Docker. Repo pushed to GitHub so Argo can pull HEAD.
- **Apple Silicon / pull issues:** `FORCE_KIND_LOAD=1 ./deploy/kind-up.sh`.

---

## Phase 0 — local CLI

```bash
./deploy/scripts/smoke-local.sh
RUN_ANALYZE=1 ./deploy/scripts/smoke-local.sh
```

Manual equivalent:

```bash
source .venv/bin/activate
PYTHONPATH=. pytest -q
python -m chessforge.analyze --source data/sample.pgn --depth 10 --max-games 5
# DONE ... lost=0 ...
```

---

## Phase 1 — Docker / CI

```bash
./deploy/scripts/smoke-docker.sh
# optional: IMAGE=chessforge:local ./deploy/scripts/smoke-docker.sh
```

CI (`.github/workflows/ci.yml`) runs the same analyze inside `chessforge:ci` before pushing GHCR tags on `main`.

Default image `CMD` also analyzes 1 game into `/tmp/chessforge.db`:

```bash
docker build -t chessforge:local .
docker run --rm chessforge:local
```

---

## Phase 3–6 — full kind bring-up (GitOps + Vault/ESO + KEDA + monitoring + Chaos Mesh)

Creates kind, installs Argo CD, applies root Application, bootstraps Vault, waits for the stack, runs ingest, asserts Postgres count.

```bash
./deploy/kind-up.sh
# FORCE_KIND_LOAD=1 ./deploy/kind-up.sh   # build + kind load if needed
```

Success line: `SUCCESS Phase 3–6 smoke: games=N` with `N >= 5`.

Also verify:

```bash
kubectl -n argocd get applications
kubectl -n chessforge get secret chessforge-db
kubectl -n chessforge get deploy,scaledobject analyzer
kubectl -n monitoring get pods
kubectl -n chaos-mesh get pods
```

Demo Vault unseal material: `.vault-init.json` (gitignored) and Secret `vault-init` in namespace `vault`. Re-bootstrap: `./deploy/scripts/vault-bootstrap.sh`.

---

## Phase 2/3 — pipeline smoke (cluster already up)

Re-apply sample ingest and wait for games (idempotent; count stays ≥5 on re-run).

```bash
./deploy/scripts/smoke-pipeline.sh
# EXPECTED_GAMES=5 ./deploy/scripts/smoke-pipeline.sh
```

Manual:

```bash
kubectl -n chessforge delete job ingest-sample --ignore-not-found
kubectl apply -f deploy/k8s/jobs/ingest-sample.yaml
kubectl -n chessforge wait --for=condition=complete job/ingest-sample --timeout=180s
kubectl -n chessforge exec chessforge-postgresql-0 -- \
  env PGPASSWORD=chessforge psql -U chessforge -d chessforge -tAc 'SELECT COUNT(*) FROM games;'
# expect >= 5
```

---

## Phase 4 — KEDA scaling

```bash
./deploy/scripts/smoke-keda.sh
# IDLE_WAIT_SECS=120 SCALE_WAIT_SECS=180 ./deploy/scripts/smoke-keda.sh
```

Manual:

```bash
kubectl -n chessforge get deploy,scaledobject analyzer
# idle → replicas toward 0
kubectl -n chessforge apply -f deploy/k8s/jobs/ingest-sample.yaml
kubectl -n chessforge get deploy,scaledobject analyzer -w
# after ingest → scale up within maxReplicaCount 4
```

Notes:

- ScaledObject: `nats-jetstream` on stream `CHESSFORGE` / consumer `analyzers`, `minReplicaCount: 0`, `maxReplicaCount: 4`.
- Cold start: before first ingest the stream may not exist; scaler stays inactive until ingest publishes.
- If scale-to-zero is still in cooldown, `smoke-keda.sh` warns and continues; scale-up after ingest is required to pass.

---

## Phase 5 — Observability

```bash
./deploy/scripts/smoke-observability.sh
```

Grafana (port-forward only; no Ingress):

```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# http://localhost:3000 — admin / chessforge
# dashboard: Chessforge pipeline
```

Alertmanager: `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093`

Notes:

- Argo Application `monitoring` installs kube-prometheus-stack (wave 2).
- NATS: chart `promExporter` sidecar on `:7777` + PodMonitor (native `:8222/metrics` is 404).
- Analyzer: `prometheus_client` on `:9090` (may be idle/scale-to-zero).
- Lost games: postgres-exporter custom query → `chessforge_lost_games` → alert `ChessforgeLostGames`.

---

## Phase 6 — Chaos Mesh (analyzer pod-kill)

```bash
./deploy/scripts/smoke-chaos.sh
# SCALE_WAIT_SECS=180 DRAIN_WAIT_SECS=360 ./deploy/scripts/smoke-chaos.sh
```

Manual sketch:

```bash
kubectl -n argocd get application chaos-mesh
kubectl -n chaos-mesh get pods
kubectl -n chessforge delete job ingest-sample --ignore-not-found
kubectl apply -f deploy/k8s/jobs/ingest-sample.yaml
# wait until analyzer pods are Running, then:
kubectl apply -f deploy/k8s/chaos/analyzer-pod-kill.yaml
kubectl -n chessforge get podchaos analyzer-pod-kill
# after drain:
kubectl -n chessforge exec chessforge-postgresql-0 -- \
  env PGPASSWORD=chessforge psql -U chessforge -d chessforge -c \
  "SELECT COUNT(*) AS games, COUNT(DISTINCT game_id) AS distinct_ids FROM games;"
kubectl -n chessforge delete podchaos analyzer-pod-kill --ignore-not-found
```

Notes:

- Argo Application `chaos-mesh` installs Chaos Mesh Helm **2.8.3** (wave 2); kind values use **containerd** (`/run/containerd/containerd.sock`).
- Experiment YAML is **not** always-on under Argo (same pattern as the ingest Job).
- Integrity uses **latest** ingest `games_enqueued` for `lost` (not `SUM` across re-smokes).
- Success: `games>=5`, `lost=0`, `COUNT(*) = COUNT(DISTINCT game_id)`.

---

## Suggested order after a fresh clone

```bash
./deploy/scripts/smoke-local.sh
./deploy/scripts/smoke-docker.sh
./deploy/kind-up.sh                      # full GitOps + pipeline
./deploy/scripts/smoke-pipeline.sh       # re-check without recreating kind
./deploy/scripts/smoke-keda.sh           # idle → scale-up after ingest
./deploy/scripts/smoke-observability.sh  # Prometheus/Grafana + scrapes
./deploy/scripts/smoke-chaos.sh          # PodChaos mid-run → lost=0
./deploy/kind-down.sh
```

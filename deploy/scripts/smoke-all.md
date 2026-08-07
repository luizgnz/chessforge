# Smoke tests — cheatsheet

Reproducible verification paths used across phases. Scripts live next to this file; full cluster bring-up stays in `deploy/kind-up.sh`.

| Path | Script / command | Expected result |
|------|------------------|-----------------|
| Phase 0 — local unit tests | `./deploy/scripts/smoke-local.sh` | pytest green |
| Phase 0 — local + Stockfish | `RUN_ANALYZE=1 ./deploy/scripts/smoke-local.sh` | pytest green; `lost=0` |
| Phase 1 — Docker image | `./deploy/scripts/smoke-docker.sh` | `lost=0` (1 game) |
| Phase 1 — CI (same as Docker) | GitHub Actions `image` job Smoke step | container exit 0 |
| Phase 3–4 — full bring-up | `./deploy/kind-up.sh` | Argo Healthy; Vault→ESO Secret; `games>=5` |
| Phase 2/3 — pipeline only | `./deploy/scripts/smoke-pipeline.sh` | ingest Job complete; `games>=5` |
| Phase 4 — KEDA scale | `./deploy/scripts/smoke-keda.sh` | idle `0` (or warn); after ingest replicas `>0`; `games>=5` |
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

## Phase 3–4 — full kind bring-up (GitOps + Vault/ESO + KEDA)

Creates kind, installs Argo CD, applies root Application, bootstraps Vault, waits for the stack, runs ingest, asserts Postgres count.

```bash
./deploy/kind-up.sh
# FORCE_KIND_LOAD=1 ./deploy/kind-up.sh   # build + kind load if needed
```

Success line: `SUCCESS Phase 3–4 smoke: games=N` with `N >= 5`.

Also verify:

```bash
kubectl -n argocd get applications
kubectl -n chessforge get secret chessforge-db
kubectl -n chessforge get deploy,scaledobject analyzer
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

## Suggested order after a fresh clone

```bash
./deploy/scripts/smoke-local.sh
./deploy/scripts/smoke-docker.sh
./deploy/kind-up.sh                 # full GitOps + pipeline
./deploy/scripts/smoke-pipeline.sh  # re-check without recreating kind
./deploy/scripts/smoke-keda.sh      # idle → scale-up after ingest
./deploy/kind-down.sh
```

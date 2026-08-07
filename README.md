# chessforge

Analyze PGN games with Stockfish. Local CLI (SQLite), container image (GHCR), and a kind + GitOps pipeline (NATS → workers → Postgres) with Vault + External Secrets and KEDA scale-to-zero on JetStream lag.

## Requirements

- Python 3.12+
- Stockfish (`brew install stockfish`) — local CLI without Docker
- Docker, [`kind`](https://kind.sigs.k8s.io/), [`helm`](https://helm.sh/), `kubectl`, `jq` — cluster path

## Setup (local CLI)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

```bash
python -m chessforge.analyze --source data/sample.pgn --depth 10 --max-games 5
python -m chessforge.report --eco C50
```

## Docker / GHCR

```bash
docker build -t chessforge:local .
docker run --rm chessforge:local
```

CI publishes `ghcr.io/luizgnz/chessforge:latest` on `main`. The package is **public** (same as the repo) so kind/nodes pull without an `imagePullSecret`. Vault/ESO stay for DB credentials only; private-package pull secrets are deferred.

### Make the package public (GitHub UI)

If anonymous `docker pull ghcr.io/luizgnz/chessforge:latest` still fails with unauthorized:

1. Open [github.com/users/luizgnz/packages/container/package/chessforge](https://github.com/users/luizgnz/packages/container/package/chessforge) (or **Packages** → **chessforge** from the profile/repo).
2. **Package settings** → **Change visibility** → **Public** → confirm.

(`gh` needs `read:packages` / `write:packages` to change this via API; the default `gh auth` token often lacks those scopes.)

## Phase 3–4 — GitOps on kind (Argo + Vault + ESO + KEDA)

Bootstrap (once): create kind + install Argo CD + apply the root Application.  
Argo reconciles Vault, ESO, KEDA, NATS, Postgres, the analyzer Deployment, and its ScaledObject from Git.  
DB credentials live in Vault; ESO syncs them to Secret `chessforge-db`.  
Analyzer replicas follow JetStream consumer lag (`minReplicaCount: 0`, `maxReplicaCount: 4`).

```bash
./deploy/kind-up.sh    # needs this repo pushed to GitHub (Argo pulls HEAD)
./deploy/kind-down.sh
```

Smoke success: Postgres has 5 games from `data/sample.pgn`.  
Design records: [`docs/DECISIONS.md`](docs/DECISIONS.md) **ADR-013** (GitOps), **ADR-014** (KEDA).

Verify scaling:

```bash
kubectl -n argocd get application keda chessforge
kubectl -n chessforge get deploy,scaledobject analyzer
# idle → replicas toward 0; after ingest Job → scale up within max 4
kubectl -n chessforge apply -f deploy/k8s/jobs/ingest-sample.yaml
kubectl -n chessforge get deploy,scaledobject analyzer -w
```

Demo Vault unseal material is written to `.vault-init.json` (gitignored) and Secret `vault-init` in the `vault` namespace — kind learning only.

By default `kind-up` relies on a **public** GHCR pull. On Apple Silicon (or if pull fails), use `FORCE_KIND_LOAD=1 ./deploy/kind-up.sh` to build and `kind load` a node-native image. If Postgres auth fails after changing the Vault password, delete the Postgres PVC and re-sync (`kubectl -n chessforge delete pvc data-chessforge-postgresql-0`).

## What this demonstrates

1. CPU-bound Stockfish analysis at fixed depth (`Threads=1`).
2. Idempotent persistence under redelivery.
3. Distributed ingest → NATS JetStream → analyzer workers → Postgres.
4. GitOps with Argo CD (app of apps).
5. Secrets via Vault + External Secrets Operator (no DB password in Git).
6. KEDA autoscaling on NATS JetStream lag (scale-to-zero).

Next: observability, Chaos Mesh.

## Docs

- Decision log: [`docs/DECISIONS.md`](docs/DECISIONS.md)

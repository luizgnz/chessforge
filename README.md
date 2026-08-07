# chessforge

Analyze PGN games with Stockfish. Local CLI (SQLite), container image (GHCR), and a kind + GitOps pipeline (NATS → workers → Postgres) with Vault + External Secrets.

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

CI publishes `ghcr.io/luizgnz/chessforge:latest` on `main`.

## Phase 3 — GitOps on kind (Argo + Vault + ESO)

Bootstrap (once): create kind + install Argo CD + apply the root Application.  
Argo reconciles Vault, ESO, NATS, Postgres, and the analyzer Deployment from Git.  
DB credentials live in Vault; ESO syncs them to Secret `chessforge-db`.

```bash
./deploy/kind-up.sh    # needs this repo pushed to GitHub (Argo pulls HEAD)
./deploy/kind-down.sh
```

Smoke success: Postgres has 5 games from `data/sample.pgn`.  
Design record: [`docs/DECISIONS.md`](docs/DECISIONS.md) **ADR-013**.

Demo Vault unseal material is written to `.vault-init.json` (gitignored) and Secret `vault-init` in the `vault` namespace — kind learning only.

## What this demonstrates

1. CPU-bound Stockfish analysis at fixed depth (`Threads=1`).
2. Idempotent persistence under redelivery.
3. Distributed ingest → NATS JetStream → analyzer workers → Postgres.
4. GitOps with Argo CD (app of apps).
5. Secrets via Vault + External Secrets Operator (no DB password in Git).

Next: KEDA, observability, Chaos Mesh.

## Docs

- Decision log: [`docs/DECISIONS.md`](docs/DECISIONS.md)

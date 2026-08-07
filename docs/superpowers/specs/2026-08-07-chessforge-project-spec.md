# Chessforge — project specification

**Date:** 2026-08-07  
**Document status:** living draft (Phase 0 and Phase 1 are implemented)  
**Preferred GitOps tool:** Argo CD (not Flux)

## 1. Vision

Chessforge analyzes chess games at scale with Stockfish to learn distributed systems and chaos engineering on Kubernetes.

**Product (what it does):**

1. Ingests PGN games.
2. Evaluates each move with Stockfish (CPU-bound, reproducible workload).
3. Persists metrics (ACPL, blunders, first-blunder ply, etc.).
4. Exposes queries/reports (e.g. blunders by ECO opening and Elo band).
5. Verifies integrity: `enqueued` vs `analyzed` vs `lost`.

**Platform (what the stack is for):**

- Queues, event-driven autoscaling, GitOps, and chaos experiments with a measurable success criterion (`lost=0` after turbulence).

## 2. GitOps lifecycle (definition of “met”)

GitOps is considered **met** only when **all** of these hold:

| # | Condition | Description |
|---|-----------|-------------|
| G1 | Desired state in Git | Cluster manifests / Helm / Kustomize live in the repo (or a dedicated GitOps repo). |
| G2 | Changes via Git | The cluster is not “fixed” with routine `kubectl apply`; Git is changed instead. |
| G3 | Reconciliation agent | Argo CD watches Git and applies desired state to the cluster. |
| G4 | Drift detection | If someone mutates the cluster outside Git, Argo detects it (and preferably reconciles). |
| G5 | Declarative app + infra | Chessforge services (ingest, workers, API) and dependencies (NATS, DB, KEDA, etc.) are declared and versioned. |

**Note:** Manifests in Git applied only with `kubectl` is **not** full GitOps (missing G3–G4). Application code alone in Git is also **not** enough (missing G1–G5 for deployment).

### Global status today

| Question | Answer |
|----------|--------|
| Is the GitOps lifecycle met now? | **No** |
| What unlocks it? | Phase 3 (Argo CD reconciling cluster manifests) |
| Chosen tool | **Argo CD** |

## 3. Phases

Status legend: `done` · `pending` · `partial`

### Phase 0 — Local draft (no Kubernetes)

| Field | Value |
|-------|--------|
| **Status** | `done` |
| **Goal** | Prove the product loop without a cluster |
| **Input** | PGN (`data/sample.pgn`) |
| **Output** | SQLite + CLI `report` |
| **GitOps** | **Not met** (no cluster or Argo; code in Git only) |

**Technologies**

| Technology | Role |
|------------|------|
| Python 3.12+ | App / CLIs |
| `python-chess` | PGN parse + UCI |
| Stockfish | Analysis engine (`Threads=1`, fixed depth) |
| SQLite | Local persistence |
| pytest | Unit tests |

**Deliverables**

- Package `chessforge/` (`analyze`, `report`, `db`, `engine`, `analyze_game`)
- Local specs/plans under `docs/superpowers/`
- Integrity criterion: `lost=0` on a run

**Out of scope for this phase:** K8s, NATS, KEDA, Postgres, Argo, Chaos Mesh, HTTP API.

---

### Phase 1 — Container and worker contract

| Field | Value |
|-------|--------|
| **Status** | `done` (Docker + GHA; see dedicated spec) |
| **Spec** | `docs/superpowers/specs/2026-08-07-phase1-docker-gha-design.md` |
| **Goal** | Package the analyzer as a reproducible image; same analysis contract as local |
| **GitOps** | **Not met** (image/CI yes; no cluster reconciliation yet) |

**Technologies**

| Technology | Role |
|------------|------|
| Docker (slim-bookworm multi-stage) | Worker image (apt Stockfish + app) |
| Python (same Phase 0 code) | Analysis logic |
| GitHub Actions + GHCR | pytest, build, smoke, push `:sha` / `:latest` on `main` |

**Deliverables**

- `Dockerfile` + `.dockerignore` + `.github/workflows/ci.yml`
- `STOCKFISH_PATH=/usr/games/stockfish` in image; CMD smoke with `--max-games 1`
- Local smoke: `docker build -t chessforge:local . && docker run --rm chessforge:local`

---

### Phase 2 — Minimal Kubernetes + queue + persistence

| Field | Value |
|-------|--------|
| **Status** | `pending` |
| **Goal** | Distributed pipeline: ingest → queue → workers → DB; basic query API |
| **GitOps** | **Not met** if deploy is manual `kubectl`; **partial** if manifests already live in Git but Argo is not wired yet |

**Technologies**

| Technology | Role |
|------------|------|
| Kubernetes | Orchestration |
| NATS JetStream | Queue / redelivery (`ack_wait` aligned with analysis duration) |
| Postgres | SQLite replacement in the cluster |
| Deployments / Jobs | `ingest`, `analyzer` workers, query service |
| Manifests (YAML / Kustomize) | Desired state in repo |

**Deliverables**

- Ingest publishes games; workers consume and persist
- Idempotency (`ON CONFLICT DO NOTHING` or equivalent) under redelivery
- Per-run integrity metric (`enqueued` / `analyzed` / `lost`)
- Thoughtful `terminationGracePeriodSeconds` and CPU limits (avoid silent throttle; Stockfish 1 thread)

---

### Phase 3 — GitOps with Argo CD

| Field | Value |
|-------|--------|
| **Status** | `pending` |
| **Goal** | Git as the single source of truth for the cluster; Argo reconciles |
| **GitOps** | **Met** (G1–G5) for the perimeter Argo manages |

**Technologies**

| Technology | Role |
|------------|------|
| Git | Source of truth |
| Argo CD | Pull/reconcile desired state |
| Kustomize or Helm | Declarative packaging (pick one and keep it) |

**Deliverables**

- Argo Application(s) pointing at the manifests repo/path
- Flow: PR → merge → sync (auto or manual) → cluster
- Drift visible in Argo UI/CLI
- Document: routine `kubectl apply` is forbidden except emergencies (then commit the fix)

**GitOps acceptance criteria**

- Change replicas or image only via Git and see Argo reflect it without manual apply.
- Mutate a Deployment by hand and see OutOfSync (and restore if auto-sync is on).

---

### Phase 4 — Event-driven autoscaling (KEDA)

| Field | Value |
|-------|--------|
| **Status** | `pending` |
| **Goal** | Scale workers from NATS queue depth, not CPU alone |
| **GitOps** | **Met if** KEDA `ScaledObject`/CRDs live in Git and Argo applies them (inherits Phase 3) |

**Technologies**

| Technology | Role |
|------------|------|
| KEDA | Event-driven autoscaling |
| NATS scaler (KEDA) | Scales `analyzer` from JetStream backlog |
| Argo CD | Remains the applicator |

**Deliverables**

- Load up → more pods; drain queue → scale to zero or minimum
- CPU/memory limits consistent with `Threads=1` per Stockfish process

---

### Phase 5 — Observability

| Field | Value |
|-------|--------|
| **Status** | `pending` |
| **Goal** | See analysis latency, errors, queue depth, and run integrity |
| **GitOps** | **Met if** metrics/dashboard stack is declared in Git + Argo |

**Technologies (proposed)**

| Technology | Role |
|------------|------|
| Prometheus | Metrics |
| Grafana | Dashboards |
| Structured logs (stdout → cluster log stack) | Traceability by `run_id` / `game_id` |

**Deliverables**

- Dashboard: queue depth, games/sec, failed, `lost`, p95 duration per game
- Minimal alerts: `lost > 0` on a “complete” run; queue growing with no consumers

---

### Phase 6 — Chaos engineering

| Field | Value |
|-------|--------|
| **Status** | `pending` |
| **Goal** | Prove resilience with a verifiable success criterion |
| **GitOps** | **Met if** experiment CRDs live in Git (or an experiments repo) and cluster runtime stays under Argo |

**Technologies (proposed)**

| Technology | Role |
|------------|------|
| Chaos Mesh (or Litmus) | Injected faults (kill pod, network delay, etc.) |
| NATS redelivery + idempotency | Message recovery |
| `lost` metric | Experiment success/failure criterion |

**Example experiments**

1. Kill `analyzer` pods mid-run → redelivery → `lost=0`, no duplicates.
2. Network delay to Postgres/NATS → controlled timeouts, no corruption.
3. Mass eviction during KEDA scale-up → run integrity holds.

**Chaos success criterion:** after the experiment, the run reports `lost=0` and there are no duplicate rows by `game_id`.

---

## 4. Phase → technologies → GitOps map

| Phase | Main technologies | GitOps met? |
|-------|-------------------|-------------|
| 0 Local CLI | Python, Stockfish, SQLite | **No** |
| 1 Container | Docker, CI, Stockfish in image | **No** |
| 2 K8s + NATS + Postgres | Kubernetes, NATS JetStream, Postgres | **No** (or partial: manifests in Git without Argo) |
| 3 Argo CD | Git + Argo CD (+ Kustomize/Helm) | **Yes** (GitOps lifecycle active) |
| 4 KEDA | KEDA + NATS scaler | **Yes** (if under Argo) |
| 5 Observability | Prometheus, Grafana | **Yes** (if under Argo) |
| 6 Chaos | Chaos Mesh + `lost` metric | **Yes** (platform under Argo; measurable chaos) |

## 5. Decisions already made

| Decision | Choice |
|----------|--------|
| Chess engine | Stockfish |
| GitOps tool | Argo CD (not Flux) |
| Queue (cluster phase) | NATS JetStream |
| Autoscaling | KEDA (by queue, not CPU alone) |
| Pre-cluster draft | Python CLI + SQLite (Phase 0) |
| Default draft depth | 10 |
| Stockfish threads | 1 (avoid oversubscribe in containers) |

## 6. Out of scope (for now)

- Engine other than Stockfish
- Rich web UI / commercial product
- Multi-cluster / multi-region
- ML training on evals

## 7. Global success criteria

1. **Product:** games can be analyzed and blunders queried by ECO/Elo.
2. **Integrity:** runs with `lost=0` in normal operation.
3. **GitOps:** from Phase 3 onward, deploy changes only via Git + Argo.
4. **Chaos:** at least one documented experiment where killing workers does not produce `lost > 0` or duplicates.

## 8. Internal references

- Phase 0 design: `docs/superpowers/specs/2026-08-07-local-cli-draft-design.md`
- Phase 0 plan: `docs/superpowers/plans/2026-08-07-local-cli-draft.md`
- Local README: `README.md`

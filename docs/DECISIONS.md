# Chessforge — decision log

**Purpose:** Record *what* we chose, *why*, and *what we rejected*, per phase.  
**Language:** English only (repo convention).  
**Status:** Living document — append new ADRs; do not rewrite history silently (add a supersession note instead).

---

## How to read this

Each entry is an ADR-style decision:

| Field | Meaning |
|-------|---------|
| **Context** | Problem / force that required a choice |
| **Decision** | What we picked |
| **Rationale** | Why this fits chessforge’s learning goals |
| **Rejected** | Alternatives and why not (now) |
| **Phase** | When the decision applies |
| **GitOps impact** | Whether this advances the GitOps lifecycle |

GitOps is **met** only from Phase 3 (Argo CD reconciliation). Earlier phases may put YAML in Git without meeting GitOps.

---

## ADR-001 — Product domain: chess analysis with Stockfish

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | Cross-cutting (motivates all phases) |
| **Status** | Accepted |

**Context:** Need a real CPU-bound workload with a measurable success metric for distributed systems and chaos engineering practice.

**Decision:** Analyze PGN games with **Stockfish**; persist ACPL/blunder metrics; treat `lost=0` (and no duplicate `game_id`s) as the integrity signal.

**Rationale:**

- Stockfish is open, deterministic at fixed depth, and legitimately CPU-heavy.
- Chess metrics give a clear product loop (ingest → analyze → query), not a fake “sleep” microservice.
- Integrity (`enqueued` / `analyzed` / `lost`) maps cleanly onto queue redelivery and chaos experiments.

**Rejected:**

- Synthetic CPU burn (no product narrative, weak demo).
- Calling a remote chess API (network-bound, not under our control).
- Training ML models (out of scope for ops/chaos learning).

**GitOps impact:** None directly.

---

## ADR-002 — Implementation language: Python

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 0+ (revisited when discussing Go/Rust) |
| **Status** | Accepted |

**Context:** Need PGN parsing, UCI to Stockfish, and fast iteration while learning K8s/queues/chaos.

**Decision:** Keep the analyzer and glue code in **Python** (`python-chess`).

**Rationale:**

- `python-chess` gives mature PGN + UCI helpers; the heavy work is Stockfish (C++), not the interpreter.
- Learning goals are the platform (NATS, K8s, KEDA, Argo, chaos), not rewriting chess I/O.
- Phase 0 already shipped in Python; rewrite cost has poor ROI for this repo.

**Rejected:**

- **Rust:** excellent for memory-safe binaries / distroless, but weaker chess ecosystem convenience and slower iteration; ROI low vs platform learning.
- **Go:** better cloud-native single-binary story than Python; still a rewrite for little gain on the critical path (Stockfish).
- Distroless-driven language change: distroless improves runtime hardening, not build speed or chaos outcomes.

**GitOps impact:** None directly.

---

## ADR-003 — Phase 0: local CLI + SQLite (no Kubernetes)

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 0 |
| **Status** | Accepted (implemented) |

**Context:** Validate the product loop before paying cluster complexity.

**Decision:** Python package with `analyze` / `report` CLIs, Stockfish on the host, **SQLite**, idempotent inserts, integrity printout.

**Rationale:**

- Proves analysis, persistence, and `lost=0` without NATS/K8s.
- Keeps Stockfish `Threads=1` discipline early (container-ready habit).
- Small sample PGN is enough for smoke learning.

**Rejected:**

- Starting directly on Kubernetes (too many variables at once).
- HTTP API in Phase 0 (YAGNI).
- Postgres in Phase 0 (SQLite is enough locally).

**GitOps impact:** **Not met** — application code in Git only; no cluster desired state.

---

## ADR-004 — Phase 1: Docker slim multi-stage + GitHub Actions + GHCR

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 1 |
| **Status** | Accepted (implemented) |

**Context:** Need a reproducible analyzer image and automated build before Kubernetes.

**Decision:**

- Base: `python:3.12-slim-bookworm` multi-stage (not distroless).
- Stockfish via **apt** (no compile-from-source).
- CI: pytest → docker build → smoke → push `ghcr.io/<owner>/<repo>:<sha>` and `:latest` on `main`.

**Rationale:**

- Fast builds come from layer/pip cache and apt Stockfish, not from distroless.
- Slim keeps a shell for debugging while learning.
- GHCR ties images to the same GitHub repo/Actions workflow.
- Smoke before `:latest` avoids publishing a broken tag.

**Rejected:**

- **Distroless (now):** smaller attack surface, but harder debug and no faster builds; revisit when the worker is stable.
- Docker Hub as primary registry (extra account; GHCR is enough).
- Compiling Stockfish in the Dockerfile (slow, brittle).

**GitOps impact:** **Not met** — publishes an image; no Argo reconciliation.

---

## ADR-005 — Phase 2 cluster target: kind (not minikube / cloud)

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 2 |
| **Status** | Accepted |

**Context:** Need a local Kubernetes cluster for the distributed pipeline without cloud cost.

**Decision:** Use **kind** (Kubernetes in Docker).

**Rationale:**

- Nodes are containers; fits the existing Docker/OrbStack workflow.
- Fast create/reset; easy `kind load docker-image` for local iteration.
- Common pattern for app+manifest learning and CI-like loops.

**Rejected:**

- **minikube:** fine, but heavier VM-oriented workflow; fewer benefits for this app-centric phase.
- **EKS/GKE/AKS (now):** more realistic later; cost and setup distract from the pipeline lesson.

**GitOps impact:** Still **not met** until Argo (Phase 3); kind is only the runtime.

---

## ADR-006 — Phase 2 slice: pipeline only (no query API yet)

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 2 (first slice) |
| **Status** | Accepted |

**Context:** Phase 2 could include ingest, queue, workers, DB, *and* a query API. That is a large bite.

**Decision:** First slice proves **ingest → NATS → analyzer workers → Postgres** with integrity (`lost=0`). No HTTP report API and no `report` Job yet. Optional verification via worker/ingest logs and `psql` counts.

**Rationale:**

- The learning target is the distributed loop (queue, redelivery, idempotency, multi-replica workers).
- Query/report only *reads* data already written; it does not prove NATS/K8s behavior.
- Reduces surface area so chaos/KEDA later have a clear baseline.

**Rejected (for this slice):**

- HTTP API (FastAPI, etc.) — defer.
- `report` CLI as a Job — defer (cheap follow-up after pipeline works).

**GitOps impact:** None until manifests + Argo; this is scope control.

---

## ADR-007 — Message bus: NATS JetStream (not Kafka / RabbitMQ)

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 2+ |
| **Status** | Accepted |

**Context:** Workers must consume analysis jobs with redelivery after crashes; later KEDA should scale on queue depth.

**Decision:** **NATS JetStream** as the work queue.

**Rationale:**

- Fits a job queue: publish game tasks, ack after persist, redeliver on failure.
- Lightweight enough for kind.
- Aligns with planned KEDA NATS scaler (Phase 4).
- NATS is **not** part of Kubernetes; it is a separate messaging system we deploy *onto* the cluster.

**Rejected:**

- **Kafka:** partitioned log / high-throughput streaming platform; operationally heavy for kind; overkill for “analyze this game” tickets.
- **RabbitMQ:** valid alternative; slightly more classic-ops weight; NATS already chosen in the project spec and pairs well with KEDA plans.
- **Cloud queues (SQS, etc.):** poor fit for local kind-first learning.
- **No queue (direct HTTP between pods):** fragile; weak redelivery story; poor chaos practice.

**GitOps impact:** None by itself; charts/manifests will live in Git (partial toward GitOps).

---

## ADR-008 — Phase 2 packaging: Helm for NATS/Postgres + plain YAML for app

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 2 |
| **Status** | Accepted |

**Context:** Need Postgres and NATS on kind without hand-writing every operational detail; keep our app manifests understandable.

**Decision:**

- **Helm** charts for NATS and Postgres.
- **Plain Kubernetes YAML** for chessforge `ingest` Job and `analyzer` Deployment (and related ServiceAccount/ConfigMap/Secret refs).

**Rationale:**

- Production-shaped Postgres/NATS (PVC, auth, probes, JetStream) is painful to recreate from scratch in YAML.
- App YAML stays readable for learning Deployments/Jobs/limits/`terminationGracePeriodSeconds`.
- Kustomize can wait until multi-env or Argo (Phase 3).

**Rejected:**

- **All-YAML (no Helm):** maximum control, maximum toil for DB/queue.
- **Kustomize for app now:** useful later; extra structure before we need overlays.
- **Helm for the app too:** unnecessary indirection for two simple workloads.

**GitOps impact:** **Partial at best** — desired state may live in Git and be applied with `helm`/`kubectl`. Full GitOps still requires Argo (Phase 3).

---

## ADR-009 — Phase 2 topology: Job ingest + Deployment workers

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 2 |
| **Status** | Accepted |

**Context:** How to run ingest and analyzers on kind for the sample PGN workload.

**Decision:**

- **Job** `ingest`: read bundled/sample PGN (ConfigMap or image), publish one NATS message per game, record ingest run, exit.
- **Deployment** `analyzer`: N replicas consume JetStream, run Stockfish (`Threads=1`), persist to Postgres idempotently.

**Rationale:**

- Matches a batch sample run without a long-lived ingest service.
- Deployment workers are the right shape for later KEDA and chaos (kill pods, redelivery).
- Clear success path: Job completes, workers drain queue, `lost=0`, row counts in Postgres.

**Rejected:**

- Always-on ingest Deployment — YAGNI with only `sample.pgn`.
- One-Job-per-game / Job-only workers — weak rehearsal for scaling and worker chaos.

**GitOps impact:** None directly.

---

## ADR-010 — GitOps tool: Argo CD (not Flux) — deferred to Phase 3

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 3 (chosen early) |
| **Status** | Accepted — design detailed in ADR-013 (not implemented yet) |

**Context:** Need a GitOps reconciler; user preference for Argo CD over Flux.

**Decision:** Use **Argo CD** in Phase 3. Phase 2 may still apply with Helm/kubectl.

**Rationale:**

- GitOps = Git desired state + continuous reconciliation + drift detection — not merely “YAML exists in Git”.
- Argo CD matches the user’s preferred UX/ecosystem.
- Separating “make the pipeline work” (Phase 2) from “make GitOps true” (Phase 3) avoids mixing failures.

**Rejected:**

- **Flux** — valid; not preferred here.
- Calling Phase 1/2 “GitOps” because CI builds images or YAML is in Git — incorrect.

**GitOps impact:** **Met starting Phase 3** when Argo reconciles cluster state from Git.

---

## ADR-011 — Future autoscaling: KEDA on NATS (Phase 4)

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 4 (chosen early) |
| **Status** | Accepted (not implemented yet) |

**Context:** CPU autoscaling is a poor signal for queue depth with single-threaded Stockfish workers.

**Decision:** Plan **KEDA** scaled on NATS/JetStream backlog (not HPA-on-CPU alone).

**Rationale:**

- Work arrives as messages; scale should follow the queue.
- `Threads=1` means CPU metrics mislead under throttle/limits.
- Depends on Phase 2 queue + Phase 3 GitOps for clean CRD management.

**Rejected:**

- HPA on CPU as the primary strategy.
- Over-provisioning fixed replicas forever.

**GitOps impact:** KEDA objects should be applied via Argo once Phase 3 exists.

---

## ADR-012 — Secrets: HashiCorp Vault + External Secrets Operator (with Phase 3)

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 3 (chosen now; implement with Argo CD) |
| **Status** | Accepted — design detailed in ADR-013 (not implemented yet) |

**Context:** Phase 2 stores demo DB credentials in Git (`deploy/k8s/secret.yaml`, Helm values). Need a production-shaped secrets path without blocking the working pipeline.

**Decision:**

- Use **HashiCorp Vault** as the secrets backend (store / policy / audit).
- Use **External Secrets Operator (ESO)** to sync Vault → Kubernetes `Secret` (e.g. `chessforge-db` for `DATABASE_URL`).
- Implement in **Phase 3 together with Argo CD**, not as a separate Phase 2.5 on kind.

**Rationale:**

- Vault governs secrets; ESO keeps workloads on idiomatic `secretKeyRef` (current ingest/analyzer manifests).
- Vault + ESO is a common prod pattern and more portable than app-level Vault SDK calls.
- Bundling with Argo avoids reworking the cluster twice and makes secret *references* (ExternalSecret, Vault auth) part of the GitOps desired state.
- Phase 2 demo plaintext secrets remain acceptable until Phase 3 lands.

**Rejected (for now):**

- **Vault alone + Agent Injector** — prod-valid, but more Vault-specific annotations; weaker fit with current Secret-based env.
- **ESO + cloud SM only (no Vault)** — fine later if cloud is mandated; Vault is better for kind-first learning of a self-hosted manager.
- **Sealed Secrets** — good GitOps-lite; chosen against in favor of a real manager + sync operator.
- **Implement Vault+ESO immediately on kind (Phase 2.5)** — deferred so GitOps and secrets arrive together.

**GitOps impact:** Phase 3 should reconcile Argo apps *and* ESO/`ExternalSecret` (and Vault install or its bootstrap story) from Git. Plaintext DB passwords should leave the repo when this ships.

---

## ADR-013 — Phase 3 design: Argo App of Apps + Vault Raft + ESO + GHCR

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 3 |
| **Status** | Accepted — implemented (`deploy/gitops`, Vault bootstrap, ESO; see changelog) |

**Context:** Phase 2 pipeline works on kind via imperative Helm/`kubectl`. Need GitOps (G1–G5) and to remove plaintext DB credentials from Git, using the already-accepted Argo CD + Vault + ESO stack (ADR-010, ADR-012).

### Locked choices (brainstorm)

| Topic | Choice |
|-------|--------|
| Cluster | Same **kind** cluster for Argo, Vault, ESO, NATS, Postgres, app |
| Argo shape | **App of Apps** (root Application → child Applications) |
| Vault | Official Helm chart, **single-node Raft**, documented demo bootstrap (init/unseal/KV/auth) — not `vault -dev` |
| Bootstrap boundary | `kind-up` creates kind + installs **Argo CD only** + applies root Application; Argo owns the rest |
| Images | Pull **`ghcr.io/luizgnz/chessforge`** (public package or pull secret via ESO if private) |

### Goal

1. Argo continuously reconciles desired state from this Git repo.
2. Vault stores sensitive values; ESO materializes Kubernetes `Secret`s (e.g. `chessforge-db` / `DATABASE_URL`).
3. Plaintext `deploy/k8s/secret.yaml` (and DB passwords in Helm values committed to Git) go away.
4. Sample pipeline still works: ingest → NATS → analyzers → Postgres.
5. GitOps lifecycle is **met**.

### Bootstrap (once, outside Argo)

1. Create kind cluster.
2. Install Argo CD (Helm or upstream install manifests).
3. Apply root `Application` (app-of-apps) pointing at the repo path (e.g. `deploy/argocd/root.yaml` or `deploy/gitops/root-app.yaml`).

No routine `kubectl apply` for app/platform after that.

### Applications under the root

| Child Application | Delivers |
|-------------------|----------|
| `vault` | Vault Helm chart, 1-node Raft |
| `eso` | External Secrets Operator |
| `nats` | NATS Helm chart with JetStream (reuse Phase 2 values) |
| `postgres` | Bitnami PostgreSQL Helm chart — **no DB password committed in Git** |
| `chessforge` | App YAML: `analyzer` Deployment + `ingest` Job; image from GHCR |
| `secrets` | `SecretStore` / `ClusterSecretStore` + `ExternalSecret` → `chessforge-db` |

Exact directory layout is an implementation detail; keep platform vs app separable so Phase 4 (KEDA) can add another child Application.

### Secrets flow

```text
Vault KV  ──(ESO)──►  Secret/chessforge-db  ──►  ingest / analyzer (DATABASE_URL)
```

- Demo bootstrap (Job or documented script after Vault is ready): init/unseal if required, enable KV + Kubernetes auth, write demo path (e.g. `secret/chessforge/db`), create policy/role for ESO.
- Repo holds only references (`ExternalSecret`, store config), not the password material.
- Postgres Helm must not rely on plaintext password in Git; use a Secret created/synced for chart consumption and/or generate-once bootstrap that also seeds Vault (implementation picks one path; acceptance = nothing sensitive in Git).

### Image policy

- Manifests reference `ghcr.io/luizgnz/chessforge` with an explicit tag (`latest` acceptable for kind learning; prefer git SHA when wiring CI later).
- If GHCR package is private: `imagePullSecret` supplied via ESO from Vault (same pattern as DB URL).

### Success criteria

1. Change analyzer replicas (or image tag) in Git → Argo syncs → cluster reflects it without routine `kubectl apply`.
2. Manual drift on a managed Deployment → Argo shows OutOfSync (and restores if auto-sync is on).
3. Workloads get `DATABASE_URL` from an ESO-synced Secret whose source is Vault.
4. Sample ingest still yields ≥5 games in Postgres.
5. GitOps checklist G1–G5 from the project vision is satisfied for the managed perimeter.

### Out of scope (Phase 3)

- KEDA (Phase 4), observability (Phase 5), chaos (Phase 6)
- Query HTTP API / report Job
- Multi-cluster / management cluster
- Vault HA beyond single-node Raft demo
- Recreating deleted `docs/superpowers/specs/` trees — this ADR is the design record

### Rejected alternatives (this design pass)

- Vault `-dev` only — too ephemeral for the learning goal of Raft bootstrap.
- Argo managing only the app while Helm stays imperative for NATS/Postgres — weaker GitOps than the chosen bootstrap boundary.
- Rendering all of Vault/NATS/Postgres as hand-written YAML — unnecessary toil.
- Keeping plaintext `secret.yaml` in Git after Phase 3 ships — contradicts ADR-012.

**GitOps impact:** **Met** when this design is implemented and the success criteria pass.

---

## Decision index by phase

| Phase | ADRs | GitOps met? |
|-------|------|-------------|
| 0 Local CLI | 001, 002, 003 | No |
| 1 Docker + GHA + GHCR | 004 | No |
| 2 kind + NATS + Postgres + app YAML | 005–009 | No / partial (Git + kubectl/helm) |
| 3 Argo CD + Vault + ESO | 010, 012, **013** | Yes (when kind-up Phase 3 smoke passes) |
| 4 KEDA | 011 | Yes if under Argo |
| 5 Observability | (pending ADR) | Yes if under Argo |
| 6 Chaos | (pending ADR; criterion from 001) | Yes if under Argo |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-08-07 | Initial decision log (ADR-001 … ADR-011) committed with Phase 2 design direction. |
| 2026-08-07 | Phase 2 pipeline implemented: `deploy/kind-up.sh`, ingest/worker modules, Helm NATS+Postgres, kind YAML. |
| 2026-08-07 | ADR-012: Vault + ESO accepted; implement with Argo in Phase 3 (not Phase 2.5). |
| 2026-08-07 | ADR-013: Phase 3 design accepted (App of Apps, Vault Raft, ESO, GHCR, Argo-owned platform). |
| 2026-08-07 | Phase 3 implementation: `deploy/gitops` app-of-apps, Vault/ESO/NATS/Postgres via Argo, vault-bootstrap, plaintext `secret.yaml` removed. |

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
| **Status** | Accepted — implemented per ADR-014 |

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
| Images | Pull **`ghcr.io/luizgnz/chessforge`** (**public** GHCR package while the repo is public) |

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
- GHCR package stays **public** while the GitHub repo is public — cluster pulls need no `imagePullSecret`.
- Private GHCR + Vault/ESO `dockerconfigjson` pull secret is **deferred** (not required for Phase 3 while the package is public).

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

## ADR-014 — Phase 4 design: KEDA on NATS JetStream backlog

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 4 |
| **Status** | Implemented |
| **Supersedes / details** | ADR-011 (direction); this ADR is the Phase 4 design + implementation record |

**Context:** Phase 3 GitOps is live (Argo app-of-apps, Vault+ESO, NATS JetStream, Postgres, analyzer Deployment at fixed `replicas: 2`). CPU HPA is a weak signal for queue work with Stockfish `Threads=1`. ADR-011 already chose KEDA on JetStream backlog; Phase 4 needs a concrete GitOps layout and scaler settings for kind learning.

### Approaches considered

| Approach | Summary | Trade-offs |
|----------|---------|------------|
| **A — KEDA Helm child Application + ScaledObject in app YAML (recommended)** | New Argo Application `keda` installs the official KEDA Helm chart; `ScaledObject` lives under `deploy/k8s/app/` (chessforge Application) targeting Deployment `analyzer` with trigger `nats-jetstream`. | Matches Phase 3 pattern (ESO/Vault as Helm apps; workload YAML plain). Sync-wave orders CRDs before ScaledObject. Minimal new structure. |
| **B — KEDA Helm child + separate autoscaling Application** | Same operator install; ScaledObject in e.g. `deploy/k8s/autoscaling/` owned by a dedicated Argo Application. | Cleaner separation of scaling CRDs vs Deployment; extra Application and path for one object — YAGNI on kind. |
| **C — Imperative KEDA install; only ScaledObject in Git** | `kubectl`/Helm install KEDA outside Argo; Git holds ScaledObject only. | Breaks the ADR-013 bootstrap boundary (“Argo owns the rest”); weaker GitOps demo. |

**Decision:** **Approach A.**

### Locked choices

| Topic | Choice |
|-------|--------|
| Operator install | Official **KEDA Helm** chart via new Argo child Application `keda` (same multi-source / chart pattern as `eso`) |
| Namespace | `keda` (operator); ScaledObject in `chessforge` |
| Sync wave | `keda` before `chessforge` (e.g. wave `1` or `2`; NATS stays wave `3`, app wave `4`) so CRDs exist before ScaledObject sync |
| Scale target | Deployment `analyzer` in namespace `chessforge` |
| Trigger | KEDA `nats-jetstream` |
| Stream / consumer | `CHESSFORGE` / `analyzers` (from `chessforge/messaging.py`) |
| Monitoring endpoint | NATS HTTP monitor port **8222** on headless Service `chessforge-nats-headless.chessforge.svc.cluster.local:8222` (ClusterIP `chessforge-nats` exposes 4222 only) |
| Account | `$G` (default; no NATS accounts configured) |
| Replica bounds | **`minReplicaCount: 0`**, **`maxReplicaCount: 4`** (kind-friendly; demonstrates scale-to-zero) |
| Lag | `lagThreshold: "1"` (≈ one pending/unacked message per replica target); `activationLagThreshold: "0"` (wake from zero when any lag) |
| Polling / cooldown | Prefer snappy learning defaults (e.g. `pollingInterval: 5`, `cooldownPeriod: 60`); exact numbers tunable at implement time |
| Worker CPU | Keep Stockfish **`Threads=1`** and existing analyzer **CPU requests/limits** (`500m` / `1`) — do not raise threads to “help” HPA |
| Deployment replicas | Once ScaledObject is live, **KEDA owns replica count**; drop or stop relying on static `replicas: 2` in the Deployment |
| Auth | No NATS monitor auth today → no `TriggerAuthentication` required |
| Docs | Design lives only in this file (`docs/DECISIONS.md`); no `docs/superpowers/specs/` |

### Goal

1. Analyzer replica count follows JetStream consumer lag, not CPU alone.
2. Idle queue → scale toward **zero**; backlog after ingest → scale up within `maxReplicaCount`.
3. KEDA operator and ScaledObject are desired state under Argo (GitOps preserved).
4. Sample pipeline integrity unchanged: ingest → NATS → analyzers → Postgres, `lost=0` / games persisted.

### GitOps layout (intended)

| Child Application | Delivers |
|-------------------|----------|
| `keda` (**new**) | KEDA Helm chart (`kedacore/keda`), CRDs + operator in `keda` |
| `chessforge` (existing) | App YAML **plus** `ScaledObject` (e.g. `deploy/k8s/app/analyzer-scaledobject.yaml`) |

Root Application already globs `deploy/gitops/applications/` — adding `keda.yaml` is enough for discovery.

### Scaling flow

```text
ingest Job ──publish──► JetStream CHESSFORGE / durable analyzers
                              │
                              │ lag (pending + ack-pending)
                              ▼
                     KEDA nats-jetstream scaler
                              │
                              ▼
                     ScaledObject → Deployment/analyzer replicas
                              │
                              ▼
                     workers (Threads=1) ──persist──► Postgres
```

**Cold start:** Stream/consumer are created by ingest/worker `ensure_stream_and_consumer`. Before the first ingest, monitoring may report stream-not-found and the scaler stays inactive — acceptable for learning. After ingest creates the stream and publishes, lag activates scale-from-zero. If that proves flaky on kind, fall back to `minReplicaCount: 1` without changing the rest of the design.

### Success criteria

1. With an empty (or drained) queue, analyzer replicas reach **0** (or stay at min) without manual `kubectl scale`.
2. Running the sample ingest Job produces backlog → KEDA scales analyzer replicas **up** (observed via `kubectl get deploy,scaledobject -n chessforge`).
3. After the queue drains and cooldown elapses, replicas scale **down** again.
4. Changing ScaledObject/`keda` Application manifests in Git → Argo syncs (no routine imperative Helm for KEDA).
5. Sample still yields ≥5 games in Postgres; Stockfish remains `Threads=1` with existing CPU limits.

### Out of scope (Phase 4)

- Observability stack (Phase 5), Chaos Mesh (Phase 6)
- Query HTTP API / report Job
- HPA-on-CPU as primary scaler; Prometheus adapter custom metrics
- NATS auth / TLS for the monitoring endpoint
- Multi-cluster KEDA; production capacity planning

### Rejected alternatives (this design pass)

- **Approach B** — separate autoscaling Application for one ScaledObject (extra indirection now).
- **Approach C** — imperative KEDA install (weakens GitOps vs ADR-013).
- **HPA on CPU** — already rejected in ADR-011; still wrong for `Threads=1` queue workers.
- **Raising Stockfish Threads or removing CPU limits** to make CPU HPA “work” — fights the learning goal.
- **`minReplicaCount: 1` as the default** — valid fallback if scale-to-zero is flaky; not the first choice for a Phase 4 learning demo.

**GitOps impact:** Remains **met** if KEDA + ScaledObject are reconciled by Argo as above.

---

## ADR-015 — Phase 5 design: Prometheus + Grafana observability

| | |
|--|--|
| **Date** | 2026-08-07 |
| **Phase** | 5 |
| **Status** | Accepted — design detailed here (not implemented yet) |
| **Depends on** | ADR-013 (GitOps), ADR-014 (KEDA / NATS monitor :8222) |

**Context:** Phases 3–4 deliver a GitOps pipeline on kind (Argo app-of-apps, Vault+ESO, NATS JetStream, Postgres, KEDA scale-to-zero). Operators still lack a first-class view of the success metrics already used in smokes and design talk: **queue depth**, **games/sec**, **failed**, **lost**, **p95 analysis latency**, with an alert when **lost > 0**. Phase 5 adds a minimal scrape + dashboard + alert path under Argo without turning kind into a full observability platform.

### Approaches considered

| Approach | Summary | Trade-offs |
|----------|---------|------------|
| **A — kube-prometheus-stack Helm child + NATS scrape + minimal Python metrics (recommended)** | One Argo Application `monitoring` installs `prometheus-community/kube-prometheus-stack` (Prometheus Operator, Prometheus, Grafana, Alertmanager, kube-state-metrics). Scrape NATS `:8222/metrics`; add a thin `prometheus_client` HTTP `/metrics` on the analyzer Deployment for pipeline counters/histograms; one Grafana dashboard + a few `PrometheusRule`s. | Heavier than bare Prometheus on kind, but matches prior Helm-under-Argo learning (Vault/ESO/KEDA). Operator CRDs unlock ServiceMonitor/PrometheusRule. Small, purposeful Python change — not a metrics rewrite. |
| **B — kube-prometheus-stack + exporters/existing only (no Python client)** | Same stack; scrape NATS + default Kubernetes metrics only. | Zero app code change. **Cannot** honestly expose games/sec, failed, lost, or p95 without log scraping or Pushgateway. Weak vs stated success metrics. |
| **C — Lightweight Prometheus + Grafana Helm (no Operator)** | Two charts (or umbrella) with annotation/`static_configs` scrape; no ServiceMonitor CRDs. | Fewer pods/CRDs; more DIY scrape config; diverges from the Operator pattern taught by kube-prometheus-stack; two child apps or a custom chart for little gain on kind. |

**Decision:** **Approach A.**

### Locked choices

| Topic | Choice |
|-------|--------|
| Stack | **`kube-prometheus-stack`** via new Argo child Application `monitoring` (official prometheus-community Helm chart; pin `targetRevision` at implement time, same style as `keda` 2.20.2) |
| Namespace | `monitoring` |
| Sync wave | **`monitoring` at wave `2`** (with/after `secrets`, before NATS/app) so Operator CRDs exist before any ServiceMonitor/PodMonitor/PrometheusRule; NATS/app stay wave `3`/`4` |
| Grafana access | **port-forward only** (no Ingress / auth IdP) — kind learning |
| Retention / size | Short Prometheus retention (e.g. **6–24h**); trim chart defaults that fight kind (avoid extra long-term storage / Thanos); keep Alertmanager enabled (needed for alert demo) |
| NATS scrape | Enable/confirm NATS HTTP monitor **:8222**; scrape **`/metrics`** on headless Service `chessforge-nats-headless.chessforge.svc:8222` (same endpoint family KEDA already uses). Prefer **ServiceMonitor** (or PodMonitor) owned by the monitoring app / values — not a second exporter pod unless `/metrics` is unavailable |
| App metrics | **Phase 5 adds minimal `prometheus_client`** on the **analyzer** only (in-process HTTP `/metrics`, e.g. port `9090`). **Not** exporter-only. **No** Pushgateway. **No** prometheus_client on the ingest Job (Job scrapes die with the pod) |
| Analyzer series (minimal) | Counters: `chessforge_games_analyzed_total`, `chessforge_games_failed_total`; histogram: `chessforge_analyze_duration_seconds` (for **p95** / games/sec via `rate()`). Optional gauge later — not required to start |
| Queue depth | From **NATS** Prometheus metrics / JetStream consumer lag series (exact metric names confirmed at implement against NATS version) — same backlog signal KEDA uses, now on a graph |
| `lost` | **Not** invent a fake lost counter on workers. Phase 5 alert **`lost > 0`** uses a **single Postgres custom query** via **postgres-exporter** (or kube-prometheus-stack postgres scrape with one query): e.g. `GREATEST(0, SUM(ingest_runs.games_enqueued) - COUNT(games))` exposed as `chessforge_lost_games`. Credentials from existing Secret `chessforge-db` / ESO — no new Vault paths unless implement proves necessary |
| Dashboard | **One** Grafana dashboard (ConfigMap + sidecar or chart `dashboardProviders`): queue depth, analyzer replicas, games/sec, failed rate, lost gauge, analyze p95. No multi-dashboard pack |
| Alerts (minimal) | (1) **`ChessforgeLostGames`** — `chessforge_lost_games > 0` for a short `for` (e.g. 2–5m) after pipeline activity; (2) optional **`ChessforgeAnalyzeFailures`** — increase in `chessforge_games_failed_total`; (3) optional **`ChessforgeQueueStuck`** — JetStream lag high while replicas at max. Ship (1) for sure; (2)–(3) only if cheap at implement |
| App YAML touch | Small: metrics port on analyzer container + ClusterIP Service (for ServiceMonitor) under `deploy/k8s/app/`; image rebuild/publish when Python metrics land |
| Docs | Design lives only in this file (`docs/DECISIONS.md`); no `docs/superpowers/specs/` |

### Goal

1. Prometheus scrapes NATS monitor + analyzer `/metrics` (+ postgres-exporter lost query) under Argo.
2. Grafana shows one pipeline dashboard covering the success metrics above.
3. Alertmanager can fire when **lost > 0** (kind: inspect Alertmanager UI / pending alerts via port-forward).
4. Observability components are desired state in Git (GitOps preserved).
5. Scope stays a learning slice — not a full SRE platform.

### GitOps layout (intended)

| Child Application | Delivers |
|-------------------|----------|
| `monitoring` (**new**) | kube-prometheus-stack Helm; values for retention/resources; ServiceMonitor(s) / PrometheusRule(s) / dashboard ConfigMap(s) — either via chart values or a second source path e.g. `deploy/k8s/monitoring/` |
| `chessforge` (existing) | Analyzer Deployment/Service gains metrics port; image tag may bump for `prometheus_client` |
| `nats` (existing) | Values tweak only if monitor/metrics port is not already exposed for scrape |

Root Application already globs `deploy/gitops/applications/` — adding `monitoring.yaml` is enough for discovery.

### Metrics flow

```text
NATS :8222/metrics ──► ServiceMonitor ──► Prometheus
Analyzer :9090/metrics (prometheus_client) ──► ServiceMonitor ──► Prometheus
Postgres (custom lost query via postgres-exporter) ──► Prometheus
                              │
                              ▼
                     Grafana dashboard (port-forward)
                     Alertmanager ← PrometheusRule (lost > 0)
```

**Why Python client (not exporter-only):** NATS and kube metrics cover queue/replicas well; they do **not** provide Stockfish analyze latency, per-game failed, or games/sec. A few counters/histograms on the long-lived analyzer match YAGNI better than Loki/log parsers or Pushgateway for Jobs.

### Success criteria

1. Argo Application `monitoring` Healthy; Prometheus and Grafana pods Ready in `monitoring`.
2. Prometheus targets include NATS monitor and analyzer metrics (and the lost SQL metric) — up/scraping.
3. After sample ingest: dashboard shows queue depth movement, games/sec or analyze rate, and p95 latency; failed/lost readable as zero on a clean run.
4. Forcing a failed/lost condition (or injecting the gauge/query) makes **`ChessforgeLostGames`** (or equivalent) fire visibly in Alertmanager.
5. Changing monitoring manifests in Git → Argo syncs (no routine imperative Helm for the stack).

### Out of scope (Phase 5)

- Chaos Mesh (Phase 6)
- Query HTTP API / report Job
- Ingress, SSO, persistent long-term metrics, Thanos, Tempo/Jaeger tracing, Loki log stack
- Pushgateway / ingest-Job metrics
- Full SLO/error-budget program; dozens of dashboards
- Production-grade Alertmanager routing (Slack/PagerDuty) — local Alertmanager UI is enough

### Rejected alternatives (this design pass)

- **Approach B** — exporters only: misses the success metrics that motivated Phase 5.
- **Approach C** — Prometheus+Grafana without Operator: lighter, but more bespoke scrape config and weaker prep for standard Kubernetes monitoring.
- **OpenTelemetry everywhere** — right long-term story, wrong bite for kind learning now.
- **Datadog / managed SaaS** — fights local kind + GitOps learning.
- **Recreating `docs/superpowers/specs/`** — this ADR is the design record.

**GitOps impact:** Remains **met** if the monitoring stack and scrape/alert config are reconciled by Argo as above.

---

## Decision index by phase

| Phase | ADRs | GitOps met? |
|-------|------|-------------|
| 0 Local CLI | 001, 002, 003 | No |
| 1 Docker + GHA + GHCR | 004 | No |
| 2 kind + NATS + Postgres + app YAML | 005–009 | No / partial (Git + kubectl/helm) |
| 3 Argo CD + Vault + ESO | 010, 012, **013** | Yes (when kind-up Phase 3 smoke passes) |
| 4 KEDA | 011, **014** | Yes (KEDA Helm + ScaledObject under Argo) |
| 5 Observability | **015** | Yes when monitoring under Argo (design accepted; not implemented yet) |
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
| 2026-08-07 | Phase 3 smoke verified on kind: Vault→ESO→Secret, ingest enqueued 5, Postgres games=5; Postgres chart 18.8.6; native kind image load. |
| 2026-08-07 | GHCR package treated as **public** while the repo is public; kind pulls without imagePullSecret. Private package + ESO dockerconfig pull secret deferred. |
| 2026-08-07 | ADR-014: Phase 4 design proposed (KEDA Helm via Argo, ScaledObject on analyzer, nats-jetstream lag, min 0 / max 4). |
| 2026-08-07 | ADR-014 implemented: Argo Application `keda` (Helm 2.20.2), ScaledObject on analyzer (`nats-jetstream`, CHESSFORGE/analyzers, min 0 / max 4), Deployment replicas owned by KEDA. |
| 2026-08-07 | Smoke scripts/docs added: `deploy/scripts/smoke-{local,docker,pipeline,keda}.sh`, cheatsheet `deploy/scripts/smoke-all.md`, README "Smoke tests" section (wraps kind-up + focused checks; no new long e2e). |
| 2026-08-07 | ADR-015: Phase 5 design proposed (kube-prometheus-stack via Argo, NATS :8222 + analyzer prometheus_client + postgres lost query, one dashboard, alert lost>0). |

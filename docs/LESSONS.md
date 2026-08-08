# Chessforge — lessons learned

**Purpose:** Capture *errors we hit while implementing* chessforge on kind/GitOps, how we diagnosed them, and what fixed them — so the next phase (or a fresh cluster) fails faster and for clearer reasons.

This file is **not** an ADR log. Design choices live in [`docs/DECISIONS.md`](DECISIONS.md). Regression checks live in the smoke scripts linked at the end.

**Language:** English only (repo convention).

---

## Incidents

| # | Symptom | Diagnosis | Fix | Lesson |
|---|---------|-----------|-----|--------|
| 1 | CI `pytest` fails with `ModuleNotFoundError: chessforge` | Running `pytest` without installing the package and without putting the repo root on `sys.path` | Set `PYTHONPATH=.` in CI / smoke scripts; add `pytest.ini` with `pythonpath = .` (`e0cee38`) | Flat source layouts need an explicit import path in CI; local venv habits do not transfer automatically |
| 2 | Helm install of NATS fails / pods CrashLoop on config | Values had `config.merge.max_payload: 8MB` — chart/config schema rejects that string form (type / format error) | Dropped the override; kept JetStream defaults in `deploy/helm/nats-values.yaml` | Chart value types are not “whatever the NATS conf file accepts”; validate with `helm upgrade` before wiring Argo |
| 3 | Analyze / ingest skips or fails on hand-written `sample.pgn` | Illegal or ambiguous SAN in a crafted game — `python-chess` cannot apply the move on a legal board | Keep sample games short and legal; run `smoke-local.sh` / analyze before treating “5 games” as the integrity bar | Domain fixtures are part of the pipeline contract; bad PGN looks like a distributed-systems failure (`lost` / low game count) |
| 4 | Phase 3 smoke stuck: Vault never seeds KV; ESO Secret missing | (a) Bash `${STATUS_JSON:-{}}` parses as default `{` plus a stray `}`, corrupting JSON for `jq`; (b) `vault status` exits 2 when sealed and aborted `kubectl exec` under `set -e` | Use `"${STATUS_JSON:-"{}"}"`; wrap status in `sh -c '… \|\| true'`; wait for unsealed before KV/auth (`9aff49c`) | Shell parameter expansion is not JSON-aware; treat sealed Vault as an expected non-zero exit |
| 5 | Postgres pods never Ready; Bitnami cannot find passwords | Chart uses `auth.existingSecret: chessforge-db`, but that Secret is created by ESO **after** Vault bootstrap — Postgres sync-wave can race ahead of a seeded Vault | Sync-wave order (Vault/ESO → secrets → postgres); `kind-up` waits for Secret `chessforge-db` before declaring the stack ready; PVC reset if password identity drifts | `existingSecret` couples Helm to bootstrap order; GitOps waves alone are not enough without an imperative wait at the bootstrap boundary |
| 6 | Argo Application for the app stays OutOfSync / Jobs re-fire oddly | Batch `Job` ingest lived under the Argo path (`deploy/k8s/app`); completed Jobs and sync/prune interact poorly for one-shot smokes | Moved ingest to `deploy/k8s/jobs/ingest-sample.yaml`; apply from `kind-up` / smoke scripts, not continuous reconciliation | Prefer Deployments (and ScaledObjects) under Argo; keep one-shot Jobs imperative next to smoke |
| 7 | Postgres Argo app unhealthy / chart pull or render failures on kind | Bitnami PostgreSQL chart pin `16.4.1` was painful on the kind bring-up path | Bumped to chart **`18.8.6`** (`e22dccd`); keep Helm/`--wait` timeouts generous in bootstrap | Pin charts, but be ready to bump when the pin blocks learning; record the working revision in Git |
| 8 | Analyzer / ingest `ImagePullBackOff` for `ghcr.io/…/chessforge:latest` | GHCR package was **private** (or amd64-only on Apple Silicon kind) | Make package **public** while the repo is public; optional `FORCE_KIND_LOAD=1` builds + `kind load`; CI multi-arch (`57777d6`, `e22dccd`) | Image pull is a secrets/platform problem separate from Vault DB secrets; kind load is a local escape hatch, not the GitOps story |
| 9 | KEDA `nats-jetstream` scaler inactive / cannot read lag | Monitoring URL pointed at ClusterIP Service (port **4222** only); JetStream JSON monitor is on **:8222** on the **headless** Service | `natsServerMonitoringEndpoint: chessforge-nats-headless…:8222` in ScaledObject (ADR-014) | Service port surfaces differ; scaler endpoints must match the chart’s monitor exposure, not the client port |
| 10 | Prometheus scrape of NATS `:8222/metrics` returns **404** | Native NATS HTTP monitor serves JSON (`/jsz`, etc.), not Prometheus text | Enable chart `promExporter` sidecar (`:7777`) + PodMonitor (ADR-015 / `f44c860`) | “Has an HTTP port” ≠ “exposes Prometheus”; verify the path before writing ServiceMonitors |
| 11 | postgres-exporter up but no `chessforge_lost_games` / TLS errors | Kind Postgres has no TLS; DSN from Vault omitted `sslmode=disable` | Default DSN includes `sslmode=disable`; exporter entrypoint appends it if missing (`96f61b6`) | Client TLS defaults differ between libraries; demo DSNs must match the actual server |
| 12 | Observability smoke fails while Grafana still rolling | Argo health `Progressing` and Prometheus label forms (`chessforge_lost_games{…}`) broke strict checks | Smoke waits for Synced + Ready pods; grep allows labeled series (`3bda586`, `f63ce2a`) | Smokes should assert *capability* (Synced, Ready, metric present), not a single transient Argo health enum |

---

## Cross-cutting themes

### Config types and chart surfaces

Helm values and NATS/Bitnami schemas are stricter than docs copy-paste. Prefer the smallest values file that enables JetStream / `existingSecret` / `promExporter`, then add knobs only after `helm template` / a live upgrade succeeds.

### Bootstrap order

GitOps owns steady state; **Vault init/unseal/seed** stays outside Argo on purpose. Anything that reads `chessforge-db` (Postgres, exporters, workers) must wait for that Secret. Password changes without PVC reset leave Postgres with the old identity.

### GitOps vs Jobs

Argo is excellent for Deployments, Helm releases, CRDs, and ScaledObjects. One-shot ingest Jobs are smoke tools: delete/apply/wait, then assert Postgres counts. Mixing them into the reconciled app path creates false drift.

### Observability assumptions

KEDA and Prometheus both care about NATS HTTP, but **different ports and formats**: `:8222` JSON for lag, `:7777` Prometheus via sidecar. Always probe the URL (`curl` from a throwaway pod) before encoding it in CRDs or dashboards.

### Secrets and image pull

Vault + ESO cover **DB credentials**. Image pull is orthogonal: public GHCR for learning, or a future `dockerconfigjson` via ESO if the package goes private. `FORCE_KIND_LOAD=1` covers Apple Silicon / pull failures without pretending it is the production path.

### Domain integrity vs platform failures

`lost=0` and `games>=5` only mean “pipeline healthy” if the sample PGN and image are good. Illegal SAN, wrong `PYTHONPATH`, or ImagePullBackOff all present as “not enough games.”

---

## Regression checks

Use these after changes to bootstrap, Helm values, secrets, or scrapes. Full cheatsheet: [`deploy/scripts/smoke-all.md`](../deploy/scripts/smoke-all.md).

| Check | Command |
|-------|---------|
| Local unit + optional Stockfish | `./deploy/scripts/smoke-local.sh` (`RUN_ANALYZE=1` for `lost=0`) |
| Docker image smoke | `./deploy/scripts/smoke-docker.sh` |
| Full kind GitOps bring-up | `./deploy/kind-up.sh` (`FORCE_KIND_LOAD=1` if needed) |
| Pipeline only (cluster up) | `./deploy/scripts/smoke-pipeline.sh` |
| KEDA scale-to-zero / scale-up | `./deploy/scripts/smoke-keda.sh` |
| Prometheus / Grafana / scrapes | `./deploy/scripts/smoke-observability.sh` |

Related design: [`docs/DECISIONS.md`](DECISIONS.md) (ADR-013…015).

# Chessforge Phase 2 — kind + NATS + Postgres (pipeline slice)

**Date:** 2026-08-07  
**Status:** approved (design)  
**Cluster:** kind  
**Slice:** C — ingest → NATS → workers → Postgres + integrity (no query API yet)  
**Packaging:** Helm for NATS/Postgres; plain YAML for app  
**Topology:** Job ingest + Deployment analyzers  

Decision log: `docs/DECISIONS.md` (ADR-005 … ADR-009).  
Parent: `docs/superpowers/specs/2026-08-07-chessforge-project-spec.md`.

## Goal

Run the Phase 0 analysis loop as a **distributed pipeline on local Kubernetes (kind)**: publish games to NATS JetStream, consume with Stockfish workers, persist to Postgres, verify `lost=0`.

## Scope

**In**

- kind cluster bootstrap docs/scripts
- Helm install of NATS (JetStream enabled) and Postgres
- Kubernetes YAML: namespace, ConfigMap (sample PGN or mount), `ingest` Job, `analyzer` Deployment
- App changes: NATS publish/consume, Postgres driver (replace SQLite for cluster path), shared schema migration strategy
- Idempotent writes under redelivery
- Stockfish `Threads=1`, sensible CPU limits, `terminationGracePeriodSeconds` ≥ analysis budget / ack wait alignment
- Integrity: ingest records `games_enqueued`; workers persist; compare / log `lost`
- Image into kind via `kind load` and/or pull from GHCR
- README section for Phase 2 bring-up

**Out**

- HTTP query API / `report` Job (follow-up slice)
- Argo CD (Phase 3)
- KEDA (Phase 4)
- Chaos Mesh (Phase 6)
- Kafka / RabbitMQ
- Kustomize overlays (deferred)
- Managed cloud Kubernetes

## Architecture

```text
                    kind cluster
┌─────────────────────────────────────────────────────────────┐
│  Helm: nats (JetStream)          Helm: postgres             │
│         ▲                                ▲                  │
│         │ publish                  persist│                  │
│  Job: ingest ──messages──► JetStream ──► Deployment:        │
│   (sample.pgn)                         analyzer × N         │
│                                        (Stockfish Threads=1)│
└─────────────────────────────────────────────────────────────┘

Success: ingest Job completes; queue drains; lost=0; Postgres row counts match.
```

## Components

| Piece | Role |
|-------|------|
| kind | Local Kubernetes |
| Helm chart: NATS | JetStream stream/consumer for game jobs |
| Helm chart: Postgres | Durable store (replaces SQLite in cluster) |
| `ingest` Job | Parse PGN → publish `{game_id, pgn}` (or equivalent) → record run → exit |
| `analyzer` Deployment | Pull messages → Stockfish → upsert game/evals → ack |
| GHCR / kind load | Supply `chessforge` image |

## Message contract (draft)

Minimal JSON (exact fields locked in implementation plan):

```json
{
  "run_id": "uuid",
  "game_id": "cf01italian",
  "pgn": "..."
}
```

- Consumer ack only after successful Postgres persist (or definitive skip).
- `ack_wait` / visibility must exceed worst-case analyze time at configured depth (start: depth 10, small sample).
- Redelivery + `ON CONFLICT DO NOTHING` (or Postgres upsert) ⇒ no duplicate games.

## App / DB notes

- Keep Phase 0 SQLite path working for local CLI.
- Cluster path: `DATABASE_URL` (Postgres) + `NATS_URL`.
- Schema: same logical tables (`games`, `move_evals`, `ingest_runs`); migrate with SQL init Job or startup migrate (choose one in plan; prefer explicit migrate Job).

## Success criteria

1. `kind` cluster up; NATS + Postgres healthy.
2. `ingest` Job publishes sample games and exits 0.
3. Analyzer pods process all messages; logs show integrity consistent with `lost=0`.
4. Re-running ingest/workers does not duplicate `game_id` rows.
5. Killing an analyzer pod mid-run still ends with full persist after redelivery (manual smoke; formal chaos = Phase 6).

## GitOps

**Not met.** Apply with Helm + `kubectl`. Manifests/values should live in Git to prepare Phase 3, but there is no reconciler yet.

## References

- `docs/DECISIONS.md`
- Phase 0/1 designs under `docs/superpowers/specs/`
- Image: `ghcr.io/luizgnz/chessforge:latest`

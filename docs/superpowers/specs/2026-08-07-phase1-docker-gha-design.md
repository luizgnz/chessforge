# Chessforge Phase 1 — Fast Docker + GitHub Actions

**Date:** 2026-08-07  
**Status:** implemented (verified with local `docker build` + `docker run`)  
**Approach:** A — `python:3.12-slim` multi-stage (not distroless)  
**CI:** build + test + push to GHCR  

Parent document: `docs/superpowers/specs/2026-08-07-chessforge-project-spec.md` (Phase 1).

## Goal

Package the Phase 0 analyzer in a Docker image that builds quickly and reproducibly, and automate in GitHub Actions: tests, build, and publish to GHCR.

## Scope

**In**

- Multi-stage `Dockerfile` on `python:3.12-slim-bookworm`
- Stockfish installed via `apt` (distro binary; do not compile from source)
- `.dockerignore` so local noise does not bust cache
- GitHub Actions workflow:
  - `pytest` in a Python job
  - `docker build` (Buildx + GHA cache)
  - push to GHCR on `main` (`:sha` and `:latest`)
  - smoke: `docker run` with sample PGN and `--max-games 1`
- `STOCKFISH_PATH` set in the image to the usual Debian path
- Update README with local build/run and CI notes
- Update parent spec: Phase 1 → in progress / done when implemented

**Out**

- Distroless
- Kubernetes, NATS, KEDA, Argo CD, Chaos Mesh
- Compiling Stockfish from source
- Registry other than GHCR
- HTTP API

## Why not distroless (now)

Distroless shrinks runtime attack surface; it does **not** speed up the build. For Phase 1 we prioritize:

1. Layer + pip cache (BuildKit)
2. Stockfish via `apt` (seconds, not minutes)
3. Easy debug (`bash` in slim if needed)

Distroless remains a later option once the worker is stable.

## Architecture

```text
┌──────────────────────────── CI (GitHub Actions) ─────────────────────────────┐
│  job: test          pytest (Python 3.12; Stockfish optional / skip engine)   │
│  job: image         docker buildx + GHA cache                                │
│                     └─ PR: build (+ smoke run, no push)                      │
│                     └─ main: build + push ghcr.io/<owner>/<repo>             │
└──────────────────────────────────────────────────────────────────────────────┘

Dockerfile (multi-stage):

  stage deps     python:3.12-slim-bookworm
                 pip install -r requirements.txt  (cache mount)

  stage runtime  python:3.12-slim-bookworm
                 apt-get install -y stockfish
                 copy site-packages + /app/chessforge + sample.pgn
                 ENV STOCKFISH_PATH=/usr/games/stockfish
                 CMD analyze sample --max-games 1
```

## Components

| Artifact | Responsibility |
|----------|----------------|
| `Dockerfile` | Worker/analyzer image |
| `.dockerignore` | Exclude `.venv`, `.git`, DBs, caches |
| `.github/workflows/ci.yml` | test + build + push GHCR |
| `README.md` | Documented `docker build` / `docker run` |

No analysis-logic changes unless smoke requires minor path/env tweaks (e.g. documenting `/usr/games/stockfish` in `engine.py` candidates — optional; `STOCKFISH_PATH` is enough).

## Dockerfile (contract)

### Stages

1. **deps** — install Python dependencies into a venv or `/install` prefix.
2. **runtime** — slim + apt `stockfish` + app code.

### Fast build (requirements)

- Order: copy `requirements.txt` → `pip install` → copy `chessforge/` and `data/sample.pgn`.
- BuildKit cache mount for pip: `--mount=type=cache,target=/root/.cache/pip`.
- No unnecessary `apt-get` in the deps stage; in runtime: `apt-get update && apt-get install -y --no-install-recommends stockfish && rm -rf /var/lib/apt/lists/*`.
- Single target architecture in CI by default: `linux/amd64` (avoid qemu multi-arch in this phase; can expand later).

### Runtime env / CMD

```dockerfile
ENV STOCKFISH_PATH=/usr/games/stockfish
WORKDIR /app
CMD ["python", "-m", "chessforge.analyze", \
     "--source", "/app/data/sample.pgn", \
     "--depth", "10", \
     "--max-games", "1", \
     "--db", "/tmp/chessforge.db"]
```

Default DB under `/tmp` so the container needs no volume for smoke.

### `.dockerignore` (minimum)

```text
.venv/
.git/
.github/
.pytest_cache/
__pycache__/
data/*.db
docs/
*.md
.DS_Store
```

(README may stay out of the image; docs live in the repo.)

## GitHub Actions

### Triggers

- `pull_request` → test + build (+ smoke), **no push**
- `push` to `main` → test + build + smoke + **push** GHCR

### Jobs

| Job | Key steps |
|-----|-----------|
| `test` | checkout, setup-python 3.12, pip cache, `pip install -r requirements.txt pytest`, `pytest` |
| `image` | checkout, setup-buildx, login GHCR (main only), build-push-action, smoke `docker run` |

### Image on GHCR

- Name: `ghcr.io/<github.repository>` (lowercase; normalize if needed)
- Tags on `main`: `<git sha>` and `latest`
- Workflow permissions: `contents: read`, `packages: write`

### Cache

- `cache-from` / `cache-to`: `type=gha,mode=max` on build-push-action

### Smoke

After build (load locally on the runner, or pull the just-pushed image on main):

```bash
docker run --rm "$IMAGE" \
  python -m chessforge.analyze \
    --source /app/data/sample.pgn \
    --depth 10 \
    --max-games 1 \
    --db /tmp/chessforge.db
```

Success = exit 0 and output with `lost=0` (or at least process OK). On runners without Stockfish in the `test` job, container smoke is the real engine check.

**Note on `test`:** current unit tests (`classify`, `db`) do not need Stockfish. Do not block the `test` job on installing Stockfish on the runner unless integration tests outside Docker are added.

## Success criteria

1. `docker build -t chessforge:local .` finishes on a developer machine without compiling Stockfish.
2. `docker run --rm chessforge:local` analyzes ≥1 sample game with no error.
3. On PR, CI runs `pytest` + build (no publish).
4. On push to `main`, the image lands on GHCR with `sha` and `latest` tags.
5. Successive rebuilds hit cache (deps are not reinstalled if `requirements.txt` is unchanged).

## Error handling

- If `apt` cannot find `stockfish` on the chosen suite: pin bookworm base and document the `stockfish` package; fail the build (do not silence).
- If GHCR login fails: only affects push on `main`; keep build/test visible as separate jobs when practical.
- Smoke failure fails the workflow (do not publish a misleading `:latest`: prefer push only after smoke, or push by digest and tag `latest` after smoke).

**Preferred order on `main`:** build (load or push `sha` tag) → smoke → tag/push `latest` (or a single push after smoke with local load). Concrete plan: smoke before retagging `latest` if the action allows two steps.

## Dependencies

- Docker Buildx / BuildKit
- GitHub Actions (`actions/checkout`, `actions/setup-python`, `docker/setup-buildx-action`, `docker/login-action`, `docker/build-push-action`)
- GHCR enabled for the repo (`GITHUB_TOKEN` packages permissions)
- Inherits Phase 0: Python 3.12, `chess`, `zstandard`, Stockfish

## GitOps

**Does not meet** the GitOps lifecycle. This phase publishes an image; there is no Argo or cluster reconciliation. (GitOps = Phase 3 in the parent spec.)

## References

- Project spec: `docs/superpowers/specs/2026-08-07-chessforge-project-spec.md`
- Local design: `docs/superpowers/specs/2026-08-07-local-cli-draft-design.md`

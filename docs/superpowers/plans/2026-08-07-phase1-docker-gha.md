# Phase 1 Docker + GitHub Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a fast multi-stage Docker image for the Python analyzer and a GitHub Actions workflow that tests, builds, smokes, and pushes to GHCR on `main`.

**Architecture:** Multi-stage `python:3.12-slim-bookworm` image installs pip deps in a builder stage and Stockfish via `apt` in runtime. CI runs unit tests without Stockfish; the image job buildx-builds with GHA cache, smokes with `docker run`, and on `main` pushes `:sha` then `:latest` only after smoke passes.

**Tech Stack:** Docker BuildKit, Python 3.12, Stockfish (Debian apt), GitHub Actions, GHCR.

## Global Constraints

- Base image: `python:3.12-slim-bookworm` only (no distroless).
- Stockfish: `apt-get install` package `stockfish`; never compile from source.
- Platform in CI: `linux/amd64` only.
- Language: Python (no Go/Rust rewrite).
- GHCR image name: `ghcr.io/<owner>/<repo>` lowercased; tags `sha` + `latest` on `main`.
- PR workflows must not push images.
- Smoke before tagging `:latest` on `main`.
- GitOps remains unmet (no Argo).

## File structure

| File | Responsibility |
|------|----------------|
| `Dockerfile` | Multi-stage image: deps + runtime with Stockfish |
| `.dockerignore` | Keep build context small / cache-friendly |
| `.github/workflows/ci.yml` | `test` + `image` jobs |
| `chessforge/engine.py` | Add Debian Stockfish path to candidates |
| `README.md` | Document docker build/run + CI/GHCR |
| `docs/superpowers/specs/2026-08-07-chessforge-project-spec.md` | Mark Fase 1 done when verified |

---

### Task 1: Docker image (Dockerfile + .dockerignore)

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Modify: `chessforge/engine.py` (add `/usr/games/stockfish` to `CANDIDATE_PATHS`)

**Interfaces:**
- Consumes: `requirements.txt`, `chessforge/`, `data/sample.pgn`
- Produces: image with `STOCKFISH_PATH=/usr/games/stockfish`, default CMD analyzing 1 sample game to `/tmp/chessforge.db`

- [x] **Step 1: Create `.dockerignore`**

```text
.venv/
.git/
.github/
.pytest_cache/
__pycache__/
**/__pycache__/
data/*.db
docs/
*.md
.DS_Store
tests/
```

- [ ] **Step 2: Create `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7

FROM python:3.12-slim-bookworm AS deps
WORKDIR /build
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install -r requirements.txt

FROM python:3.12-slim-bookworm AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends stockfish \
    && rm -rf /var/lib/apt/lists/*
COPY --from=deps /install /usr/local
WORKDIR /app
COPY chessforge/ ./chessforge/
COPY data/sample.pgn ./data/sample.pgn
ENV STOCKFISH_PATH=/usr/games/stockfish \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
CMD ["python", "-m", "chessforge.analyze", \
     "--source", "/app/data/sample.pgn", \
     "--depth", "10", \
     "--max-games", "1", \
     "--db", "/tmp/chessforge.db"]
```

- [ ] **Step 3: Add Debian path in `engine.py`**

Insert `"/usr/games/stockfish"` into `CANDIDATE_PATHS` after env override (keep Homebrew paths for local Mac).

- [ ] **Step 4: Build and smoke locally**

Run:

```bash
docker build -t chessforge:local .
docker run --rm chessforge:local
```

Expected: exit 0, log lines with `RUN …`, `game …`, `DONE … lost=0`.

- [ ] **Step 5: Commit** (only if user asked to commit; otherwise skip)

---

### Task 2: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Dockerfile from Task 1; `tests/` + `requirements.txt`
- Produces: workflow that on PR builds+smokes without push; on `main` pushes `sha` after smoke then `latest`

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: ci

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

env:
  REGISTRY: ghcr.io

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
      - run: pip install -r requirements.txt pytest
      - run: pytest -q

  image:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4

      - name: Image name (lowercase)
        run: echo "IMAGE_NAME=${GITHUB_REPOSITORY,,}" >> "$GITHUB_ENV"

      - uses: docker/setup-buildx-action@v3

      - name: Login to GHCR
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build (and load for smoke)
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          load: true
          tags: chessforge:ci
          cache-from: type=gha
          cache-to: type=gha,mode=max
          platforms: linux/amd64

      - name: Smoke
        run: |
          docker run --rm chessforge:ci \
            python -m chessforge.analyze \
              --source /app/data/sample.pgn \
              --depth 10 \
              --max-games 1 \
              --db /tmp/chessforge.db

      - name: Push sha + latest (main only)
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
          platforms: linux/amd64
```

Note: second build-push on `main` should hit cache after smoke; smoke gates `:latest`.

- [ ] **Step 2: Validate workflow YAML locally if possible** (`actionlint` optional; otherwise visual review)

- [ ] **Step 3: Commit** (only if user asked)

---

### Task 3: Docs + parent spec status

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-07-chessforge-project-spec.md`

- [ ] **Step 1: README — add Docker + CI section**

Document:

```bash
docker build -t chessforge:local .
docker run --rm chessforge:local
```

Note: CI pushes `ghcr.io/<owner>/<repo>:latest` on `main`; GitOps still not in use.

- [ ] **Step 2: Parent spec — Fase 1 status**

Set Fase 1 estado to `hecho` after local docker smoke passes; keep GitOps **No**.

- [ ] **Step 3: Run unit tests**

```bash
pytest -q
```

Expected: PASS

- [ ] **Step 4: Final local docker smoke** (reconfirm)

---

## Spec coverage check

| Spec requirement | Task |
|------------------|------|
| Multi-stage slim-bookworm | Task 1 |
| apt stockfish, pip cache mount | Task 1 |
| `.dockerignore` | Task 1 |
| STOCKFISH_PATH + CMD sample | Task 1 |
| pytest job | Task 2 |
| buildx + GHA cache | Task 2 |
| PR no push; main push sha+latest | Task 2 |
| smoke before latest | Task 2 (smoke step before push step) |
| README + parent spec | Task 3 |
| No distroless / no K8s | respected |

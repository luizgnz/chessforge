# Chessforge Fase 1 — Docker rápido + GitHub Actions

**Fecha:** 2026-08-07  
**Estado:** implemented (verificado con `docker build` + `docker run` local)  
**Enfoque:** A — `python:3.12-slim` multi-stage (no distroless)  
**CI:** build + test + push a GHCR  

Documento padre: `docs/superpowers/specs/2026-08-07-chessforge-project-spec.md` (Fase 1).

## Goal

Empaquetar el analyzer de la Fase 0 en una imagen Docker que se construya rápido y sea reproducible, y automatizar en GitHub Actions: tests, build y publicación en GHCR.

## Scope

**In**

- `Dockerfile` multi-stage sobre `python:3.12-slim-bookworm`
- Stockfish instalado por `apt` (binario del distro; no compilar desde source)
- `.dockerignore` para no invalidar cache con ruido local
- Workflow GitHub Actions:
  - `pytest` en job Python
  - `docker build` (Buildx + cache GHA)
  - push a GHCR en `main` (`:sha` y `:latest`)
  - smoke: `docker run` con sample PGN y `--max-games 1`
- `STOCKFISH_PATH` fijado en la imagen al path Debian habitual
- Actualizar README con build/run local y notas de CI
- Actualizar el spec padre: Fase 1 → en progreso / hecho cuando se implemente

**Out**

- Distroless
- Kubernetes, NATS, KEDA, Argo CD, Chaos Mesh
- Compilar Stockfish desde source
- Registry distinto de GHCR
- HTTP API

## Por qué no distroless (ahora)

Distroless reduce tamaño/superficie de ataque en runtime; **no** acelera el build. Para Fase 1 priorizamos:

1. Cache de capas + pip (BuildKit)
2. Stockfish vía `apt` (segundos, no minutos)
3. Debug fácil (`bash` en slim si hace falta)

Distroless queda como opción posterior cuando el worker esté estable.

## Architecture

```text
┌──────────────────────────── CI (GitHub Actions) ─────────────────────────────┐
│  job: test          pytest (Python 3.12 + Stockfish en runner o skip engine) │
│  job: image         docker buildx + cache GHA                                │
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

| Artefacto | Responsabilidad |
|-----------|-----------------|
| `Dockerfile` | Imagen del worker/analyzer |
| `.dockerignore` | Excluir `.venv`, `.git`, DBs, caches |
| `.github/workflows/ci.yml` | test + build + push GHCR |
| `README.md` | `docker build` / `docker run` documentados |

Sin cambios de lógica de análisis salvo ajustes menores de path/env si el smoke lo exige (p. ej. documentar `/usr/games/stockfish` en `engine.py` candidates — opcional; `STOCKFISH_PATH` basta).

## Dockerfile (contrato)

### Stages

1. **deps** — instalar dependencias Python en un venv o `/install` prefix.
2. **runtime** — slim + `stockfish` del apt + código de app.

### Build rápido (requisitos)

- Orden: copiar `requirements.txt` → `pip install` → copiar `chessforge/` y `data/sample.pgn`.
- BuildKit cache mount para pip: `--mount=type=cache,target=/root/.cache/pip`.
- No `apt-get` innecesario en el stage de deps; en runtime: `apt-get update && apt-get install -y --no-install-recommends stockfish && rm -rf /var/lib/apt/lists/*`.
- Una sola arquitectura objetivo en CI por defecto: `linux/amd64` (evitar qemu multi-arch en esta fase; se puede ampliar después).

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

DB por defecto en `/tmp` para que el contenedor no necesite volumen en el smoke.

### `.dockerignore` (mínimo)

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

(README puede quedar fuera de la imagen; la doc vive en el repo.)

## GitHub Actions

### Triggers

- `pull_request` → test + build (+ smoke), **sin push**
- `push` a `main` → test + build + smoke + **push** GHCR

### Jobs

| Job | Pasos clave |
|-----|-------------|
| `test` | checkout, setup-python 3.12, pip cache, `pip install -r requirements.txt pytest`, `pytest` |
| `image` | checkout, setup-buildx, login GHCR (solo main), build-push-action, smoke `docker run` |

### Imagen en GHCR

- Nombre: `ghcr.io/<github.repository>` (minúsculas; normalizar si hace falta)
- Tags en `main`: `<git sha>` y `latest`
- Permisos del workflow: `contents: read`, `packages: write`

### Cache

- `cache-from` / `cache-to`: `type=gha,mode=max` en build-push-action

### Smoke

Tras build (y load local en el runner, o pull de la imagen recién pusheada en main):

```bash
docker run --rm "$IMAGE" \
  python -m chessforge.analyze \
    --source /app/data/sample.pgn \
    --depth 10 \
    --max-games 1 \
    --db /tmp/chessforge.db
```

Éxito = exit 0 y salida con `lost=0` (o al menos proceso OK). En runners sin Stockfish en el job `test`, el smoke del contenedor es la verificación real del motor.

**Nota sobre `test`:** los tests unitarios actuales (`classify`, `db`) no requieren Stockfish. No bloquear el job `test` instalando Stockfish en el runner salvo que se añadan tests de integración fuera de Docker.

## Success criteria

1. `docker build -t chessforge:local .` completa en máquina de desarrollo sin compilar Stockfish.
2. `docker run --rm chessforge:local` analiza ≥1 partida del sample sin error.
3. En PR, CI corre `pytest` + build (sin publicar).
4. En push a `main`, la imagen queda en GHCR con tags `sha` y `latest`.
5. Rebuilds sucesivos aprovechan cache (deps no se reinstalan si `requirements.txt` no cambia).

## Error handling

- Si `apt` no encuentra `stockfish` en la suite elegida: fijar imagen base bookworm y paquete `stockfish` documentado; fallar el build (no silenciar).
- Si GHCR login falla: solo afecta push en `main`; build/test deben seguir siendo visibles como jobs separados cuando sea práctico.
- Smoke failure falla el workflow (no publicar `:latest` engañoso: preferir push solo tras smoke, o push por digest y tag `latest` después del smoke).

**Orden preferido en `main`:** build (load o push a tag `sha`) → smoke → tag/push `latest` (o un solo push tras smoke con build local load). Implementación concreta en el plan: smoke antes de retaguear `latest` si el action lo permite con dos pasos.

## Dependencies

- Docker Buildx / BuildKit
- GitHub Actions (`actions/checkout`, `actions/setup-python`, `docker/setup-buildx-action`, `docker/login-action`, `docker/build-push-action`)
- GHCR habilitado para el repo (permisos de packages del `GITHUB_TOKEN`)
- Hereda Fase 0: Python 3.12, `chess`, `zstandard`, Stockfish

## GitOps

**No cumple** el ciclo GitOps. Esta fase publica una imagen; no hay Argo ni reconciliación de cluster. (GitOps = Fase 3 del spec padre.)

## Referencias

- Spec proyecto: `docs/superpowers/specs/2026-08-07-chessforge-project-spec.md`
- Diseño local: `docs/superpowers/specs/2026-08-07-local-cli-draft-design.md`

# chessforge (local draft)

Borrador sin Kubernetes: analiza partidas PGN con Stockfish, guarda resultados en SQLite y consulta blunders por apertura.

## Requisitos

- Python 3.12+
- Stockfish (`brew install stockfish`) — solo para ejecución local sin Docker
- Docker (opcional) — imagen con Stockfish incluido

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Uso local

```bash
# Analiza el sample (depth 10, 1 hilo de Stockfish)
python -m chessforge.analyze --source data/sample.pgn --depth 10 --max-games 5

# Reporte por apertura (ECO)
python -m chessforge.report --eco C50
```

Al terminar, `analyze` imprime un resumen de integridad:

```text
DONE  RUN …  enqueued=5  analyzed=5  failed=0  lost=0  …
```

## Docker (Fase 1)

Imagen multi-stage `python:3.12-slim-bookworm` + Stockfish vía `apt` (sin compilar).

```bash
docker build -t chessforge:local .
docker run --rm chessforge:local
```

Por defecto analiza 1 partida del sample y escribe la DB en `/tmp/chessforge.db`.

## CI / GHCR

GitHub Actions (`.github/workflows/ci.yml`):

- En PR y `main`: `pytest` + `docker build` + smoke (`docker run`, 1 partida).
- Solo en push a `main`: publica `ghcr.io/<owner>/<repo>:<sha>` y `:latest` **después** del smoke.

Esto **no** es GitOps (falta Argo CD / reconciliación de cluster).

## Qué demuestra

1. Análisis CPU-bound real con profundidad fija (reproducible).
2. Persistencia idempotente (`ON CONFLICT DO NOTHING`).
3. Conteo verificable (`enqueued` vs analizadas).
4. Consulta del tipo “blunders por apertura / Elo”.
5. Imagen reproducible + CI que publica a GHCR.

Lo que viene después: NATS, K8s, KEDA, observabilidad, Chaos Mesh, GitOps con **Argo CD**.

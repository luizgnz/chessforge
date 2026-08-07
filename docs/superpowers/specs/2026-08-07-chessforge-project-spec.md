# Chessforge — especificaciones del proyecto

**Fecha:** 2026-08-07  
**Estado del documento:** borrador vivo (la Fase 0 está implementada)  
**GitOps preferido:** Argo CD (no Flux)

## 1. Visión

Chessforge analiza partidas de ajedrez en masa con Stockfish para aprender sistemas distribuidos y chaos engineering sobre Kubernetes.

**Producto (qué hace):**

1. Ingiere partidas PGN.
2. Evalúa cada jugada con Stockfish (carga CPU-bound, reproducible).
3. Persiste métricas (ACPL, blunders, primera jugada-blunder, etc.).
4. Expone consultas/reportes (p. ej. blunders por apertura ECO y banda Elo).
5. Verifica integridad: `enqueued` vs `analyzed` vs `lost`.

**Plataforma (para qué sirve el stack):**

- Colas, autoscaling por eventos, GitOps y experimentos de caos con un criterio de éxito medible (`lost=0` tras turbulencia).

## 2. Ciclo de vida GitOps (definición de “cumplido”)

GitOps se considera **cumplido** solo si se dan **todas** estas condiciones:

| # | Condición | Descripción |
|---|-----------|-------------|
| G1 | Fuente de verdad en Git | Manifiestos / Helm / Kustomize del cluster viven en el repo (o repo GitOps dedicado). |
| G2 | Cambios vía Git | El cluster no se “arregla” a mano con `kubectl apply` como flujo normal; se cambia Git. |
| G3 | Agente de reconciliación | Argo CD observa Git y aplica el estado deseado al cluster. |
| G4 | Drift detection | Si alguien muda el cluster fuera de Git, Argo lo detecta (y preferiblemente lo reconcilia). |
| G5 | App + infra declarativas | Servicios chessforge (ingest, workers, API) y dependencias (NATS, DB, KEDA, etc.) están declarados y versionados. |

**Nota:** Tener manifiestos en Git pero aplicarlos solo con `kubectl` **no** es GitOps completo (faltan G3–G4). Tener solo código de aplicación en Git **tampoco** (faltan G1–G5 del despliegue).

### Estado global hoy

| Pregunta | Respuesta |
|----------|-----------|
| ¿Se cumple el ciclo de vida GitOps ahora? | **No** |
| ¿Qué lo desbloquea? | Fase 3 (Argo CD reconciliando manifiestos del cluster) |
| Herramienta elegida | **Argo CD** |

## 3. Fases

Leyenda de estado: `hecho` · `pendiente` · `parcial`

### Fase 0 — Borrador local (sin Kubernetes)

| Campo | Valor |
|-------|--------|
| **Estado** | `hecho` |
| **Objetivo** | Probar el loop de producto sin cluster |
| **Entrada** | PGN (`data/sample.pgn`) |
| **Salida** | SQLite + CLI `report` |
| **GitOps** | **No cumple** (no hay cluster ni Argo; solo código en Git) |

**Tecnologías**

| Tecnología | Rol |
|------------|-----|
| Python 3.12+ | App / CLIs |
| `python-chess` | Parse PGN + UCI |
| Stockfish | Motor de análisis (`Threads=1`, depth fija) |
| SQLite | Persistencia local |
| pytest | Tests unitarios |

**Entregables**

- Paquete `chessforge/` (`analyze`, `report`, `db`, `engine`, `analyze_game`)
- Spec/plan locales en `docs/superpowers/`
- Criterio de integridad: `lost=0` en un run

**Fuera de alcance de esta fase:** K8s, NATS, KEDA, Postgres, Argo, Chaos Mesh, HTTP API.

---

### Fase 1 — Contenedor y contrato de worker

| Campo | Valor |
|-------|--------|
| **Estado** | `hecho` (Docker + GHA; ver spec dedicado) |
| **Spec** | `docs/superpowers/specs/2026-08-07-phase1-docker-gha-design.md` |
| **Objetivo** | Empaquetar el analyzer como imagen reproducible; mismo contrato de análisis que en local |
| **GitOps** | **No cumple** (imagen/CI sí; aún no hay reconciliación de cluster) |

**Tecnologías**

| Tecnología | Rol |
|------------|-----|
| Docker (slim-bookworm multi-stage) | Imagen del worker (Stockfish apt + app) |
| Python (mismo código Fase 0) | Lógica de análisis |
| GitHub Actions + GHCR | pytest, build, smoke, push `:sha` / `:latest` en `main` |

**Entregables**

- `Dockerfile` + `.dockerignore` + `.github/workflows/ci.yml`
- `STOCKFISH_PATH=/usr/games/stockfish` en imagen; CMD smoke con `--max-games 1`
- Smoke local: `docker build -t chessforge:local . && docker run --rm chessforge:local`

---

### Fase 2 — Kubernetes mínimo + cola + persistencia

| Campo | Valor |
|-------|--------|
| **Estado** | `pendiente` |
| **Objetivo** | Pipeline distribuido: ingest → cola → workers → DB; API/consulta básica |
| **GitOps** | **No cumple** si el deploy es manual con `kubectl`; **parcial** si los manifiestos ya viven en Git pero aún no hay Argo |

**Tecnologías**

| Tecnología | Rol |
|------------|-----|
| Kubernetes | Orquestación |
| NATS JetStream | Cola / redelivery (`ack_wait` alineado con duración del análisis) |
| Postgres | Reemplazo de SQLite en cluster |
| Deployments / Jobs | `ingest`, `analyzer` workers, servicio de consulta |
| Manifiestos (YAML / Kustomize) | Estado deseado en repo |

**Entregables**

- Ingest publica juegos; workers consumen y persisten
- Idempotencia (`ON CONFLICT DO NOTHING` o equivalente) ante redelivery
- Métrica de integridad por run (`enqueued` / `analyzed` / `lost`)
- `terminationGracePeriodSeconds` y límites de CPU pensados (evitar throttle silencioso; Stockfish 1 hilo)

---

### Fase 3 — GitOps con Argo CD

| Campo | Valor |
|-------|--------|
| **Estado** | `pendiente` |
| **Objetivo** | Git como única fuente de verdad del cluster; Argo reconcilia |
| **GitOps** | **Sí cumple** (G1–G5), para el perímetro que Argo gestione |

**Tecnologías**

| Tecnología | Rol |
|------------|-----|
| Git | Fuente de verdad |
| Argo CD | Pull/reconcile del estado deseado |
| Kustomize o Helm | Empaquetado declarativo (elegir uno y mantenerlo) |

**Entregables**

- Application(s) Argo apuntando al repo/path de manifiestos
- Flujo: PR → merge → sync (auto o manual) → cluster
- Drift visible en UI/CLI de Argo
- Documentar: “prohibido” el `kubectl apply` rutinario salvo emergencias (y luego commit del fix)

**Criterio de aceptación GitOps**

- Cambiar réplicas o imagen solo vía Git y ver el cambio reflejado por Argo sin apply manual.
- Alterar un Deployment a mano y ver OutOfSync (y restore si auto-sync está on).

---

### Fase 4 — Autoscaling por eventos (KEDA)

| Campo | Valor |
|-------|--------|
| **Estado** | `pendiente` |
| **Objetivo** | Escalar workers según profundidad de la cola NATS, no solo CPU |
| **GitOps** | **Cumple si** los `ScaledObject`/CRDs de KEDA están en Git y Argo los aplica (hereda Fase 3) |

**Tecnologías**

| Tecnología | Rol |
|------------|-----|
| KEDA | Autoscaling event-driven |
| NATS scaler (KEDA) | Escala `analyzer` según backlog JetStream |
| Argo CD | Sigue siendo el aplicador |

**Entregables**

- Subir carga → más pods; vaciar cola → scale to zero o mínimo
- Límites de CPU/memoria coherentes con `Threads=1` por proceso Stockfish

---

### Fase 5 — Observabilidad

| Campo | Valor |
|-------|--------|
| **Estado** | `pendiente` |
| **Objetivo** | Ver latencia de análisis, errores, profundidad de cola e integridad de runs |
| **GitOps** | **Cumple si** stack de métricas/dashboards está declarado en Git + Argo |

**Tecnologías (propuesta)**

| Tecnología | Rol |
|------------|-----|
| Prometheus | Métricas |
| Grafana | Dashboards |
| Logs estructurados (stdout → stack del cluster) | Trazabilidad por `run_id` / `game_id` |

**Entregables**

- Dashboard: queue depth, games/sec, failed, `lost`, duración p95 por partida
- Alertas mínimas: `lost > 0` en run “completo”; cola creciendo sin consumers

---

### Fase 6 — Chaos engineering

| Campo | Valor |
|-------|--------|
| **Estado** | `pendiente` |
| **Objetivo** | Probar resiliencia con criterio de éxito verificable |
| **GitOps** | **Cumple si** experimentos/CRDs viven en Git (o repo de experimentos) y el runtime del cluster sigue bajo Argo |

**Tecnologías (propuesta)**

| Tecnología | Rol |
|------------|-----|
| Chaos Mesh (u Litmus) | Fallos inyectados (kill pod, network delay, etc.) |
| NATS redelivery + idempotencia | Recuperación de mensajes |
| Métrica `lost` | Criterio de éxito/falla del experimento |

**Experimentos ejemplo**

1. Matar pods `analyzer` a mitad de run → redelivery → `lost=0`, sin duplicados.
2. Delay de red hacia Postgres/NATS → timeouts controlados, no corrupción.
3. Eviction masiva durante scale-up KEDA → integridad del run se mantiene.

**Criterio de éxito del caos:** tras el experimento, el run reporta `lost=0` y no hay filas duplicadas por `game_id`.

---

## 4. Mapa fase → tecnologías → GitOps

| Fase | Tecnologías principales | ¿GitOps cumplido? |
|------|-------------------------|-------------------|
| 0 Local CLI | Python, Stockfish, SQLite | **No** |
| 1 Contenedor | Docker, CI, Stockfish en imagen | **No** |
| 2 K8s + NATS + Postgres | Kubernetes, NATS JetStream, Postgres | **No** (o parcial: manifiestos en Git sin Argo) |
| 3 Argo CD | Git + Argo CD (+ Kustomize/Helm) | **Sí** (ciclo de vida GitOps activo) |
| 4 KEDA | KEDA + NATS scaler | **Sí** (si está bajo Argo) |
| 5 Observabilidad | Prometheus, Grafana | **Sí** (si está bajo Argo) |
| 6 Chaos | Chaos Mesh + métrica `lost` | **Sí** (plataforma bajo Argo; caos medible) |

## 5. Decisiones ya tomadas

| Decisión | Elección |
|----------|----------|
| Motor de ajedrez | Stockfish |
| GitOps tool | Argo CD (no Flux) |
| Cola (fase cluster) | NATS JetStream |
| Autoscaling | KEDA (por cola, no solo CPU) |
| Borrador previo al cluster | CLI Python + SQLite (Fase 0) |
| Profundidad default del borrador | 10 |
| Hilos Stockfish | 1 (evitar oversubscribe en contenedores) |

## 6. Fuera de alcance (por ahora)

- Motor distinto de Stockfish
- UI web rica / producto comercial
- Multi-cluster / multi-región
- Entrenamiento de modelos de ML sobre las evals

## 7. Criterios de éxito globales

1. **Producto:** se pueden analizar partidas y consultar blunders por ECO/Elo.
2. **Integridad:** runs con `lost=0` en operación normal.
3. **GitOps:** a partir de Fase 3, cambios de despliegue solo vía Git + Argo.
4. **Caos:** al menos un experimento documentado donde matar workers no produce `lost > 0` ni duplicados.

## 8. Referencias internas

- Diseño Fase 0: `docs/superpowers/specs/2026-08-07-local-cli-draft-design.md`
- Plan Fase 0: `docs/superpowers/plans/2026-08-07-local-cli-draft.md`
- README operativo local: `README.md`

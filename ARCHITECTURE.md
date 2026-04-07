# Arquitectura del Dispatcher

## Diagrama General

```
                          ┌─────────────────────────────┐
                          │      tmux session "0"        │
                          │                              │
  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐
  │ Window 0  │  │ Window 1  │  │ Window 2  │  │ Window 3  │  │ Window 4  │
  │           │  │ Worker A  │  │ Worker B  │  │ Coordinador│  │ Worker C  │
  │ (libre)   │  │ Claude ⚡ │  │ Claude ⚡ │  │ Claude +  │  │ Claude ⚡ │
  │           │  │           │  │           │  │ dispatcher│  │           │
  └───────────┘  └───────────┘  └───────────┘  └─────┬─────┘  └───────────┘
                       ▲              ▲               │              ▲
                       │              │               │              │
                       └──────────────┼───────────────┼──────────────┘
                                      │               │
                              tmux send-keys      dispatcher_v2.sh
                                                      │
                                    ┌─────────────────┼─────────────────┐
                                    ▼                 ▼                  ▼
                              tasks.txt         state_v2.txt      dispatcher_v2.log
                              (cola FIFO)       (estado persist.)  (bitácora)
```

## Flujo de Datos

```
tasks.txt ──────────────────────┐
(ID|TIPO|NOMBRE|RUTA|INSTRUCCION)│
                                 ▼
                        ┌──────────────────┐
                        │  dispatcher_v2.sh │
                        │   (main_loop)     │
                        └────────┬─────────┘
                                 │
                    ┌────────────┼────────────┐
                    ▼            ▼             ▼
            ┌──────────┐ ┌──────────┐  ┌──────────┐
            │ Worker 1 │ │ Worker 2 │  │ Worker N │
            │ (tmux W1)│ │ (tmux W2)│  │ (tmux WN)│
            └────┬─────┘ └────┬─────┘  └────┬─────┘
                 │             │              │
                 ▼             ▼              ▼
            output_1.docx output_2.docx  output_N.docx
                 │             │              │
                 └─────────────┼──────────────┘
                               ▼
                     dispatcher detecta .docx
                     → marca completada
                     → asigna siguiente tarea
```

## Ciclo del Main Loop

```
┌─────────────────────────────────────────────────────────────┐
│                      MAIN LOOP (cada 60s)                    │
│                                                              │
│  Para cada worker:                                           │
│                                                              │
│  ┌─ ¿Tiene tarea asignada? ───────────────────────┐         │
│  │  SÍ                                            NO        │
│  ▼                                                 ▼         │
│  ¿Existe .docx? ──── SÍ ──→ COMPLETADA           ¿Idle?    │
│  │                          → liberar worker       │         │
│  NO                         → next task            │         │
│  │                                                 │         │
│  ¿En cooldown? ─── SÍ ──→ ESPERAR                SÍ ──→    │
│  │                                            ASIGNAR TAREA  │
│  NO                                               │         │
│  │                                                NO ──→    │
│  ¿Idle? ─── NO ──→ TRABAJANDO (ok)            OCUPADA (ok)  │
│  │                                                           │
│  SÍ + tiempo > MIN_WORK_TIME                                │
│  │                                                           │
│  → POSIBLE FALLO → limpiar → liberar                        │
│                                                              │
│  Log status → sleep INTERVAL → repetir                       │
└─────────────────────────────────────────────────────────────┘
```

## Componentes en Detalle

### tasks.txt — Cola de Tareas

```
# Formato: ID|TIPO|NOMBRE|RUTA_DOCX|INSTRUCCION
1|estado|Jalisco|/ruta/a/output.docx|Instrucción completa para Claude...
2|estado|Nuevo León|/ruta/a/output.docx|Instrucción completa para Claude...
13|consolidado|Nacional|/ruta/a/output.docx|TAREA FINAL - Solo ejecutar cuando 1-6 estén completas...
```

- Líneas con `#` son comentarios
- RUTA_DOCX se usa para detección de completación (file exists check)
- INSTRUCCION debe ser autocontenida — toda la info que Claude necesita
- Dependencias: tarea 13 espera a 1-6 (hardcoded, no genérico)

### state_v2.txt — Estado Persistente

```
next_task=8
completed=3,1,2,7,
window_1_task=10
window_1_sent_at=1743933600
window_2_task=0
window_2_sent_at=0
window_4_task=11
window_4_sent_at=1743933700
window_5_task=0
window_5_sent_at=0
```

- Sobrevive reinicios del dispatcher
- `next_task`: siguiente ID a asignar
- `completed`: IDs completados (comma-separated)
- `window_N_task`: 0 = libre, >0 = tarea asignada
- `window_N_sent_at`: epoch de cuándo se envió

### dispatcher_v2.sh — Script Principal

| Función | Qué hace |
|---------|----------|
| `init_state()` | Crea o carga state_v2.txt |
| `get_state(key)` | Lee valor del state |
| `set_state(key, val)` | Escribe valor al state |
| `get_task_instruction(id)` | Extrae instrucción de tasks.txt |
| `get_task_docx(id)` | Extrae ruta .docx de tasks.txt |
| `is_session_idle(window)` | Captura tmux pane, busca `❯` vacío |
| `is_task_done(id)` | Verifica si el .docx existe |
| `send_task(window, id)` | Envía instrucción vía tmux send-keys |
| `setup_workers()` | Identifica/crea ventanas tmux con Claude |
| `main_loop()` | Loop principal de monitoreo |

### Detección de Estado del Worker

```
IDLE:
  - Última línea tiene ❯
  - Última línea es solo ❯ (nada después)
  - No hay "Pasted text" en buffer
  - No hay keywords de actividad en últimas 3 líneas:
    Cooked, Brewed, Whirring, Cogitated, Running, Writing,
    Reading, Thinking, Web Search, Bash, agent, tokens

COMPLETADA:
  - El archivo .docx especificado en tasks.txt EXISTE en disco
  - Es la detección más confiable (file exists > screen parsing)

FALLO PROBABLE:
  - Worker está idle (prompt ❯ vacío)
  - Han pasado > MIN_WORK_TIME (300s) desde que se envió
  - El .docx NO existe
  - → Se limpia el worker y se marca como libre

EN COOLDOWN:
  - Han pasado < COOLDOWN_AFTER_SEND (120s) desde el envío
  - No se verifica nada — se asume que está arrancando
```

## Parámetros y Constantes

| Parámetro | Default | Descripción |
|-----------|---------|-------------|
| INTERVAL | 60s | Segundos entre cada ciclo de verificación |
| NUM_WORKERS | 4 | Cantidad de workers tmux a usar |
| MIN_WORK_TIME | 300s | Gracia antes de declarar fallo |
| COOLDOWN_AFTER_SEND | 120s | Gracia después de enviar (no verificar idle) |
| WORKER_WINDOWS | 1,2,4,5... | Ventanas tmux disponibles (excluye coordinador en W3) |

## Limitaciones Arquitectónicas

1. **Detección vía screen scraping** — Parsear tmux pane no es 100% confiable
2. **Detección vía file exists** — Solo funciona si el output es un archivo; no valida contenido
3. **Dependencias hardcoded** — Tarea 13 espera 1-6, pero no es un DAG genérico
4. **Sin retry** — Tareas fallidas se marcan pero no se reintentan
5. **Sin watchdog** — No detecta workers atorados por tiempo prolongado (Bug 10)
6. **RAM bound** — Cada Claude usa ~200-300 MB, límite práctico ~4-5 workers en 8 GB
7. **Single tmux session** — Todo opera en session "0", no soporta múltiples sessions

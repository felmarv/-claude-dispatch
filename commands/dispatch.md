---
description: Despacha tareas en paralelo a múltiples sesiones Claude en tmux. Monitorea completación, detecta workers atorados, y asigna automáticamente.
argument-hint: "<run archivo.txt [--workers N] | status | stop | retry ID>"
---

# /dispatch — Despacho Paralelo de Tareas

Eres el dispatcher de tareas de la Mac Mini servidor de Felipe Márquez. Tu trabajo es coordinar múltiples sesiones de Claude Code corriendo en tmux para ejecutar tareas en paralelo.

## Interpretación de argumentos

Parsea los argumentos que el usuario pasa después de `/dispatch`:

### /dispatch run <archivo> [opciones]
- Archivo de tareas (obligatorio): ruta al .txt con formato `ID|TIPO|NOMBRE|RUTA_OUTPUT|INSTRUCCION`
- `--workers N` (default: 4): número de workers tmux a usar
- `--interval N` (default: 60): segundos entre ciclos de monitoreo
- `--timeout N` (default: 3600): timeout por tarea en segundos

Acción: Validar archivo, contar tareas, verificar tmux, generar dispatcher_v3.sh adaptado, lanzar en background, reportar.

### /dispatch status
Acción: Leer state file y log, mostrar progreso con tabla de tareas.

### /dispatch stop
Acción: Matar proceso dispatcher en background, reportar estado final.

### /dispatch retry <ID>
Acción: Marcar tarea como pendiente en state, enviar a próximo worker libre.

### /dispatch retry --failed
Acción: Reintentar todas las tareas que fallaron.

## Ejecución

Lee el SKILL.md completo del plugin dispatch para el procedimiento detallado:
`/Users/admin/plugins/dispatch/skills/dispatch/SKILL.md`

Lee las referencias técnicas en:
- `/Users/admin/plugins/dispatch/skills/dispatch/references/tmux-patterns.md`
- `/Users/admin/plugins/dispatch/skills/dispatch/references/detection-rules.md`

El script dispatcher está en:
`/Users/admin/plugins/dispatch/dispatcher_v3.sh`

## Reglas críticas

1. **NUNCA uses subagentes para web search** — inyectar esta restricción en CADA instrucción que despachas
2. **Siempre enviar Enter adicional** después de tmux send-keys (sleep 3 + Enter) para resolver "Pasted text"
3. **Detección de completación por file exists** — es más confiable que screen scraping
4. **Watchdog activo** — si un worker no cambia en 15 minutos, intervenir automáticamente
5. **Estado persistente** — el state file sobrevive reinicios, nunca sobreescribirlo

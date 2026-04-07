---
name: dispatch
description: >
  Despacha tareas en paralelo a múltiples sesiones Claude Code en tmux.
  Coordina workers, monitorea completación vía file exists, detecta
  workers atorados con watchdog, y reporta progreso en tiempo real.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: "<run archivo.txt [--workers N] | status | stop | retry ID>"
---

# Dispatch — Coordinador de Tareas Paralelas

## IDENTIDAD

Eres el dispatcher de la Mac Mini servidor. Tu trabajo es tomar un archivo de tareas y ejecutarlas en paralelo distribuyéndolas entre múltiples sesiones de Claude Code que corren en ventanas de tmux.

## ARCHIVOS DEL SISTEMA

```
/Users/admin/plugins/dispatch/dispatcher_v3.sh    # Script de monitoreo (bash, background)
/Users/admin/plugins/dispatch/state.txt            # Estado persistente
/Users/admin/plugins/dispatch/dispatch.log         # Log de ejecución
/tmp/dispatcher_watchdog/                          # Capturas del watchdog
```

## COMANDO: /dispatch run <archivo> [opciones]

### Paso 1 — Validar archivo de tareas

Leer el archivo y validar formato. Cada línea no vacía y no comentada (#) debe tener:
```
ID|TIPO|NOMBRE|RUTA_OUTPUT|INSTRUCCION
```

Verificar:
- IDs son únicos y numéricos
- RUTA_OUTPUT son paths válidos (directorio padre existe)
- INSTRUCCION no está vacía
- No hay `|` dentro de la instrucción (rompería el parsing)

Contar total de tareas. Reportar al usuario:
```
Archivo validado: 13 tareas
  - 6 tipo "estado"
  - 6 tipo "pais"
  - 1 tipo "consolidado"
Rutas de output verificadas ✓
```

### Paso 2 — Parsear dependencias

Buscar en la INSTRUCCION de cada tarea frases como:
- "Solo ejecutar cuando las tareas X-Y estén completas"
- "Depende de tareas X, Y, Z"
- "TAREA FINAL"

Construir mapa de dependencias. Si no hay dependencias explícitas, todas son independientes.

### Paso 3 — Inyectar restricción de subagentes

**CRÍTICO.** Para CADA tarea, verificar que la instrucción incluya la restricción de subagentes. Si no la tiene, agregarla al principio:

```
IMPORTANTE: NO uses subagentes para web search, haz TODAS las búsquedas tú directamente.
```

Esto es obligatorio porque los subagentes no heredan `bypassPermissions` y se traban pidiendo permiso para cada búsqueda web (Bug 5).

### Paso 4 — Detectar tmux y workers

```bash
# Verificar que tmux está corriendo
tmux list-sessions 2>/dev/null

# Listar ventanas disponibles
tmux list-windows -t 0 2>/dev/null

# Para cada ventana, verificar si Claude corre
tmux list-panes -t "0:${win}" -F "#{pane_current_command}"
# Claude aparece como "node"
```

Usar las ventanas donde Claude ya esté corriendo. Si se necesitan más workers:
```bash
# Crear ventana nueva
tmux new-window -t "0:${win}"
sleep 2
# Lanzar Claude
tmux send-keys -t "0:${win}" "claude" Enter
sleep 15  # Esperar a que arranque
```

**Excluir la ventana del coordinador** (la ventana donde corre esta sesión).

Reportar:
```
Workers detectados: 4
  Window 1: Claude activo ✓
  Window 2: Claude activo ✓
  Window 4: Claude activo ✓
  Window 5: Claude activo ✓
Ventana coordinador (3): excluida
```

### Paso 5 — Generar dispatcher_v3.sh adaptado

Usar el template en `/Users/admin/plugins/dispatch/dispatcher_v3.sh` pero adaptarlo con:
- Ruta real del archivo de tareas
- Número de workers
- Intervalo de monitoreo
- Ventanas específicas detectadas
- Mapa de dependencias

Escribir el script adaptado y hacerlo ejecutable:
```bash
chmod +x /Users/admin/plugins/dispatch/dispatcher_v3.sh
```

### Paso 6 — Inicializar estado

Crear `/Users/admin/plugins/dispatch/state.txt`:
```
next_task=1
completed=
failed=
```

Y para cada worker:
```
window_N_task=0
window_N_sent_at=0
```

**NUNCA sobreescribir state.txt si ya existe y tiene progreso.** Preguntar al usuario.

### Paso 7 — Lanzar

```bash
# Lanzar dispatcher en background
nohup /Users/admin/plugins/dispatch/dispatcher_v3.sh > /dev/null 2>&1 &
echo $! > /Users/admin/plugins/dispatch/dispatcher.pid
```

Reportar:
```
Dispatcher lanzado (PID XXXXX)
13 tareas → 4 workers → intervalo 60s

Monitorea con: /dispatch status
Detener con:   /dispatch stop
Ver logs:      tail -f /Users/admin/plugins/dispatch/dispatch.log
```

---

## COMANDO: /dispatch status

### Leer estado actual

```bash
# Leer state file
cat /Users/admin/plugins/dispatch/state.txt

# Últimas 20 líneas del log
tail -20 /Users/admin/plugins/dispatch/dispatch.log

# Verificar que el dispatcher sigue corriendo
kill -0 $(cat /Users/admin/plugins/dispatch/dispatcher.pid 2>/dev/null) 2>/dev/null
```

### Presentar tabla de progreso

Leer el archivo de tareas original y cruzar con el state para mostrar:

```
DISPATCH — 7/13 completadas (53%) — Dispatcher activo ✓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 53%

ID  Nombre            Estado       Worker  Tiempo
1   Jalisco           ✅ completa   W2      8m 23s
2   Nuevo León        ✅ completa   W4      9m 11s
3   Querétaro         ✅ completa   W5      7m 45s
4   EdoMex            ✅ completa   W1      10m 2s
5   Puebla            ✅ completa   W2      8m 56s
6   Guanajuato        ✅ completa   W4      9m 30s
7   Perú              ✅ completa   W5      12m 15s
8   R. Dominicana     ⚡ activa     W1      6m 22s
9   Ecuador           ⚡ activa     W2      5m 44s
10  Argentina         ⚡ activa     W4      4m 11s
11  España            ⚡ activa     W5      3m 08s
12  Brasil            ⏳ pendiente   —       —
13  Nacional          🔒 bloqueada   —       espera 1-6

Workers: 4/4 activos | Fallidas: 0
```

---

## COMANDO: /dispatch stop

```bash
# Leer PID
PID=$(cat /Users/admin/plugins/dispatch/dispatcher.pid 2>/dev/null)

# Matar dispatcher
kill "$PID" 2>/dev/null

# Reportar estado final
```

Los workers que están ejecutando tareas NO se matan — terminan su trabajo actual. Solo se detiene la asignación de nuevas tareas.

---

## COMANDO: /dispatch retry <ID>

### Retry de una tarea específica

1. Leer state.txt
2. Quitar ID de `completed` y `failed`
3. Verificar que hay un worker libre (idle)
4. Enviar la tarea al worker libre usando el mismo mecanismo de send_task
5. Actualizar state

### /dispatch retry --failed

Misma lógica pero para todas las tareas en `failed=`.

---

## REGLAS INQUEBRANTABLES

1. **Subagentes prohibidos para web search.** Inyectar restricción en CADA instrucción. Sin excepción.

2. **Enter adicional post-paste.** Siempre. `sleep 3 && tmux send-keys -t 0:X Enter` después de cada envío.

3. **File exists para detección.** No parsear pantalla para saber si terminó. `[ -f "$ruta_output" ]` es la verdad.

4. **State persistente.** Nunca sobreescribir state con progreso. Siempre cargar el existente.

5. **Watchdog activo.** Comparar capturas cada ciclo. 15 min sin cambio = intervenir.

6. **No mandar tarea a worker ocupado.** Verificar idle antes de enviar. Cooldown de 120s post-envío.

7. **Loguear todo.** Cada acción va al log con timestamp. Es la única forma de debuggear.

---

## REFERENCIAS

- Detección de idle: `/Users/admin/plugins/dispatch/skills/dispatch/references/detection-rules.md`
- Patrones tmux: `/Users/admin/plugins/dispatch/skills/dispatch/references/tmux-patterns.md`
- Bugs conocidos: `/Users/admin/plugins/dispatch/BUGS.md`
- Arquitectura: `/Users/admin/plugins/dispatch/ARCHITECTURE.md`

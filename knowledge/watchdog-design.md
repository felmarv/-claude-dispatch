# Diseño del Watchdog — Detección de Sesiones Atoradas

## El problema (Bug 10)

El bug más costoso: 3 workers quedaron idle con "Pasted text" en buffer durante **1 hora completa**. El dispatcher no los detectó porque:
1. No estaban "idle" según la definición (tenían texto en la línea de input)
2. No estaban "trabajando" (no había spinners ni keywords nuevas)
3. El dispatcher no tiene concepto de "sin cambios por mucho tiempo"

**Impacto:** ~3 horas-worker perdidas. En un run de 13 tareas esto puede significar la diferencia entre 3 horas y 6 horas de ejecución total.

## Diseño propuesto

### Concepto: Comparación de capturas

Cada ciclo, el watchdog captura la pantalla de cada worker y la compara con la captura anterior. Si una ventana no ha cambiado en N ciclos consecutivos, genera una alerta.

### Implementación

```bash
WATCHDOG_DIR="/tmp/dispatcher_watchdog"
STALE_THRESHOLD=15  # ciclos sin cambio antes de alertar (15 min con interval=60s)

watchdog_check() {
    local window=$1
    local current_capture
    current_capture=$(tmux capture-pane -t "0:${window}" -p -S -10 2>/dev/null)
    
    local prev_file="$WATCHDOG_DIR/window_${window}_prev.txt"
    local stale_file="$WATCHDOG_DIR/window_${window}_stale_count.txt"
    
    # Inicializar contador si no existe
    [ ! -f "$stale_file" ] && echo "0" > "$stale_file"
    
    if [ -f "$prev_file" ]; then
        local prev_capture
        prev_capture=$(cat "$prev_file")
        
        if [ "$current_capture" = "$prev_capture" ]; then
            # Sin cambios — incrementar contador
            local count=$(cat "$stale_file")
            count=$((count + 1))
            echo "$count" > "$stale_file"
            
            if [ "$count" -ge "$STALE_THRESHOLD" ]; then
                return 1  # STALE — posiblemente atorada
            fi
        else
            # Hubo cambio — resetear contador
            echo "0" > "$stale_file"
        fi
    fi
    
    # Guardar captura actual como referencia
    echo "$current_capture" > "$prev_file"
    return 0  # OK
}
```

### Acciones ante detección de stale

Escalamiento progresivo:

```
Ciclo 15 (15 min sin cambio):
  → Log warning: "Window X sin cambio en 15 minutos"
  → Enviar Enter como intento de desbloqueo
  
Ciclo 20 (20 min sin cambio):
  → Log alert: "Window X posiblemente atorada"
  → Enviar /clear + Enter
  → Reintentar la tarea asignada
  
Ciclo 30 (30 min sin cambio):
  → Log critical: "Window X no responde"
  → Escribir archivo de alerta para el coordinador
  → Opcionalmente: kill + restart Claude en esa ventana
  → Opcionalmente: notificar vía Asana/email
```

### Intento de desbloqueo automático

```bash
try_unblock() {
    local window=$1
    local attempt=$2
    
    case $attempt in
        1)
            # Primer intento: solo Enter
            tmux send-keys -t "0:${window}" Enter
            log "WATCHDOG: Enviado Enter a ventana $window (intento $attempt)"
            ;;
        2)
            # Segundo intento: /clear + nueva instrucción
            tmux send-keys -t "0:${window}" "/clear" Enter
            sleep 3
            local task_id=$(get_state "window_${window}_task")
            if [ "$task_id" != "0" ]; then
                send_task "$window" "$task_id"  # Reintentar
                log "WATCHDOG: Reintentando tarea $task_id en ventana $window"
            fi
            ;;
        3)
            # Tercer intento: kill + restart
            local pane_pid=$(tmux list-panes -t "0:${window}" -F "#{pane_pid}")
            kill "$pane_pid" 2>/dev/null
            sleep 2
            tmux send-keys -t "0:${window}" "claude" Enter
            sleep 15
            log "WATCHDOG: Claude reiniciado en ventana $window"
            ;;
    esac
}
```

### Archivo de alerta

```bash
# El watchdog escribe un archivo que el coordinador puede leer
ALERT_FILE="/tmp/dispatcher_alert.txt"

write_alert() {
    local window=$1
    local task_id=$(get_state "window_${window}_task")
    local task_name=$(get_task_name "$task_id")
    echo "[$(date)] ALERT: Window $window atorada — tarea $task_id ($task_name) sin progreso por >15 min" >> "$ALERT_FILE"
}
```

### Notificación externa

```bash
# Crear tarea en Asana cuando se detecta worker atorado
notify_asana() {
    # Usar MCP de Asana para crear tarea de alerta
    # El coordinador Claude puede leer $ALERT_FILE y actuar
    echo "DISPATCH ALERT: Worker atorado" > /tmp/dispatch_needs_attention
}
```

## Integración en el main loop

```bash
main_loop() {
    mkdir -p "$WATCHDOG_DIR"
    
    while true; do
        for win in "${WORKER_WINDOWS[@]}"; do
            # ... lógica existente de verificación ...
            
            # Watchdog check
            if ! watchdog_check "$win"; then
                local stale_count=$(cat "$WATCHDOG_DIR/window_${win}_stale_count.txt")
                log "WATCHDOG: Window $win sin cambio por $stale_count ciclos"
                
                if [ "$stale_count" -eq "$STALE_THRESHOLD" ]; then
                    try_unblock "$win" 1
                elif [ "$stale_count" -eq $((STALE_THRESHOLD + 5)) ]; then
                    try_unblock "$win" 2
                elif [ "$stale_count" -eq $((STALE_THRESHOLD + 15)) ]; then
                    try_unblock "$win" 3
                fi
            fi
        done
        
        sleep "$INTERVAL"
    done
}
```

## Estado: NO IMPLEMENTADO

Este diseño existe solo como documentación. No se implementó en el dispatcher V2.
Es prioritario para V3 o para el skill `/dispatch`.

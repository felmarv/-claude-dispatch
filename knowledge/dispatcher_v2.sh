#!/bin/bash
# DOMINEUM Task Dispatcher V2
# Monitorea sesiones tmux de Claude y despacha tareas automáticamente
# Corrige: detección prematura de idle, timestamps por tarea, cooldown después de envío

TASKS_FILE="/Users/admin/scripts/dispatcher/tasks.txt"
STATE_FILE="/Users/admin/scripts/dispatcher/state_v2.txt"
LOG_FILE="/Users/admin/scripts/dispatcher/dispatcher_v2.log"
INTERVAL="${1:-60}"  # Default 1 minuto
NUM_WORKERS="${2:-4}"  # Default 4 workers
MIN_WORK_TIME=300  # Mínimo 5 minutos antes de considerar fallo
COOLDOWN_AFTER_SEND=120  # 2 minutos de gracia después de enviar tarea

WORKER_WINDOWS=()

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Inicializar archivo de estado solo si no existe
init_state() {
    if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
        echo "next_task=1" > "$STATE_FILE"
        echo "completed=" >> "$STATE_FILE"
        log "Estado inicializado (fresh start)"
    else
        log "Estado existente cargado: next_task=$(get_state 'next_task'), completed=$(get_state 'completed')"
    fi
}

get_state() {
    grep "^$1=" "$STATE_FILE" | cut -d'=' -f2
}

set_state() {
    if grep -q "^$1=" "$STATE_FILE"; then
        sed -i '' "s|^$1=.*|$1=$2|" "$STATE_FILE"
    else
        echo "$1=$2" >> "$STATE_FILE"
    fi
}

get_total_tasks() {
    grep -v '^#' "$TASKS_FILE" | grep -v '^$' | wc -l | tr -d ' '
}

get_task_instruction() {
    grep -v '^#' "$TASKS_FILE" | grep -v '^$' | grep "^${1}|" | cut -d'|' -f5
}

get_task_name() {
    grep -v '^#' "$TASKS_FILE" | grep -v '^$' | grep "^${1}|" | cut -d'|' -f3
}

get_task_docx() {
    grep -v '^#' "$TASKS_FILE" | grep -v '^$' | grep "^${1}|" | cut -d'|' -f4
}

now_epoch() {
    date +%s
}

# Verificar si Claude está idle - más conservador
is_session_idle() {
    local window=$1
    local last_lines
    last_lines=$(tmux capture-pane -t "0:${window}" -p -S -3 2>/dev/null)

    if [ -z "$last_lines" ]; then
        return 1
    fi

    # Obtener la última línea no vacía
    local last_line
    last_line=$(echo "$last_lines" | grep -v '^$' | tail -1)

    # Debe tener el prompt ❯ Y no tener indicadores de actividad en las últimas 3 líneas
    if echo "$last_line" | grep -q "❯" && \
       ! echo "$last_lines" | grep -qiE "(Cooked|Brewed|Whirring|Cogitated|Running|still running|Do you want|searching|Writing|Reading|Thinking|thinking|Web Search|Bash|agent|tokens)" && \
       ! echo "$last_line" | grep -qE "\[Pasted"; then
        # Verificación adicional: el prompt debe estar vacío (sin texto después del ❯)
        if echo "$last_line" | grep -qE "❯\s*$"; then
            return 0  # Genuinamente idle
        fi
    fi

    return 1
}

is_task_done() {
    local docx_path
    docx_path=$(get_task_docx "$1")
    [ -f "$docx_path" ]
}

# Enviar tarea - sin /clear separado, instrucción directa
send_task() {
    local window=$1
    local task_id=$2
    local task_name
    task_name=$(get_task_name "$task_id")
    local instruction
    instruction=$(get_task_instruction "$task_id")

    if [ -z "$instruction" ]; then
        log "ERROR: No se encontró instrucción para tarea $task_id"
        return 1
    fi

    log ">>> Enviando tarea $task_id ($task_name) a ventana $window"

    # Escribir instrucción a archivo temporal
    local tmp_file="/tmp/dispatcher_task_${task_id}.txt"
    echo "$instruction" > "$tmp_file"

    # Enviar directamente sin /clear previo
    tmux send-keys -t "0:${window}" "$(cat "$tmp_file")" Enter
    rm -f "$tmp_file"

    # Registrar tarea y timestamp
    set_state "window_${window}_task" "$task_id"
    set_state "window_${window}_sent_at" "$(now_epoch)"

    log "    Tarea $task_id despachada a ventana $window ($(date '+%H:%M'))"
}

# Setup workers
setup_workers() {
    log "=== Configurando $NUM_WORKERS workers ==="

    local available_windows=(1 2 4 5 6 7 8 9)

    for ((i=0; i<NUM_WORKERS; i++)); do
        local win=${available_windows[$i]}

        if tmux list-windows -t 0 2>/dev/null | grep -q "^${win}:"; then
            local pane_cmd
            pane_cmd=$(tmux list-panes -t "0:${win}" -F "#{pane_current_command}" 2>/dev/null)
            if echo "$pane_cmd" | grep -q "node"; then
                log "Worker ventana $win: Claude ya corriendo"
                WORKER_WINDOWS+=("$win")
                continue
            fi
            tmux send-keys -t "0:${win}" "claude" Enter
            log "Worker ventana $win: Claude lanzado"
        else
            tmux new-window -t "0:${win}" 2>/dev/null
            sleep 2
            tmux send-keys -t "0:${win}" "claude" Enter
            log "Worker ventana $win: creada y Claude lanzado"
        fi

        WORKER_WINDOWS+=("$win")
        sleep 3
    done

    log "Workers configurados: ventanas ${WORKER_WINDOWS[*]}"
    log "Esperando 15s a que todos arranquen..."
    sleep 15
}

# Ciclo principal
main_loop() {
    local total_tasks
    total_tasks=$(get_total_tasks)
    log "=== DOMINEUM Dispatcher V2 iniciado ==="
    log "Total tareas: $total_tasks | Workers: ${#WORKER_WINDOWS[@]} | Intervalo: ${INTERVAL}s"
    log "Min work time: ${MIN_WORK_TIME}s | Cooldown: ${COOLDOWN_AFTER_SEND}s"
    log "Ventanas worker: ${WORKER_WINDOWS[*]}"

    while true; do
        local active_count=0
        local now
        now=$(now_epoch)

        for win in "${WORKER_WINDOWS[@]}"; do
            local current_task
            current_task=$(get_state "window_${win}_task")

            if [ -n "$current_task" ] && [ "$current_task" != "0" ]; then
                # Tiene tarea asignada
                local sent_at
                sent_at=$(get_state "window_${win}_sent_at")
                local elapsed=$((now - sent_at))

                # Verificar si el docx ya existe → completada
                if is_task_done "$current_task"; then
                    local task_name
                    task_name=$(get_task_name "$current_task")
                    log "<<< COMPLETADA tarea $current_task ($task_name) en ventana $win (${elapsed}s)"

                    local completed
                    completed=$(get_state "completed")
                    set_state "completed" "${completed}${current_task},"
                    set_state "window_${win}_task" "0"
                    set_state "window_${win}_sent_at" "0"

                # Todavía en cooldown → no revisar
                elif [ "$elapsed" -lt "$COOLDOWN_AFTER_SEND" ]; then
                    log "    Ventana $win: tarea $current_task en cooldown (${elapsed}s/${COOLDOWN_AFTER_SEND}s)"
                    active_count=$((active_count + 1))

                # Ya pasó el cooldown, verificar si sigue trabajando
                elif ! is_session_idle "$win"; then
                    # Sigue ocupada, todo bien
                    active_count=$((active_count + 1))

                # Idle Y ya pasó min_work_time → probable fallo
                elif [ "$elapsed" -gt "$MIN_WORK_TIME" ]; then
                    log "??? Ventana $win: tarea $current_task idle después de ${elapsed}s sin docx - marcando como fallo"
                    set_state "window_${win}_task" "0"
                    set_state "window_${win}_sent_at" "0"
                    # Hacer /clear para limpiar
                    tmux send-keys -t "0:${win}" "/clear" Enter
                    sleep 3

                # Idle pero dentro de min_work_time → puede estar procesando
                else
                    log "    Ventana $win: tarea $current_task parece idle (${elapsed}s) - esperando min_work_time"
                    active_count=$((active_count + 1))
                fi
            fi

            # Si worker está libre, asignar siguiente tarea
            current_task=$(get_state "window_${win}_task")
            if [ -z "$current_task" ] || [ "$current_task" = "0" ]; then
                if is_session_idle "$win"; then
                    local next
                    next=$(get_state "next_task")

                    # Tarea 13 espera a que 1-6 estén completas
                    if [ "$next" = "13" ]; then
                        local states_done=true
                        for sid in 1 2 3 4 5 6; do
                            if ! is_task_done "$sid"; then
                                states_done=false
                                break
                            fi
                        done
                        if ! $states_done; then
                            log "--- Tarea 13 (consolidado) esperando estados 1-6"
                            active_count=$((active_count + 1))
                            continue
                        fi
                    fi

                    if [ "$next" -le "$total_tasks" ] 2>/dev/null; then
                        send_task "$win" "$next"
                        set_state "next_task" "$((next + 1))"
                        active_count=$((active_count + 1))
                    fi
                else
                    active_count=$((active_count + 1))
                fi
            fi
        done

        # Status
        local completed_count
        completed_count=$(get_state "completed" | tr ',' '\n' | grep -c '[0-9]')
        local next_pending
        next_pending=$(get_state "next_task")
        log "--- STATUS: ${completed_count}/${total_tasks} completas | ${active_count} activas | Próxima tarea: ${next_pending}"

        # Listar docx existentes
        local existing_docx
        existing_docx=$(find "/Users/admin/Google Drive/Mi unidad/DOMINEUM" -name "*.docx" -newer "$STATE_FILE" 2>/dev/null | wc -l | tr -d ' ')
        log "    Docx nuevos detectados: $existing_docx"

        # Fin si todas completadas
        if [ "$completed_count" -ge "$total_tasks" ]; then
            log "=== TODAS LAS TAREAS COMPLETADAS ==="
            break
        fi

        # Fin si no hay pendientes ni activas
        if [ "$next_pending" -gt "$total_tasks" ] 2>/dev/null && [ "$active_count" -eq 0 ]; then
            log "=== No hay más tareas pendientes ni activas ==="
            break
        fi

        sleep "$INTERVAL"
    done
}

# --- EJECUCIÓN ---
init_state
setup_workers
main_loop

log "=== Dispatcher V2 terminado ==="

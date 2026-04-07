#!/bin/bash
# ============================================================
# Dispatcher V3 — Despacho Automático de Tareas entre Sesiones Claude
# Márquez & Asociados — Mac Mini Server
#
# Mejoras sobre V2:
#   - Watchdog: detecta workers atorados (>15 min sin cambio)
#   - Enter automático post-paste (Bug 7 fix)
#   - Dependencias genéricas (parsea "depends_on:X,Y,Z" en instrucción)
#   - Mejor idle detection (solo última línea)
#   - Desbloqueo escalado (Enter → /clear → kill/restart)
#   - Tracking de tareas fallidas
#
# Uso:
#   ./dispatcher_v3.sh <tasks_file> [intervalo] [num_workers]
#   ./dispatcher_v3.sh tasks.txt 60 4
# ============================================================

set -euo pipefail

# --- CONFIGURACIÓN ---
TASKS_FILE="${1:?Uso: ./dispatcher_v3.sh <tasks_file> [intervalo] [num_workers]}"
INTERVAL="${2:-60}"
NUM_WORKERS="${3:-4}"

DISPATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$DISPATCH_DIR/state.txt"
LOG_FILE="$DISPATCH_DIR/dispatch.log"
PID_FILE="$DISPATCH_DIR/dispatcher.pid"
WATCHDOG_DIR="/tmp/dispatcher_watchdog"

MIN_WORK_TIME=300        # 5 min antes de considerar fallo
COOLDOWN_AFTER_SEND=120  # 2 min gracia post-envío
STALE_THRESHOLD=15       # ciclos sin cambio = atorado (15 min @ 60s)
STALE_UNBLOCK_2=20       # ciclos para /clear + retry
STALE_UNBLOCK_3=30       # ciclos para kill + restart

WORKER_WINDOWS=()

# --- FUNCIONES BÁSICAS ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

now_epoch() {
    date +%s
}

get_state() {
    grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2
}

set_state() {
    if grep -q "^$1=" "$STATE_FILE" 2>/dev/null; then
        sed -i '' "s|^$1=.*|$1=$2|" "$STATE_FILE"
    else
        echo "$1=$2" >> "$STATE_FILE"
    fi
}

get_total_tasks() {
    grep -v '^#' "$TASKS_FILE" | grep -v '^$' | wc -l | tr -d ' '
}

get_task_field() {
    # $1=task_id, $2=field_number (1=ID, 2=TIPO, 3=NOMBRE, 4=RUTA, 5=INSTRUCCION)
    grep -v '^#' "$TASKS_FILE" | grep -v '^$' | grep "^${1}|" | cut -d'|' -f"$2"
}

get_task_name() { get_task_field "$1" 3; }
get_task_docx() { get_task_field "$1" 4; }
get_task_instruction() { get_task_field "$1" 5; }

# --- DEPENDENCIAS ---

get_task_dependencies() {
    # Busca "depends_on:X,Y,Z" o "Solo ejecutar cuando las tareas X-Y" en la instrucción
    local instruction
    instruction=$(get_task_instruction "$1")

    # Formato explícito: depends_on:1,2,3
    local deps
    deps=$(echo "$instruction" | grep -oE 'depends_on:[0-9,]+' | cut -d':' -f2)
    if [ -n "$deps" ]; then
        echo "$deps"
        return
    fi

    # Formato natural: "cuando las tareas X-Y estén completas"
    local range
    range=$(echo "$instruction" | grep -oE 'tareas [0-9]+-[0-9]+' | grep -oE '[0-9]+-[0-9]+')
    if [ -n "$range" ]; then
        local start end
        start=$(echo "$range" | cut -d'-' -f1)
        end=$(echo "$range" | cut -d'-' -f2)
        local result=""
        for ((i=start; i<=end; i++)); do
            [ -n "$result" ] && result="$result,"
            result="$result$i"
        done
        echo "$result"
        return
    fi

    echo ""  # Sin dependencias
}

are_dependencies_met() {
    local task_id=$1
    local deps
    deps=$(get_task_dependencies "$task_id")

    if [ -z "$deps" ]; then
        return 0  # Sin dependencias, siempre OK
    fi

    IFS=',' read -ra dep_ids <<< "$deps"
    for dep_id in "${dep_ids[@]}"; do
        local dep_docx
        dep_docx=$(get_task_docx "$dep_id")
        if [ ! -f "$dep_docx" ]; then
            return 1  # Dependencia no completada
        fi
    done
    return 0  # Todas las dependencias completadas
}

# --- DETECCIÓN DE ESTADO ---

is_session_idle() {
    local window=$1
    local last_line
    last_line=$(tmux capture-pane -t "0:${window}" -p -S -1 2>/dev/null | grep -v '^$' | tail -1)

    if [ -z "$last_line" ]; then
        return 1
    fi

    # Solo revisar la ÚLTIMA línea: ¿es un prompt ❯ vacío?
    if echo "$last_line" | grep -qE "❯\s*$" && \
       ! echo "$last_line" | grep -qE "\[Pasted"; then
        return 0  # Idle
    fi

    return 1
}

is_task_done() {
    local docx_path
    docx_path=$(get_task_docx "$1")
    [ -f "$docx_path" ] && [ -s "$docx_path" ]  # Existe Y no está vacío
}

# --- WATCHDOG ---

watchdog_check() {
    local window=$1
    local current_capture
    current_capture=$(tmux capture-pane -t "0:${window}" -p -S -5 2>/dev/null)

    local prev_file="$WATCHDOG_DIR/win_${window}.txt"
    local stale_file="$WATCHDOG_DIR/win_${window}_stale.txt"

    [ ! -f "$stale_file" ] && echo "0" > "$stale_file"

    if [ -f "$prev_file" ]; then
        local prev_capture
        prev_capture=$(cat "$prev_file")

        if [ "$current_capture" = "$prev_capture" ]; then
            local count
            count=$(cat "$stale_file")
            count=$((count + 1))
            echo "$count" > "$stale_file"

            if [ "$count" -ge "$STALE_THRESHOLD" ]; then
                echo "$count"
                echo "$current_capture" > "$prev_file"
                return 1  # STALE
            fi
        else
            echo "0" > "$stale_file"
        fi
    fi

    echo "$current_capture" > "$prev_file"
    return 0
}

watchdog_reset() {
    local window=$1
    echo "0" > "$WATCHDOG_DIR/win_${window}_stale.txt" 2>/dev/null
}

try_unblock() {
    local window=$1
    local stale_count=$2
    local task_id
    task_id=$(get_state "window_${window}_task")

    if [ "$stale_count" -ge "$STALE_UNBLOCK_3" ]; then
        # Nivel 3: kill + restart Claude
        log "WATCHDOG [L3]: Reiniciando Claude en ventana $window"
        local pane_pid
        pane_pid=$(tmux list-panes -t "0:${window}" -F "#{pane_pid}" 2>/dev/null)
        if [ -n "$pane_pid" ]; then
            kill "$pane_pid" 2>/dev/null
            sleep 2
            tmux send-keys -t "0:${window}" "claude" Enter
            sleep 15
        fi
        # Marcar tarea como fallida para retry
        if [ -n "$task_id" ] && [ "$task_id" != "0" ]; then
            local failed
            failed=$(get_state "failed")
            set_state "failed" "${failed}${task_id},"
            set_state "window_${window}_task" "0"
            set_state "window_${window}_sent_at" "0"
            log "WATCHDOG: Tarea $task_id marcada como fallida"
        fi
        watchdog_reset "$window"

    elif [ "$stale_count" -ge "$STALE_UNBLOCK_2" ]; then
        # Nivel 2: /clear + reenviar tarea
        log "WATCHDOG [L2]: /clear + reenvío en ventana $window"
        tmux send-keys -t "0:${window}" "/clear" Enter
        sleep 3
        if [ -n "$task_id" ] && [ "$task_id" != "0" ]; then
            send_task "$window" "$task_id"
        fi
        watchdog_reset "$window"

    elif [ "$stale_count" -ge "$STALE_THRESHOLD" ]; then
        # Nivel 1: solo Enter
        log "WATCHDOG [L1]: Enter a ventana $window (${stale_count} ciclos sin cambio)"
        tmux send-keys -t "0:${window}" Enter
    fi
}

# --- ENVÍO DE TAREAS ---

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

    # Inyectar restricción de subagentes si no la tiene
    if ! echo "$instruction" | grep -qi "no uses subagentes"; then
        instruction="IMPORTANTE: NO uses subagentes para web search, haz TODAS las búsquedas tú directamente. ${instruction}"
    fi

    log ">>> Enviando tarea $task_id ($task_name) a ventana $window"

    # Escribir a archivo temporal
    local tmp_file="/tmp/dispatch_task_${task_id}.txt"
    echo "$instruction" > "$tmp_file"

    # Enviar vía tmux
    tmux send-keys -t "0:${window}" "$(cat "$tmp_file")" Enter

    # OBLIGATORIO: Enter adicional para resolver "Pasted text" (Bug 7)
    sleep 3
    tmux send-keys -t "0:${window}" Enter

    rm -f "$tmp_file"

    # Registrar en state
    set_state "window_${window}_task" "$task_id"
    set_state "window_${window}_sent_at" "$(now_epoch)"

    # Reset watchdog para esta ventana
    watchdog_reset "$window"

    log "    Tarea $task_id despachada a ventana $window"
}

# --- SETUP ---

init_state() {
    if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
        echo "next_task=1" > "$STATE_FILE"
        echo "completed=" >> "$STATE_FILE"
        echo "failed=" >> "$STATE_FILE"
        log "Estado inicializado (fresh start)"
    else
        log "Estado existente cargado: next_task=$(get_state 'next_task'), completed=$(get_state 'completed'), failed=$(get_state 'failed')"
    fi
}

setup_workers() {
    log "=== Configurando $NUM_WORKERS workers ==="

    # Detectar ventana del coordinador (excluir)
    local coord_window
    coord_window=$(tmux display-message -p '#{window_index}' 2>/dev/null || echo "3")

    local available_windows=(1 2 4 5 6 7 8 9)
    local count=0

    for win in "${available_windows[@]}"; do
        [ "$count" -ge "$NUM_WORKERS" ] && break
        [ "$win" = "$coord_window" ] && continue

        if tmux list-windows -t 0 2>/dev/null | grep -q "^${win}:"; then
            local pane_cmd
            pane_cmd=$(tmux list-panes -t "0:${win}" -F "#{pane_current_command}" 2>/dev/null)
            if echo "$pane_cmd" | grep -q "node"; then
                log "Worker ventana $win: Claude activo"
                WORKER_WINDOWS+=("$win")
                count=$((count + 1))
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
        count=$((count + 1))
        sleep 3
    done

    log "Workers: ventanas ${WORKER_WINDOWS[*]} (coordinador: $coord_window excluido)"
    log "Esperando 15s a que arranquen..."
    sleep 15
}

# --- CICLO PRINCIPAL ---

main_loop() {
    local total_tasks
    total_tasks=$(get_total_tasks)

    log "============================================================"
    log "DISPATCHER V3 INICIADO"
    log "Tareas: $total_tasks | Workers: ${#WORKER_WINDOWS[@]} | Intervalo: ${INTERVAL}s"
    log "Watchdog: ${STALE_THRESHOLD} ciclos (${STALE_THRESHOLD} min @ 60s)"
    log "Ventanas: ${WORKER_WINDOWS[*]}"
    log "============================================================"

    mkdir -p "$WATCHDOG_DIR"

    while true; do
        local active_count=0
        local now
        now=$(now_epoch)

        for win in "${WORKER_WINDOWS[@]}"; do
            local current_task
            current_task=$(get_state "window_${win}_task")

            # --- Worker con tarea asignada ---
            if [ -n "$current_task" ] && [ "$current_task" != "0" ]; then
                local sent_at
                sent_at=$(get_state "window_${win}_sent_at")
                local elapsed=$((now - sent_at))

                # ¿Completada? (file exists + not empty)
                if is_task_done "$current_task"; then
                    local task_name
                    task_name=$(get_task_name "$current_task")
                    log "<<< COMPLETADA tarea $current_task ($task_name) en ventana $win (${elapsed}s)"

                    local completed
                    completed=$(get_state "completed")
                    set_state "completed" "${completed}${current_task},"
                    set_state "window_${win}_task" "0"
                    set_state "window_${win}_sent_at" "0"
                    watchdog_reset "$win"

                # ¿En cooldown?
                elif [ "$elapsed" -lt "$COOLDOWN_AFTER_SEND" ]; then
                    active_count=$((active_count + 1))

                # ¿Sigue trabajando?
                elif ! is_session_idle "$win"; then
                    active_count=$((active_count + 1))

                    # Watchdog check (incluso si parece ocupada)
                    if ! watchdog_check "$win" > /dev/null 2>&1; then
                        local stale
                        stale=$(cat "$WATCHDOG_DIR/win_${win}_stale.txt" 2>/dev/null || echo "0")
                        try_unblock "$win" "$stale"
                    fi

                # Idle + min_work_time pasado + sin output → fallo
                elif [ "$elapsed" -gt "$MIN_WORK_TIME" ]; then
                    local task_name
                    task_name=$(get_task_name "$current_task")
                    log "??? FALLO tarea $current_task ($task_name) en ventana $win (idle sin output, ${elapsed}s)"

                    local failed
                    failed=$(get_state "failed")
                    set_state "failed" "${failed}${current_task},"
                    set_state "window_${win}_task" "0"
                    set_state "window_${win}_sent_at" "0"
                    watchdog_reset "$win"

                    # Limpiar worker
                    tmux send-keys -t "0:${win}" "/clear" Enter
                    sleep 3

                # Idle pero dentro de min_work_time → esperar
                else
                    active_count=$((active_count + 1))
                fi
            fi

            # --- Worker libre: asignar siguiente tarea ---
            current_task=$(get_state "window_${win}_task")
            if [ -z "$current_task" ] || [ "$current_task" = "0" ]; then
                if is_session_idle "$win"; then
                    local next
                    next=$(get_state "next_task")

                    # Verificar que la tarea existe
                    if [ "$next" -le "$total_tasks" ] 2>/dev/null; then
                        # Verificar dependencias
                        if are_dependencies_met "$next"; then
                            send_task "$win" "$next"
                            set_state "next_task" "$((next + 1))"
                            active_count=$((active_count + 1))
                        else
                            local deps
                            deps=$(get_task_dependencies "$next")
                            log "--- Tarea $next esperando dependencias: $deps"
                            # Intentar la siguiente tarea que no tenga dependencias bloqueantes
                            local try_next=$((next + 1))
                            while [ "$try_next" -le "$total_tasks" ]; do
                                if are_dependencies_met "$try_next"; then
                                    send_task "$win" "$try_next"
                                    active_count=$((active_count + 1))
                                    break
                                fi
                                try_next=$((try_next + 1))
                            done
                        fi
                    fi
                else
                    # Worker libre pero no idle (ocupada por otra vía)
                    active_count=$((active_count + 1))
                fi
            fi
        done

        # --- Status ---
        local completed_count
        completed_count=$(get_state "completed" | tr ',' '\n' | grep -c '[0-9]' || echo "0")
        local failed_count
        failed_count=$(get_state "failed" | tr ',' '\n' | grep -c '[0-9]' || echo "0")
        local next_pending
        next_pending=$(get_state "next_task")

        log "--- STATUS: ${completed_count}/${total_tasks} completas | ${failed_count} fallidas | ${active_count} activas | Próxima: ${next_pending}"

        # --- Fin ---
        if [ "$completed_count" -ge "$total_tasks" ]; then
            log "============================================================"
            log "TODAS LAS TAREAS COMPLETADAS"
            log "============================================================"
            break
        fi

        if [ "$next_pending" -gt "$total_tasks" ] 2>/dev/null && [ "$active_count" -eq 0 ]; then
            log "============================================================"
            log "FIN: No hay más tareas pendientes ni activas"
            log "Completadas: $completed_count | Fallidas: $failed_count"
            log "============================================================"
            break
        fi

        sleep "$INTERVAL"
    done
}

# --- EJECUCIÓN ---
echo $$ > "$PID_FILE"
init_state
setup_workers
main_loop

log "Dispatcher V3 terminado (PID $$)"
rm -f "$PID_FILE"

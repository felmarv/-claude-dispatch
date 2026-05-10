#!/bin/bash
# Dispatcher — Fixes de auditoría + Mejoras de investigación
# 5 tareas paralelas, sesión tmux "1", ventanas 1-5

set -euo pipefail

TASKS_FILE="/Users/admin/plugins/dispatch/tasks_fixes_and_improvements.txt"
INTERVAL=60
TMUX_SESSION="1"

DISPATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$DISPATCH_DIR/state.txt"
LOG_FILE="$DISPATCH_DIR/dispatch.log"
PID_FILE="$DISPATCH_DIR/dispatcher.pid"
WATCHDOG_DIR="/tmp/dispatcher_watchdog"

MIN_WORK_TIME=300
COOLDOWN_AFTER_SEND=120
STALE_THRESHOLD=15
STALE_UNBLOCK_2=20
STALE_UNBLOCK_3=30

WORKER_WINDOWS=(1 2 3 4 5)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
now_epoch() { date +%s; }
get_state() { grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2; }
set_state() {
    if grep -q "^$1=" "$STATE_FILE" 2>/dev/null; then
        sed -i '' "s|^$1=.*|$1=$2|" "$STATE_FILE"
    else
        echo "$1=$2" >> "$STATE_FILE"
    fi
}
get_total_tasks() { grep -v '^#' "$TASKS_FILE" | grep -v '^$' | wc -l | tr -d ' '; }
get_task_field() { grep -v '^#' "$TASKS_FILE" | grep -v '^$' | grep "^${1}|" | cut -d'|' -f"$2"; }
get_task_name() { get_task_field "$1" 3; }
get_task_docx() { get_task_field "$1" 4; }
get_task_instruction() { get_task_field "$1" 5; }

is_session_idle() {
    local window=$1
    local last_line
    last_line=$(tmux capture-pane -t "${TMUX_SESSION}:${window}" -p -S -1 2>/dev/null | grep -v '^$' | tail -1)
    [ -z "$last_line" ] && return 1
    if echo "$last_line" | grep -qE "(❯\s*$|bypass permissions)" && \
       ! echo "$last_line" | grep -qE "\[Pasted"; then
        return 0
    fi
    return 1
}

is_task_done() {
    local docx_path
    docx_path=$(get_task_docx "$1")
    [ -f "$docx_path" ] && [ -s "$docx_path" ]
}

watchdog_check() {
    local window=$1
    local current_capture
    current_capture=$(tmux capture-pane -t "${TMUX_SESSION}:${window}" -p -S -5 2>/dev/null)
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
                return 1
            fi
        else
            echo "0" > "$stale_file"
        fi
    fi
    echo "$current_capture" > "$prev_file"
    return 0
}

watchdog_reset() { echo "0" > "$WATCHDOG_DIR/win_${1}_stale.txt" 2>/dev/null; }

try_unblock() {
    local window=$1 stale_count=$2
    local task_id
    task_id=$(get_state "window_${window}_task")
    if [ "$stale_count" -ge "$STALE_UNBLOCK_3" ]; then
        log "WATCHDOG [L3]: Reiniciando Claude en ventana $window"
        local pane_pid
        pane_pid=$(tmux list-panes -t "${TMUX_SESSION}:${window}" -F "#{pane_pid}" 2>/dev/null)
        [ -n "$pane_pid" ] && kill "$pane_pid" 2>/dev/null && sleep 2 && tmux send-keys -t "${TMUX_SESSION}:${window}" "claude" Enter && sleep 15
        if [ -n "$task_id" ] && [ "$task_id" != "0" ]; then
            local failed; failed=$(get_state "failed")
            set_state "failed" "${failed}${task_id},"
            set_state "window_${window}_task" "0"
            set_state "window_${window}_sent_at" "0"
        fi
        watchdog_reset "$window"
    elif [ "$stale_count" -ge "$STALE_UNBLOCK_2" ]; then
        log "WATCHDOG [L2]: /clear + reenvío en ventana $window"
        tmux send-keys -t "${TMUX_SESSION}:${window}" "/clear" Enter
        sleep 3
        [ -n "$task_id" ] && [ "$task_id" != "0" ] && send_task "$window" "$task_id"
        watchdog_reset "$window"
    elif [ "$stale_count" -ge "$STALE_THRESHOLD" ]; then
        log "WATCHDOG [L1]: Enter a ventana $window"
        tmux send-keys -t "${TMUX_SESSION}:${window}" Enter
    fi
}

send_task() {
    local window=$1 task_id=$2
    local task_name; task_name=$(get_task_name "$task_id")
    local instruction; instruction=$(get_task_instruction "$task_id")
    [ -z "$instruction" ] && log "ERROR: No instrucción para tarea $task_id" && return 1
    echo "$instruction" | grep -qi "no uses subagentes" || instruction="IMPORTANTE: NO uses subagentes para web search, haz TODAS las búsquedas tú directamente. ${instruction}"
    log ">>> Enviando tarea $task_id ($task_name) a ventana $window"
    local tmp_file="/tmp/dispatch_task_${task_id}.txt"
    echo "$instruction" > "$tmp_file"
    tmux send-keys -t "${TMUX_SESSION}:${window}" "$(cat "$tmp_file")" Enter
    sleep 3
    tmux send-keys -t "${TMUX_SESSION}:${window}" Enter
    rm -f "$tmp_file"
    set_state "window_${window}_task" "$task_id"
    set_state "window_${window}_sent_at" "$(now_epoch)"
    watchdog_reset "$window"
    log "    Tarea $task_id despachada a ventana $window"
}

init_state() {
    echo "next_task=1" > "$STATE_FILE"
    echo "completed=" >> "$STATE_FILE"
    echo "failed=" >> "$STATE_FILE"
    for win in "${WORKER_WINDOWS[@]}"; do
        echo "window_${win}_task=0" >> "$STATE_FILE"
        echo "window_${win}_sent_at=0" >> "$STATE_FILE"
    done
    log "Estado inicializado (fresh start)"
}

main_loop() {
    local total_tasks; total_tasks=$(get_total_tasks)
    log "============================================================"
    log "DISPATCHER FIXES + MEJORAS INICIADO"
    log "Tareas: $total_tasks | Workers: ${#WORKER_WINDOWS[@]} | Intervalo: ${INTERVAL}s"
    log "============================================================"
    mkdir -p "$WATCHDOG_DIR"

    while true; do
        local active_count=0 now; now=$(now_epoch)
        for win in "${WORKER_WINDOWS[@]}"; do
            local current_task; current_task=$(get_state "window_${win}_task")
            if [ -n "$current_task" ] && [ "$current_task" != "0" ]; then
                local sent_at; sent_at=$(get_state "window_${win}_sent_at")
                local elapsed=$((now - sent_at))
                if is_task_done "$current_task"; then
                    local task_name; task_name=$(get_task_name "$current_task")
                    log "<<< COMPLETADA tarea $current_task ($task_name) en ventana $win (${elapsed}s)"
                    local completed; completed=$(get_state "completed")
                    set_state "completed" "${completed}${current_task},"
                    set_state "window_${win}_task" "0"
                    set_state "window_${win}_sent_at" "0"
                    watchdog_reset "$win"
                elif [ "$elapsed" -lt "$COOLDOWN_AFTER_SEND" ]; then
                    active_count=$((active_count + 1))
                elif ! is_session_idle "$win"; then
                    active_count=$((active_count + 1))
                    if ! watchdog_check "$win" > /dev/null 2>&1; then
                        local stale; stale=$(cat "$WATCHDOG_DIR/win_${win}_stale.txt" 2>/dev/null || echo "0")
                        try_unblock "$win" "$stale"
                    fi
                elif [ "$elapsed" -gt "$MIN_WORK_TIME" ]; then
                    local task_name; task_name=$(get_task_name "$current_task")
                    log "??? FALLO tarea $current_task ($task_name) en ventana $win (idle sin output, ${elapsed}s)"
                    local failed; failed=$(get_state "failed")
                    set_state "failed" "${failed}${current_task},"
                    set_state "window_${win}_task" "0"
                    set_state "window_${win}_sent_at" "0"
                    watchdog_reset "$win"
                    tmux send-keys -t "${TMUX_SESSION}:${win}" "/clear" Enter
                    sleep 3
                else
                    active_count=$((active_count + 1))
                fi
            fi
            current_task=$(get_state "window_${win}_task")
            if [ -z "$current_task" ] || [ "$current_task" = "0" ]; then
                if is_session_idle "$win"; then
                    local next; next=$(get_state "next_task")
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
        local completed_count; completed_count=$(get_state "completed" | tr ',' '\n' | grep -c '[0-9]' || echo "0")
        local failed_count; failed_count=$(get_state "failed" | tr ',' '\n' | grep -c '[0-9]' || echo "0")
        local next_pending; next_pending=$(get_state "next_task")
        log "--- STATUS: ${completed_count}/${total_tasks} completas | ${failed_count} fallidas | ${active_count} activas | Próxima: ${next_pending}"
        [ "$completed_count" -ge "$total_tasks" ] && log "=== TODAS LAS TAREAS COMPLETADAS ===" && break
        if [ "$next_pending" -gt "$total_tasks" ] 2>/dev/null && [ "$active_count" -eq 0 ]; then
            log "=== FIN: Completadas: $completed_count | Fallidas: $failed_count ===" && break
        fi
        sleep "$INTERVAL"
    done
}

echo $$ > "$PID_FILE"
init_state
main_loop
log "Dispatcher terminado (PID $$)"
rm -f "$PID_FILE"

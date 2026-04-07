# Reglas de Detección — Referencia Rápida

## ¿Tarea completada?
```bash
[ -f "$ruta_output" ] && [ -s "$ruta_output" ]
# Existe Y no está vacío → COMPLETADA
```
Esta es la fuente de verdad. No confiar en screen scraping.

## ¿Worker idle?
```bash
last_line=$(tmux capture-pane -t "0:${win}" -p -S -1 | grep -v '^$' | tail -1)
echo "$last_line" | grep -qE "❯\s*$"  # Prompt vacío → IDLE
```
Solo revisar la ÚLTIMA línea. Ignorar historial (contiene keywords que confunden).

## ¿Worker atorado?
```bash
# Captura actual
capture=$(tmux capture-pane -t "0:${win}" -p -S -5)
# Comparar con captura anterior (guardada en /tmp/dispatcher_watchdog/)
prev=$(cat "/tmp/dispatcher_watchdog/win_${win}.txt" 2>/dev/null)
if [ "$capture" = "$prev" ]; then
    stale_count=$((stale_count + 1))
fi
echo "$capture" > "/tmp/dispatcher_watchdog/win_${win}.txt"
# stale_count >= 15 ciclos (15 min con interval=60s) → ATORADO
```

## ¿Worker en cooldown?
```bash
sent_at=$(get_state "window_${win}_sent_at")
elapsed=$(($(date +%s) - sent_at))
[ "$elapsed" -lt 120 ]  # < 120s desde envío → EN COOLDOWN, no verificar
```

## ¿Tarea fallida?
```bash
# Idle + más de MIN_WORK_TIME + no existe output → FALLO
is_idle && [ "$elapsed" -gt 300 ] && ! [ -f "$ruta_output" ]
```

## Keywords de actividad (solo para referencia, NO usar como detección primaria)
```
Spinners activos: ✻ ✳ ✢ ✶ ✽
Fases Claude: Cooked, Brewed, Whirring, Cogitated
Herramientas: Web Search, Bash, Running, Writing, Reading
Estado: thinking, Thinking, still running, agent, tokens
Bloqueo: "Do you want", "Pasted text", "[Y/n]"
```

## Escalamiento de desbloqueo
```
15 min sin cambio → Enter
20 min sin cambio → /clear + Enter + reenviar tarea
30 min sin cambio → kill worker + restart Claude + reenviar
```

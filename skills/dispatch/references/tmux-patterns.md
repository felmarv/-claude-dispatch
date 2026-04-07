# Patrones tmux — Referencia Rápida

## Enviar instrucción a worker
```bash
# Escribir a temporal (evita problemas con caracteres especiales)
echo "$instruction" > /tmp/dispatch_task_${id}.txt

# Enviar
tmux send-keys -t "0:${window}" "$(cat /tmp/dispatch_task_${id}.txt)" Enter

# OBLIGATORIO: Enter adicional para "Pasted text"
sleep 3
tmux send-keys -t "0:${window}" Enter

# Cleanup
rm -f /tmp/dispatch_task_${id}.txt
```

## Capturar pantalla
```bash
# Última línea (para idle detection)
tmux capture-pane -t "0:${window}" -p -S -1

# Últimas 5 líneas (para watchdog)
tmux capture-pane -t "0:${window}" -p -S -5

# Todo el pane visible
tmux capture-pane -t "0:${window}" -p
```

## Verificar si Claude corre en una ventana
```bash
pane_cmd=$(tmux list-panes -t "0:${window}" -F "#{pane_current_command}" 2>/dev/null)
echo "$pane_cmd" | grep -q "node"  # Claude = node process
```

## Crear worker nuevo
```bash
# Crear ventana
tmux new-window -t "0:${window}" 2>/dev/null
sleep 2

# Lanzar Claude
tmux send-keys -t "0:${window}" "claude" Enter
sleep 15  # Esperar a que arranque completamente
```

## Destruir worker
```bash
tmux kill-window -t "0:${window}" 2>/dev/null
```

## Listar ventanas
```bash
tmux list-windows -t 0 -F "#{window_index}: #{window_name}"
```

## Identificar ventana del coordinador
```bash
# El coordinador es la ventana donde corre ESTA sesión
# Obtener el window index actual
tmux display-message -p '#{window_index}'
# Excluir este número de los workers disponibles
```

## Enviar /clear a un worker
```bash
tmux send-keys -t "0:${window}" "/clear" Enter
sleep 3  # Esperar a que procese
```

## Convenciones
- Session: siempre "0" (la session tmux principal)
- Windows: números enteros (0, 1, 2, 3...)
- Formato target: "0:N" donde N es el window index
- Workers disponibles: todas las ventanas con Claude EXCEPTO la del coordinador

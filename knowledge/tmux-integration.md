# Integración con tmux — Envío de Comandos a Claude

## Contexto

El dispatcher envía instrucciones a sesiones de Claude Code que corren en ventanas de tmux. tmux permite enviar keystrokes a cualquier pane, lo que nos permite "escribir" en la terminal de Claude como si fuera un usuario.

## Comandos clave de tmux

### Enviar texto a una ventana
```bash
# Enviar texto + Enter a ventana 2 de session 0
tmux send-keys -t "0:2" "texto aquí" Enter

# Enviar solo Enter (para confirmar Pasted text)
tmux send-keys -t "0:2" Enter
```

### Capturar contenido de pantalla
```bash
# Últimas 3 líneas
tmux capture-pane -t "0:2" -p -S -3

# Todo el pane visible
tmux capture-pane -t "0:2" -p
```

### Listar ventanas y panes
```bash
# Listar ventanas de session 0
tmux list-windows -t 0

# Ver qué proceso corre en cada pane
tmux list-panes -t "0:2" -F "#{pane_current_command}"
```

### Crear y destruir ventanas
```bash
# Crear ventana 6 en session 0
tmux new-window -t "0:6"

# Destruir ventana 6
tmux kill-window -t "0:6"
```

## Problema: "Pasted text"

Cuando se envía texto largo vía `tmux send-keys`, Claude Code lo detecta como texto pegado y muestra:

```
❯ Pasted text #1 (2847 chars)
```

**No se ejecuta automáticamente.** Requiere un Enter adicional para confirmar.

### Solución

```bash
# Enviar instrucción
tmux send-keys -t "0:2" "$instruction" Enter

# Esperar 2-3 segundos
sleep 2

# Enviar Enter adicional para confirmar el paste
tmux send-keys -t "0:2" Enter
```

El `sleep 2` es necesario porque Claude tarda un momento en procesar el texto pegado. Sin el delay, el Enter llega antes de que Claude muestre el "Pasted text" y se pierde.

## Problema: Archivo temporal para texto largo

El shell puede tener problemas con instrucciones muy largas en `tmux send-keys`. Solución: escribir a archivo temporal y usar `cat`:

```bash
# Escribir instrucción a archivo temporal
echo "$instruction" > /tmp/dispatcher_task_${id}.txt

# Enviar contenido
tmux send-keys -t "0:2" "$(cat /tmp/dispatcher_task_${id}.txt)" Enter

# Cleanup
rm -f /tmp/dispatcher_task_${id}.txt
```

## Problema: Texto residual de sesión muerta

Si se mata Claude con `kill -9`, el pane mantiene el texto de la sesión anterior. Esto confunde al dispatcher.

### Soluciones
1. **Limpiar el pane**: `tmux send-keys -t "0:2" /clear Enter` (solo funciona si Claude está corriendo)
2. **Recrear la ventana**: `tmux kill-window -t "0:2" && tmux new-window -t "0:2"`
3. **Lanzar Claude nuevo**: Después de recrear, `tmux send-keys -t "0:2" "claude" Enter`

## Flujo completo: send_task()

```bash
send_task() {
    local window=$1
    local task_id=$2
    local instruction=$(get_task_instruction "$task_id")
    
    # 1. Escribir a archivo temporal
    echo "$instruction" > /tmp/dispatcher_task_${task_id}.txt
    
    # 2. Enviar a tmux
    tmux send-keys -t "0:${window}" "$(cat /tmp/dispatcher_task_${task_id}.txt)" Enter
    
    # 3. Cleanup temporal
    rm -f /tmp/dispatcher_task_${task_id}.txt
    
    # 4. Enter adicional para "Pasted text" (con delay)
    sleep 2
    tmux send-keys -t "0:${window}" Enter
    
    # 5. Registrar en state
    set_state "window_${window}_task" "$task_id"
    set_state "window_${window}_sent_at" "$(now_epoch)"
}
```

## Setup de workers

```bash
# Verificar si Claude corre en una ventana
pane_cmd=$(tmux list-panes -t "0:${win}" -F "#{pane_current_command}")
# Claude Code = proceso node
if echo "$pane_cmd" | grep -q "node"; then
    echo "Claude ya corriendo"
fi
```

El proceso de Claude Code aparece como `node` en tmux.

## Nomenclatura de ventanas

- **Session**: `0` (la session tmux principal)
- **Window**: número entero (0, 1, 2, 3, 4, 5...)
- **Convención**: Window 3 = coordinador, las demás = workers disponibles
- **available_windows**: array con los índices disponibles para workers (excluye coordinador)

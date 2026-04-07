# Detección de Idle en Claude Code vía tmux

## El problema

Necesitamos saber cuándo un worker de Claude terminó de trabajar y está listo para recibir nueva tarea. Claude Code corre dentro de un pane de tmux, así que la única forma de observar su estado es capturar el contenido de la pantalla.

## Cómo capturar la pantalla

```bash
# Capturar últimas 3 líneas del pane
tmux capture-pane -t "0:${window}" -p -S -3

# Capturar últimas 10 líneas
tmux capture-pane -t "0:${window}" -p -S -10

# Capturar todo el pane visible
tmux capture-pane -t "0:${window}" -p
```

`-p` envía a stdout en lugar de al paste buffer.
`-S -N` empieza N líneas antes del final.

## Indicadores de estado

### Claude está IDLE cuando:
- La última línea no vacía contiene `❯`
- Después del `❯` no hay texto (prompt vacío)
- No hay "Pasted text" en la línea (texto pegado sin ejecutar)

### Claude está TRABAJANDO cuando:
- Aparecen spinners: `✻`, `✳`, `✢`, `✶`, `✽`
- Aparecen keywords en las últimas líneas:
  - `Cooked`, `Brewed`, `Whirring`, `Cogitated` (fases de Claude)
  - `Running`, `still running` (comandos en ejecución)
  - `Writing`, `Reading` (operaciones de archivo)
  - `Thinking`, `thinking` (procesamiento)
  - `Web Search`, `Bash` (herramientas activas)
  - `agent`, `tokens` (subagentes o conteo)

### Claude está ATORADO cuando:
- Muestra "Pasted text" o "Pasted text #N" sin ejecutar
- Muestra "Do you want to proceed?" esperando input
- La pantalla no ha cambiado en >15 minutos

## Implementación actual (V2)

```bash
is_session_idle() {
    local window=$1
    local last_lines
    last_lines=$(tmux capture-pane -t "0:${window}" -p -S -3 2>/dev/null)
    
    local last_line
    last_line=$(echo "$last_lines" | grep -v '^$' | tail -1)
    
    # Tiene ❯ + no hay keywords de actividad + no hay Pasted text + prompt vacío
    if echo "$last_line" | grep -q "❯" && \
       ! echo "$last_lines" | grep -qiE "(Cooked|Brewed|...)" && \
       ! echo "$last_line" | grep -qE "\[Pasted" && \
       echo "$last_line" | grep -qE "❯\s*$"; then
        return 0  # idle
    fi
    return 1  # no idle
}
```

## Problemas conocidos

### 1. Output largo contamina la detección (Bug 9)
Cuando Claude termina y muestra un resumen largo, keywords como "Writing" aparecen en el historial visible. La función revisa las últimas 3 líneas y los encuentra.

**Fix propuesto:** Solo revisar la ÚLTIMA línea. Si es `❯` vacío → idle, sin importar qué digan las líneas anteriores.

### 2. Comparación temporal (más robusta)
Capturar la pantalla dos veces con 10s de diferencia. Si no cambió y tiene `❯` → idle.

```bash
is_truly_idle() {
    local capture1=$(tmux capture-pane -t "0:$1" -p -S -5)
    sleep 10
    local capture2=$(tmux capture-pane -t "0:$1" -p -S -5)
    if [ "$capture1" = "$capture2" ] && echo "$capture2" | tail -1 | grep -qE "❯\s*$"; then
        return 0
    fi
    return 1
}
```

### 3. "Pasted text" no siempre dice "Pasted"
A veces el texto pegado simplemente aparece en la línea de input sin etiqueta. Difícil de distinguir de texto que el usuario está escribiendo.

## Recomendaciones para el skill

1. **Usar comparación temporal** como método principal (más confiable que keywords)
2. **Revisar solo la última línea** para el prompt `❯`
3. **Ignorar las líneas anteriores** — contienen output histórico que confunde
4. **Implementar watchdog** — si nada cambia en 15 min, es sospechoso

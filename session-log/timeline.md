# Timeline — Sesión de Construcción del Dispatcher

**Fecha:** 6 de abril de 2026 (sábado noche → domingo madrugada)
**Objetivo:** Despachar 13 investigaciones DOMINEUM en paralelo
**Resultado:** 7+ completadas, sistema funcional con 11 bugs documentados

---

## Cronología

### ~16:00 — Setup inicial
- Felipe arranca con la idea de paralelizar las investigaciones DOMINEUM
- 5 sesiones Claude Code ya corriendo en la Mac Mini
- Se decide usar tmux para coordinar

### ~16:30 — Dispatcher V1
- Primer script `dispatcher.sh` creado
- Formato de tasks.txt definido: `ID|TIPO|NOMBRE|RUTA|INSTRUCCION`
- 13 tareas escritas: 6 estados MX + 6 países + 1 consolidado
- Se lanzan 4 workers (ventanas tmux 1, 2, 4, 5)

### ~17:00 — Primeros bugs
- **Bug 1** detectado: detección prematura de idle
- **Bug 2** detectado: /clear + instrucción separados causan falso idle
- Se implementa cooldown de 120s después de enviar

### ~17:30 — Dispatcher V2
- Reescritura completa del script
- Estado persistente con `state_v2.txt`
- Cooldown + min_work_time implementados
- Se relanza con las primeras tareas ya en progreso

### ~18:00 — Tareas completando
- Tarea 3 (Querétaro) completada — primer .docx generado
- Tareas 1 (Jalisco) y 2 (Nuevo León) completan poco después
- **Bug 4 y 7** detectados: "Pasted text" no se ejecuta, necesita Enter

### ~18:30 — Bug 10 (el costoso)
- Workers 2, 4 y 5 terminaron tareas pero quedaron idle con "Pasted text" en buffer
- El dispatcher los veía como "activos" por el texto en pantalla
- **~1 hora perdida** antes de que Felipe preguntara por el status
- Se identifica la necesidad del watchdog

### ~19:00 — Recovery manual
- Felipe interviene manualmente, envía Enter a workers atorados
- Workers retoman trabajo
- Tarea 7 (Perú) completa

### ~19:15 — State fix
- Se ajusta state_v2.txt manualmente para reflejar las tareas completadas fuera del dispatcher
- completed=1,2,3,4,5,6,7
- Se relanza dispatcher para las tareas restantes (8-13)

### ~19:30 — Segundo round
- Tareas 8-12 (países) en progreso
- Tarea 13 (consolidado) esperando a que 1-6 estén listas (ya lo están)

### ~20:00 — Transición a knowledge
- Felipe pide empaquetar todo el conocimiento en carpeta de plugins
- Se crea plan `mighty-brewing-swan` para la carpeta dispatch
- La sesión s003 empieza a trabajar en esto...

### ~20:30 — Sesión s003 se traba
- La sesión que estaba creando la carpeta de knowledge deja de responder
- 0% CPU, no reacciona
- El trabajo queda pendiente

### 2026-04-06 ~11:00 — Retomado en sesión s007
- Felipe detecta que s003 no responde
- Se retoma el trabajo en esta sesión (la de SICAR)
- Se crea la carpeta plugins/dispatch/ con toda la documentación

---

## Métricas de la sesión

| Métrica | Valor |
|---------|-------|
| Tareas totales | 13 |
| Completadas (confirmadas) | 7+ (estados 1-6 + Perú) |
| Workers simultáneos | 4 |
| Duración total | ~4 horas |
| Tiempo perdido por bugs | ~1.5 horas (Bug 10 + debugging) |
| Bugs encontrados | 11 |
| Bugs resueltos en V2 | 8 |
| Bugs pendientes | 3 (Bug 10 watchdog, Bug 9 parcial, Bug 11 trade-off) |

## Lecciones clave

1. **El watchdog es indispensable** — Sin él, workers atorados pasan desapercibidos
2. **File exists es la mejor detección** — Más confiable que screen scraping
3. **tmux send-keys + Pasted text** es la fuente #1 de problemas
4. **Estado persistente es crítico** — Poder relanzar sin perder progreso
5. **Los subagentes de Claude no heredan permisos** — Prohibirlos en la instrucción
6. **4 workers es el sweet spot** — Con 8 GB RAM no caben más

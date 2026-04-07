# Bugs Encontrados — Dispatcher V1 y V2

11 bugs documentados durante la sesión de construcción y pruebas (6 de abril 2026).
Cada bug incluye: qué pasó, por qué, y cómo se resolvió.

---

## Bug 1: Detección prematura de idle

**Síntoma:** Después de enviar tarea, el dispatcher detectaba al worker como idle y le mandaba otra tarea encima.

**Causa raíz:** Claude muestra el prompt `❯` brevemente mientras procesa el `/clear` o el texto pegado. El dispatcher lo veía y asumía que estaba libre.

**Solución:** Agregar `COOLDOWN_AFTER_SEND` (120 segundos) después de cada envío. No verificar idle durante ese periodo.

---

## Bug 2: /clear + instrucción como pasos separados

**Síntoma:** Al enviar `/clear` y luego la instrucción en dos comandos tmux, Claude mostraba `❯` vacío entre ambos. El dispatcher lo detectaba como idle.

**Causa raíz:** Dos `tmux send-keys` secuenciales crean un momento intermedio donde el prompt queda limpio.

**Solución V2:** Enviar instrucción directamente sin `/clear` previo. El worker la procesa sobre el contexto existente.

---

## Bug 3: init_state sobreescribe estado existente

**Síntoma:** Al relanzar el dispatcher (después de un kill o ajuste), todo el progreso se perdía. Empezaba desde tarea 1.

**Causa raíz:** `init_state()` siempre creaba un archivo `state_v2.txt` nuevo.

**Solución:** Verificar si el archivo existe y tiene contenido antes de sobreescribir. Si existe, cargar el estado.

---

## Bug 4: Texto en buffer de tmux no se ejecuta

**Síntoma:** La instrucción se pegaba en la línea de input de Claude pero no se ejecutaba. Quedaba como texto inerte.

**Causa raíz:** `tmux send-keys` con texto largo lo pega en modo "Pasted text" que requiere confirmación adicional.

**Solución:** Enviar un `Enter` adicional después de cada `tmux send-keys ... Enter`.

---

## Bug 5: Subagentes no heredan permisos de web search

**Síntoma:** Aunque `bypassPermissions` está en la config, los subagentes de Claude pedían permiso para cada Web Search, bloqueando el worker.

**Causa raíz:** Los permisos se aplican al proceso principal de Claude, no a los subagentes que lanza internamente.

**Solución:** Incluir en la instrucción: "IMPORTANTE: NO uses subagentes para web search, haz TODAS las búsquedas tú directamente".

---

## Bug 6: Texto residual de sesión muerta

**Síntoma:** Después de matar un proceso Claude con `kill -9`, el pane de tmux conservaba el texto de la sesión anterior. El dispatcher veía keywords como "Do you want to proceed" y se confundía.

**Causa raíz:** `kill -9` termina el proceso pero tmux mantiene el contenido del pane intacto.

**Solución:** Hacer `tmux send-keys -t 0:X /clear Enter` o verificar que el prompt pertenece a un Claude activo (no texto viejo). Alternativamente, destruir y recrear la ventana tmux.

---

## Bug 7: "Pasted text" necesita Enter adicional

**Síntoma:** Instrucciones largas quedaban como "Pasted text #N" en la línea de input de Claude sin ejecutarse. Los workers esperaban indefinidamente.

**Causa raíz:** Claude Code interpreta texto largo pegado como "Pasted text" y lo muestra como preview. Necesita un Enter para confirmar.

**Solución:** En `send_task()`, después de `tmux send-keys ... Enter`, hacer `sleep 2 && tmux send-keys -t 0:X Enter`. El delay de 2-3 segundos es necesario para que Claude procese el paste.

---

## Bug 8: No trackea tareas asignadas fuera del dispatcher

**Síntoma:** Tareas enviadas manualmente o por el dispatcher v1 no aparecían en el state del v2. Las ventanas estaban trabajando pero el dispatcher las veía como `task=0`. Cuando terminaban, no se les asignaba nueva tarea.

**Causa raíz:** El dispatcher solo conoce las tareas que él mismo envió. Si una ventana recibió tarea por otro medio, queda invisible.

**Solución:** El dispatcher verifica independientemente si una ventana está idle, sin depender solo de su state. Si `task=0` y está idle → asignar. Si `task=0` y está ocupada → dejar.

---

## Bug 9: Detección de idle falla con output largo

**Síntoma:** Claude terminaba una tarea y mostraba un resumen largo ("Documento generado con 11 secciones..."). La pantalla tenía keywords como "Writing", "Bash", "Web Search" en el historial. El dispatcher pensaba que seguía activa.

**Causa raíz:** `is_session_idle()` revisaba las últimas N líneas y encontraba keywords de actividad del output anterior.

**Solución:** Solo revisar la ÚLTIMA línea no vacía. Si es `❯` vacío → idle, punto. Las keywords de actividad solo deben buscarse en líneas con spinners activos (`✻`, `✳`, `✢`, etc.). Alternativa: comparar dos capturas separadas por 10s — si la pantalla no cambió y tiene `❯`, está idle.

---

## Bug 10: No detecta sesiones atoradas (el más costoso)

**Síntoma:** Las sesiones 2, 4 y 5 terminaron tareas y quedaron idle con "Pasted text" en buffer sin ejecutar. El dispatcher las veía como "activas". Pasó **1 HORA** sin que nadie detectara el problema.

**Causa raíz:** El dispatcher no tiene mecanismo de watchdog. Solo verifica idle/ocupado/completado pero no detecta "sin cambios por mucho tiempo". No puede distinguir entre "trabajando" y "atorado con output viejo".

**Solución propuesta (no implementada en v2):** Watchdog que compare capturas de pantalla cada ciclo. Si una ventana no cambió en 15 minutos → alerta. Opciones: (1) escribir archivo de alerta, (2) enviar Enter como intento de desbloqueo, (3) notificar vía Asana/email.

**Impacto:** ~1 hora de 3 workers idle = ~3 horas-worker perdidas.

---

## Bug 11: Enviar tarea a ventana con conversación existente

**Síntoma:** Al asignar una nueva tarea a un worker que ya tenía una conversación larga, Claude procesaba la nueva instrucción CON el contexto anterior, lo cual: (a) consumía más tokens, (b) potencialmente contaminaba la respuesta.

**Causa raíz:** V2 eliminó el `/clear` previo (para evitar Bug 2) pero eso dejó el contexto anterior vivo.

**Solución:** Trade-off. Opciones: (a) Aceptar el contexto anterior (riesgo bajo para tareas independientes), (b) Enviar `/clear` con timeout suficiente, (c) Destruir y recrear la ventana tmux completa entre tareas.

---

## Resumen de severidad

| Bug | Severidad | Resuelto en V2 | Impacto real |
|-----|-----------|-----------------|--------------|
| 1 | Alta | Sí (cooldown) | Workers recibían tareas dobles |
| 2 | Media | Sí (sin /clear) | Prompt falso confundía detector |
| 3 | Alta | Sí (check exists) | Progreso perdido al reiniciar |
| 4 | Alta | Parcial (Enter extra) | Workers atorados esperando |
| 5 | Media | Workaround (instrucción) | Workers bloqueados en permisos |
| 6 | Baja | Manual (recrear ventana) | Confusión de estado |
| 7 | Alta | Sí (sleep + Enter) | Workers atorados indefinidamente |
| 8 | Media | Sí (check idle independiente) | Workers idle sin nueva tarea |
| 9 | Alta | Parcial (mejorar regex) | Workers idle sin detectar |
| 10 | **Crítica** | **No** | **~3 horas-worker perdidas** |
| 11 | Baja | Trade-off aceptado | Contexto contaminado (bajo riesgo) |

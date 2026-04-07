# /dispatch — Sistema de Despacho Automático de Tareas entre Sesiones Claude

## Qué es

Sistema que permite a una sesión coordinadora de Claude Code despachar tareas a múltiples sesiones worker corriendo en tmux. Cada worker ejecuta una tarea independiente (investigación + generación de documento) mientras el dispatcher monitorea y asigna la siguiente tarea cuando un worker se libera.

## Para qué sirve

- Investigaciones masivas en paralelo (ej: análisis de viabilidad de 6 estados + 6 países)
- Generación de documentos en batch (cada worker produce un .docx)
- Cualquier workload de Claude Code que sea paralelizable y tenga output verificable

## Caso de uso real

**DOMINEUM — 13 tareas despachadas en paralelo:**
- 6 análisis de viabilidad por estado mexicano (Jalisco, NL, Querétaro, EdoMex, Puebla, Guanajuato)
- 6 análisis de viabilidad por país (Perú, RD, Ecuador, Argentina, España, Brasil)
- 1 documento consolidado (dependía de los 6 estados)
- 4 workers simultáneos en tmux
- Resultado: 13 documentos .docx generados en ~3 horas (vs ~13 horas secuencialmente)

## Componentes

| Componente | Archivo | Función |
|------------|---------|---------|
| Cola de tareas | `tasks.txt` | Lista de tareas con formato `ID\|TIPO\|NOMBRE\|RUTA_DOCX\|INSTRUCCION` |
| Script dispatcher | `dispatcher_v2.sh` | Loop principal: monitorea, detecta completación, asigna tareas |
| Estado persistente | `state_v2.txt` | Trackea progreso: próxima tarea, completadas, asignación por ventana |
| Bitácora | `dispatcher_v2.log` | Log timestamped de todo: envíos, completaciones, status |

## Cómo funciona

```
1. El dispatcher lee tasks.txt
2. Identifica ventanas tmux con Claude corriendo (workers)
3. Envía la primera tarea disponible a cada worker vía tmux send-keys
4. Cada 60 segundos:
   a. Verifica si algún worker completó su tarea (¿existe el .docx?)
   b. Si completó → marca como libre → asigna siguiente tarea
   c. Si está idle sin .docx después de 5 min → marca como fallo
   d. Logea status
5. Repite hasta que todas las tareas se completen
```

## Uso

```bash
# Ejecutar con defaults (60s intervalo, 4 workers)
./dispatcher_v2.sh

# Personalizar
./dispatcher_v2.sh 30 6  # 30s intervalo, 6 workers

# Ver progreso en tiempo real
tail -f dispatcher_v2.log
```

## Estado actual

- **V2** — funcional con 11 bugs documentados y resueltos/mitigados
- **No es skill todavía** — es un script bash que se ejecuta manualmente
- **Próximo paso** — convertir en skill `/dispatch` de Claude Code

## Archivos de referencia

- `knowledge/` — documentación técnica de cada componente
- `session-log/` — timeline de la sesión donde se construyó y probó
- `future/` — diseño propuesto para el skill `/dispatch`
- `BUGS.md` — los 11 bugs encontrados con causas raíz y soluciones
- `ARCHITECTURE.md` — diagrama y flujo completo del sistema

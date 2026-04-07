# Diseño del Skill /dispatch

## Visión

Convertir el dispatcher bash en un skill nativo de Claude Code que cualquier sesión pueda invocar para despachar trabajo en paralelo a múltiples sesiones tmux.

## Comandos

```bash
/dispatch run tasks.txt              # Lanzar dispatcher con archivo de tareas
/dispatch run tasks.txt --workers 6  # Especificar número de workers
/dispatch run tasks.txt --interval 30  # Intervalo de monitoreo en segundos

/dispatch status                     # Ver progreso en tiempo real
/dispatch stop                       # Detener el dispatcher
/dispatch retry 5                    # Reintentar tarea 5
/dispatch retry --failed             # Reintentar todas las fallidas
/dispatch logs                       # Ver últimas líneas del log
/dispatch logs --tail 50             # Últimas 50 líneas
```

## Inputs

### Archivo de tareas (obligatorio)
Mismo formato `ID|TIPO|NOMBRE|RUTA_OUTPUT|INSTRUCCION`.
Mejora: soportar YAML o JSON como alternativa al pipe-delimited.

```yaml
# tasks.yaml (formato alternativo)
tasks:
  - id: 1
    name: Jalisco
    type: estado
    output: /ruta/a/output.docx
    instruction: |
      Investiga Jalisco como plaza para DOMINEUM...
    depends_on: []
    
  - id: 13
    name: Nacional
    type: consolidado
    output: /ruta/a/consolidado.docx
    instruction: |
      Lee los documentos 1-6 y consolida...
    depends_on: [1, 2, 3, 4, 5, 6]
```

### Opciones
| Flag | Default | Descripción |
|------|---------|-------------|
| `--workers` | 4 | Número de workers |
| `--interval` | 60 | Segundos entre ciclos |
| `--timeout` | 3600 | Timeout por tarea (seconds) |
| `--retry` | 0 | Intentos de retry automático |
| `--notify` | none | Notificar al completar: `asana`, `email`, `none` |
| `--cleanup` | false | Destruir ventanas tmux al terminar |

## Mejoras sobre V2

### 1. DAG de dependencias real
No hardcoded. El archivo de tareas define `depends_on` por tarea. El dispatcher resuelve el grafo y despacha respetando el orden.

```
Tarea 13 depends_on: [1, 2, 3, 4, 5, 6]
→ No se asigna hasta que 1-6 tengan .docx
```

### 2. Retry automático con backoff
```
Intento 1: ejecutar normal
Intento 2: /clear + ejecutar (contexto limpio)
Intento 3: kill + restart Claude + ejecutar
```
Backoff: 0s, 30s, 120s entre intentos.

### 3. Watchdog integrado
Comparación temporal de capturas cada ciclo. Alerta si una ventana no cambia en 15 minutos. Desbloqueo automático escalado (Enter → /clear → kill/restart).

### 4. Detección de completación mejorada
- **Nivel 1**: File exists (actual) — `[ -f output.docx ]`
- **Nivel 2**: File size check — `[ -s output.docx ]` (no vacío)
- **Nivel 3**: Content validation — verificar que tiene contenido real (no solo headers)
- **Nivel 4**: Custom validator — script que el usuario define

### 5. Notificaciones
Al completar todas las tareas (o al fallar):
- Asana: crear tarea con resumen en proyecto "Mac Mini"
- Email: enviar resumen vía Gmail MCP
- Archivo: escribir `/tmp/dispatch_complete.txt`

### 6. Auto-scaling por RAM
```bash
# Verificar RAM disponible
available_mb=$(vm_stat | awk '/Pages free/ {print $3 * 4096 / 1048576}')
max_workers=$((available_mb / 300))  # ~300MB por Claude session
```
Si la RAM es insuficiente para N workers, reducir automáticamente y avisar.

### 7. Dashboard de progreso
Output de `/dispatch status`:
```
DISPATCH STATUS — 7/13 tareas completadas (53%)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 53%

Workers: 4 activos | RAM: 3.2 GB / 8 GB

ID  Nombre          Estado      Worker  Tiempo   Output
1   Jalisco         ✅ completa  W2      8m 23s   ✓ 48KB
2   Nuevo León      ✅ completa  W4      9m 11s   ✓ 52KB
3   Querétaro       ✅ completa  W5      7m 45s   ✓ 41KB
4   EdoMex          ✅ completa  W1      10m 2s   ✓ 55KB
5   Puebla          ✅ completa  W2      8m 56s   ✓ 44KB
6   Guanajuato      ✅ completa  W4      9m 30s   ✓ 47KB
7   Perú            ✅ completa  W5      12m 15s  ✓ 38KB
8   R. Dominicana   ⚡ activa    W1      6m 22s   ...
9   Ecuador         ⚡ activa    W2      5m 44s   ...
10  Argentina       ⚡ activa    W4      4m 11s   ...
11  España          ⚡ activa    W5      3m 08s   ...
12  Brasil          ⏳ pendiente  -       -        -
13  Nacional        🔒 bloqueada  -       -        espera 1-6
```

### 8. Limpieza al terminar
```bash
/dispatch cleanup   # Destruir ventanas tmux de workers
                    # Limpiar archivos temporales
                    # Archivar logs
```

### 9. Template de instrucciones
Permitir variables en las instrucciones:
```
INSTRUCCION: Investiga {{NOMBRE}} como plaza para DOMINEUM. Guarda en: {{RUTA_DOCX}}
```
El dispatcher reemplaza `{{NOMBRE}}` y `{{RUTA_DOCX}}` automáticamente.

## Estructura del Skill

```
plugins/dispatch/
├── SKILL.md              # Definición del skill para Claude Code
├── README.md             # Documentación general
├── BUGS.md               # Bugs conocidos
├── ARCHITECTURE.md       # Diagrama y flujo
├── knowledge/            # Conocimiento técnico
│   ├── idle-detection.md
│   ├── tmux-integration.md
│   ├── task-format.md
│   ├── watchdog-design.md
│   ├── dispatcher_v2.sh  # Script de referencia
│   └── tasks-example.txt # Ejemplo de tareas
├── session-log/          # Historia de desarrollo
│   └── timeline.md
└── future/               # Este archivo
    └── skill-design.md
```

## Prioridad de implementación

1. **P0 — Watchdog** (Bug 10 es el más costoso)
2. **P0 — Retry automático** (hoy se pierden tareas fallidas)
3. **P1 — DAG de dependencias** (hoy es hardcoded)
4. **P1 — Status dashboard** (hoy es solo logs)
5. **P2 — Notificaciones** (calidad de vida)
6. **P2 — Auto-scaling RAM** (seguridad)
7. **P3 — Content validation** (nice to have)
8. **P3 — Template variables** (conveniencia)

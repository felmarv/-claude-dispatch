# Formato de Tareas — tasks.txt

## Estructura

```
ID|TIPO|NOMBRE|RUTA_DOCX|INSTRUCCION
```

Cada línea es una tarea. Delimitador: `|` (pipe).

## Campos

| Campo | Tipo | Descripción | Ejemplo |
|-------|------|-------------|---------|
| ID | int | Secuencial, único | `1`, `2`, `13` |
| TIPO | string | Categoría para agrupar | `estado`, `pais`, `consolidado` |
| NOMBRE | string | Nombre corto para logs | `Jalisco`, `Perú` |
| RUTA_DOCX | path | Ruta completa del output esperado | `/Users/admin/.../output.docx` |
| INSTRUCCION | string | Prompt completo para Claude | `Investiga Jalisco como plaza...` |

## Reglas

- Líneas que empiezan con `#` son comentarios
- Líneas vacías se ignoran
- RUTA_DOCX se usa para detección de completación: `[ -f "$docx_path" ]`
- INSTRUCCION debe ser **autocontenida** — Claude no tiene contexto previo
- No usar `|` dentro de la instrucción (rompe el parsing con `cut -d'|'`)
- Incluir en la instrucción: "NO uses subagentes para web search" (Bug 5)

## Ejemplo Real

```
# Estados mexicanos
1|estado|Jalisco|/Users/admin/Google Drive/Mi unidad/DOMINEUM/DOMINEUM JALISCO/DOMINEUM JALISCO - Analisis de Viabilidad.docx|Investiga Jalisco (Guadalajara) como plaza para DOMINEUM...

# Países
7|pais|Perú|/Users/admin/Google Drive/Mi unidad/DOMINEUM/DOMINEUM INTERNACIONAL/DOMINEUM PERU/GDP Viabilidad Peru.docx|Investiga Perú como país para expandir GDP...

# Tarea con dependencia (espera a 1-6)
13|consolidado|Nacional|/Users/admin/Google Drive/Mi unidad/DOMINEUM/ESTRUCTURA DOMINEUM/DOMINEUM Analisis Expansion Nacional.docx|TAREA FINAL - Solo ejecutar cuando las tareas 1-6 estén completas...
```

## Tips para escribir buenas instrucciones

1. **Ser explícito sobre el output**: "Genera un .docx profesional y guarda en: /ruta/..."
2. **Incluir toda la info necesaria**: Claude no sabe qué es DOMINEUM si no se lo dices
3. **Prohibir subagentes**: "IMPORTANTE: NO uses subagentes para web search"
4. **Especificar estructura**: "Con secciones: resumen ejecutivo, análisis, conclusión..."
5. **Ser específico sobre la ruta de guardado**: Debe coincidir exactamente con RUTA_DOCX

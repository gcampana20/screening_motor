# AGENTS.md — Guía para agentes de IA en este repo

> Este archivo es el punto de entrada para **cualquier agente** (Claude Code,
> Cursor, Codex, Windsurf, Copilot Workspace, etc.) que vaya a leer o
> modificar este repo. Cargalo antes de tocar archivos.

El proyecto es un **motor de screening de compliance** sobre PostgreSQL 17.
Multi-tenant, fuzzy matching, validación de tax IDs país-específica,
alertas ponderadas. Ver `README.md` para el overview de producto.

---

## Principios de trabajo

1. **Propone antes de implementar.** Si la tarea implica ≥2 archivos o una
   decisión de diseño, describí primero el enfoque (en 3-8 líneas) y esperá
   confirmación. No desperdicies tokens/cycles escribiendo código que el
   humano va a descartar.
2. **Idempotencia siempre.** Toda migración debe poder re-correrse sin
   errores ni side effects. Patrón: `DROP ... IF EXISTS` + `CREATE ... OR REPLACE`,
   o `DO` blocks con `IF EXISTS ... THEN ALTER`. Nunca asumir estado previo.
3. **Transaccionalidad.** Cada archivo `.sql` va envuelto en
   `BEGIN ... COMMIT`. Si falla, rollback completo.
4. **Comentarios = rationale, no descripción.** El SQL dice *qué*; el comment
   dice *por qué* y qué alternativa fue rechazada. Ejemplo bueno:
   `-- DO block con check de tipo actual porque ALTER COLUMN TYPE no es
   idempotente si el tipo destino ya aplica.`
   Ejemplo malo: `-- Altera la columna.`
5. **Tests por migración.** Cada `V###__foo.sql` viene con
   `migrations/tests/test_V###__foo.sql`. Tests envueltos en
   `BEGIN ... ROLLBACK` para no dejar residuo.
6. **No editar migraciones aplicadas.** Si V009 está en producción, los
   arreglos van en V011, no reescribiendo V009. Excepción: comentarios
   puros (no-SQL-semántico).

---

## Convenciones de naming

- Migraciones: `V<NNN>__<snake_case>.sql`, numeración estricta y secuencial.
- Tests: `migrations/tests/test_V<NNN>__<snake_case>.sql`, 1-a-1 con la
  migración.
- Funciones SQL: `public.verbo_objeto` (e.g. `run_screening`,
  `calculate_similarity`, `validate_tax_id`).
- Parámetros PL/pgSQL: prefijo `p_` (`p_entity_id`, `p_country`).
- Variables PL/pgSQL locales: prefijo `v_` (`v_normalized`, `v_category`).
- Constraints explícitos: `<tabla>_<check_short_name>_check` o
  `<tabla>_<col>_fkey`.
- JSONB keys: `snake_case` en inglés (matching industry standard).

---

## Estructura mental del schema

El **hot path** del motor es:

```
tenant → person/company → calculate_similarity → screening_list_entry → alert
```

Cualquier cambio que toque este path necesita evaluar impacto en:

1. **Índices** — los queries de matching son GIN trigram + B-tree
   compuesto. Tocar columnas normalizadas = re-evaluar índices.
2. **RLS policies** — cualquier tabla nueva necesita policy de
   `tenant_id = current_tenant_id()`. Ver `V004__rls_policies.sql`.
3. **search_path en SECURITY DEFINER** — si la función nueva hace
   INSERT/UPDATE en `alert` o tablas sensibles, va con
   `SECURITY DEFINER` + `SET search_path = pg_catalog, public`.
4. **Tests V009/V010** — casi cualquier cambio invalida algún test.
   Correr tests después de cada migración.

---

## Dominio: cosas que todo agente debe saber

### Conceptos de compliance screening

- **Tipos de lista:** `SANCTIONS` (OFAC, UN — falso negativo = multa),
  `PEP` (políticamente expuestos), `ADVERSE_MEDIA` (cobertura negativa),
  `INTERNAL` (blacklist propia del tenant).
- **Jurisdicciones con tax_id implementadas:** AR (CUIT, 11 dígitos,
  mod-11), CL (RUT, 8-9 dígitos + DV, mod-11 weights 2..7),
  US (SSN 9 dígitos, reglas de area/group/serial), BR (CPF 11 dígitos,
  CNPJ 14 dígitos, ambos mod-11).
- **Placeholder detection:** todos los mismos dígitos (`99999999999`) o
  secuencia consecutiva (`12345678901`) → peso 0 en similarity. Es a
  propósito: un match entre dos placeholders **no** es signal de identidad.
- **Country vs Nationality:** en `person`, `country` = residencia/domicilio
  (qué tax_id tiene), `nationality` = ciudadanía (relevante para EDD, otro
  motor). No mezclar.

### Weighting de `calculate_similarity`

```
score = (Σ componente_i × peso_i) / Σ peso_i × 100
```

- `name` — peso 0.5 (siempre).
- `tax_id` — peso 0.3 / 0.15 / 0 según validación.
- `birth_date` — peso 0.2 (si ambos presentes).

---

## Playbooks comunes

### Agregar una nueva jurisdicción de tax_id

1. Escribir `V###__tax_id_validation_<country>.sql` con función
   `_validate_<country>_<doctype>(p_normalized)` que devuelva jsonb con
   `{category, reasons, normalized, country, doc_type}`.
2. Agregar el branch en el dispatcher (`public.validate_tax_id`) matcheando
   por `p_country = 'XX'`.
3. Actualizar el check de `UNKNOWN_COUNTRY` para excluir el nuevo código.
4. Agregar sección de tests en `test_V###...sql` con ≥5 casos: válido,
   checksum inválido, formato inválido, placeholder, secuencial.
5. Actualizar el README: tabla de "Jurisdicciones con tax_id implementadas".

### Escribir una nueva migración

1. Elegí el próximo número: `ls migrations/V*.sql | sort -V | tail -1`.
2. Header-comment con: qué hace, por qué, dependencias previas,
   consideraciones de idempotencia.
3. Envolver todo en `BEGIN ... COMMIT`.
4. Idempotencia: `DROP IF EXISTS`, `CREATE OR REPLACE`, `IF NOT EXISTS`,
   o `DO` blocks con checks previos.
5. `COMMENT ON FUNCTION/TABLE/COLUMN` al final para doc in-DB.
6. Crear `test_V###...sql` paralelo con casos críticos.
7. Correr: primero la migración, después su test.

### Modificar una función existente

1. Si solo cambia el cuerpo: `CREATE OR REPLACE FUNCTION ...`.
2. Si cambia la signature (cantidad o tipo de params): `DROP FUNCTION IF EXISTS`
   con la signature vieja **explícita** + `CREATE`.
3. Verificar que callers no rompan: grep del nombre de la función y
   revisar que cada call site use la nueva signature o defaults.

---

## Qué NO hacer

- **NO** hardcodear `tenant_id`s o UUIDs fuera de tests/seeds.
- **NO** usar `SET ROLE` dentro de funciones SECURITY DEFINER — usa
  `search_path` fijo y confía en el grant.
- **NO** agregar columnas `tenant_id` a tablas que heredan visibilidad
  (ej: `screening_list_entry`, que hereda vía `list`).
- **NO** bypassar RLS con `SET row_security = off` — si realmente necesitás,
  justifica en el PR.
- **NO** usar el operador `||` para concatenar strings a arrays en
  contextos `jsonb` — causa ambigüedad de resolución. Usar `array_append()`.
  (Ver el comment de V008 sobre el bug que arreglamos.)
- **NO** guardar texto plano en `alert.detail` — es jsonb post-V010.
- **NO** mezclar `country` con `nationality` en lógica de screening.

---

## Verificación de cambios

Antes de considerar un cambio "done":

```bash
# 1. La migración corre sin errores
docker compose exec db psql -U complif_admin -d complif \
    -f /repo/migrations/V###__tu_cambio.sql

# 2. El test de la migración pasa
docker compose exec db psql -U complif_admin -d complif \
    -f /repo/migrations/tests/test_V###__tu_cambio.sql

# 3. Los tests previos siguen pasando (no rompiste nada)
docker compose exec db bash -c '
    for t in /repo/migrations/tests/test_V*.sql; do
        echo "=== $t ==="
        psql -U complif_admin -d complif -f "$t"
    done
'
```

Si cualquiera falla, el cambio no está done.

---

## Referencias internas

- `README.md` — overview, quickstart, decisiones de diseño.
- `.cursor/rules/complif.mdc` — versión Cursor-friendly de este archivo.
- `.mcp.json` — config del MCP Postgres server para queryear la DB desde
  el agente durante desarrollo.
- `migrations/` — schema evolution (V000-V010 al momento de escribir esto).
- `migrations/tests/` — tests SQL por migración.

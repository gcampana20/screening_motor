-- =============================================================================
-- demo/tour.sql
-- -----------------------------------------------------------------------------
-- Tour guiado del motor de screening. 8 pasos secuenciales que muestran el
-- motor end-to-end sin leer código: contexto multi-tenant, matching fuerte,
-- matching con peso degradado por placeholder, validador de tax_id,
-- aislamiento RLS cross-tenant, y vistas de reporting.
--
-- Uso (recomendado para review rápido):
--   docker compose exec db psql -U complif_admin -d complif -f /repo/demo/tour.sql
--
-- Uso didáctico (ver paso por paso): abrir sesión interactiva y copiar-pegar
-- sección por sección desde este archivo, mirando los resultados uno por uno.
--   docker compose exec db psql -U complif_admin -d complif
--
-- Este archivo NO modifica datos — son todos SELECTs + SET de sesión.
-- =============================================================================

-- ============================================================================
-- Configuración de display para que la salida sea legible en -f
-- ============================================================================

-- Pager OFF: evita que psql capture stdin y tire los resultados al "less"
-- cuando corremos con -f. Sin esto, quedás atrapado en (END) entre secciones.
\pset pager off

-- Formato vertical automático: cuando una fila es más ancha que la terminal,
-- psql la muestra columna-por-columna. Crítico para leer los JSON de
-- `match_details` en `run_screening` y el breakdown de `validate_tax_id`.
\x auto

-- Alinear nombres de columna a la izquierda para que los banners de \echo
-- queden bien alineados con las tablas.
\pset linestyle unicode
\pset border 2


-- ============================================================================
-- Cambio de rol: pasar de complif_admin (SUPERUSER) a complif_app (NOSUPERUSER)
-- ============================================================================
-- IMPORTANTE: los SUPERUSER bypasean RLS por definición de Postgres, aunque
-- las tablas tengan FORCE ROW LEVEL SECURITY. Sin este SET ROLE, los SELECTs
-- del tour devolverían filas de TODOS los tenants, anulando la demo.
--
-- complif_app se crea en V011 con NOSUPERUSER + NOBYPASSRLS, así que las
-- policies de V004 sí se aplican. El SET ROLE es válido porque complif_admin
-- (rol de sesión) es superuser y puede asumir cualquier rol.
--
-- El cambio dura toda la sesión del script. Si corrés interactivo y querés
-- volver a admin: RESET ROLE;
SET ROLE complif_app;

\echo ''
\echo '── Rol activo durante el tour:'
SELECT current_user AS rol_efectivo,
       session_user AS rol_de_sesion,
       current_setting('is_superuser') AS es_superuser;


-- ============================================================================
-- Convención de tenant context a lo largo del tour
-- ============================================================================
-- PASO 1 .......... sin tenant context (lista tenants — tabla SIN RLS).
-- PASO 2 .......... SET app.tenant_id = Acme  → contexto Acme en pasos 2-6.
-- PASO 3-5 ........ heredan el contexto Acme del paso 2.
-- PASO 6 .......... validate_tax_id es función pura, no depende de tenant.
-- PASO 7 .......... SET app.tenant_id = Globex (switch para demostrar RLS).
-- PASO 8 .......... SET app.tenant_id = Acme (volvemos a Acme para reporting).
--
-- Cada vez que cambia el contexto, el tour imprime "── Tenant activo: …"
-- abajo del SET para que sea visualmente claro desde qué tenant se consulta.


-- ============================================================================
-- PASO 1 — Ver los tenants disponibles
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 1 — Tenants registrados (catálogo SIN RLS)                    ║'
\echo '║ Cada tenant = un cliente de Complif (banco, fintech).              ║'
\echo '║ En prod habría decenas; en los seeds hay 2 (Acme, Globex).         ║'
\echo '║ Nota: este SELECT funciona sin SET app.tenant_id porque la tabla   ║'
\echo '║ tenant queda intencionalmente fuera de RLS (es un catálogo).       ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

SELECT id, name FROM public.tenant ORDER BY name;


-- ============================================================================
-- PASO 2 — Contextualizarte como Acme y ver SUS datos
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 2 — Set tenant context = Acme, listar SUS personas            ║'
\echo '║ SET app.tenant_id activa el filtro de RLS: a partir de acá, TODAS  ║'
\echo '║ las queries se scopean automáticamente. No más WHERE tenant_id.    ║'
\echo '║ Esperado: 3 personas (Juan, María, Ricardo). Las 3 de Globex NO    ║'
\echo '║ aparecen aunque esten en la misma tabla.                           ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

SET app.tenant_id = '10000000-0000-0000-0000-000000000001';

\echo ''
\echo '── Tenant activo:'
SELECT COALESCE(
    (SELECT name FROM public.tenant WHERE id = public.current_tenant_id()),
    '(sin contexto)'
) AS tenant_activo;

SELECT first_name, last_name, country, tax_id
FROM public.person
ORDER BY last_name;


-- ============================================================================
-- PASO 3 — Ver listas contra las que se screenea
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 3 — Listas disponibles desde Acme                             ║'
\echo '║ tenant_id = NULL  → lista GLOBAL (OFAC, UN, PEP, Adverse Media),   ║'
\echo '║                     mantenida por Complif centralmente.            ║'
\echo '║ tenant_id = UUID  → lista PRIVADA del tenant (Internal Blacklist). ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

SELECT name, type, tenant_id,
       CASE WHEN tenant_id IS NULL
            THEN 'Global (Complif la mantiene)'
            ELSE 'Privada del tenant' END AS origen
FROM public.list
ORDER BY tenant_id NULLS FIRST, name;


-- ============================================================================
-- PASO 4 — Match fuerte: Juan Pérez contra OFAC
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 4 — run_screening: Juan Pérez contra TODAS las listas         ║'
\echo '║ Esperado: 1 alerta contra OFAC SDN, similarity_score = 100.00      ║'
\echo '║ En match_details (JSON) ves el breakdown: name=1.0, tax_id=1,     ║'
\echo '║ birth_date=1, weights.total=1.0 → match exacto en todo.            ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

-- jsonb_pretty hace que el JSON salga multi-línea y legible en lugar de una
-- sola fila kilométrica. Las otras columnas las explicitamos para mantener
-- el orden estable.
SELECT alert_id,
       list_name,
       matched_entry_id,
       similarity_score,
       jsonb_pretty(match_details) AS match_details
FROM public.run_screening(
    'PERSON',
    '30000000-0000-0000-0000-000000000001'::uuid,
    NULL
);


-- ============================================================================
-- PASO 5 — Match con tax_id PLACEHOLDER (peso degradado a 0)
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 5 — run_screening: Ricardo Fernández (tax_id = 99999999999)   ║'
\echo '║ Hay una entry en UN Consolidated con el mismo placeholder. Sin la  ║'
\echo '║ lógica de V008+V009, el "tax_id igual" inflaría el score. Con la   ║'
\echo '║ validación, el peso del tax_id COLAPSA A 0 y el score refleja solo ║'
\echo '║ el name similarity (fuzzy).                                        ║'
\echo '║ Mirá en match_details: weights_applied.tax_id = 0.                 ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

SELECT alert_id,
       list_name,
       matched_entry_id,
       similarity_score,
       jsonb_pretty(match_details) AS match_details
FROM public.run_screening(
    'PERSON',
    '30000000-0000-0000-0000-000000000003'::uuid,
    NULL
);


-- ============================================================================
-- PASO 6 — Validador de tax_id aislado (función reutilizable)
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 6 — validate_tax_id: las 4 categorías side-by-side            ║'
\echo '║ La función es reutilizable fuera del screening (ej: un officer     ║'
\echo '║ verificando un doc suelto). En vez de mirar 4 JSONs separados,     ║'
\echo '║ comparamos las 4 categorías en una sola tabla:                     ║'
\echo '║   6a VALID            — CUIT con checksum correcto.                ║'
\echo '║   6b PLACEHOLDER      — formato OK pero todos los dígitos iguales. ║'
\echo '║   6c INVALID_CHECKSUM — formato OK, checksum mod-11 falla.         ║'
\echo '║   6d UNKNOWN_COUNTRY  — país sin validador implementado (FR).      ║'
\echo '║ Mirá las columnas is_valid / is_suspicious / reasons para ver      ║'
\echo '║ cómo la función diferencia cada caso.                              ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

-- Una sola query que extrae las columnas clave del JSON que devuelve
-- validate_tax_id, para que las 4 categorías queden alineadas en filas
-- comparables. Si la fila es más ancha que la terminal, \x auto la pasa a
-- formato vertical (RECORD 1..4) y sigue siendo legible.
SELECT
    caso,
    j->>'category'                   AS category,
    j->>'doc_type'                   AS doc_type,
    j->>'normalized'                 AS normalized,
    (j->>'is_valid')::boolean        AS is_valid,
    (j->>'is_suspicious')::boolean   AS is_suspicious,
    j->'reasons'                     AS reasons
FROM (VALUES
    ('6a · CUIT VÁLIDO',         public.validate_tax_id('20-12345678-6', 'AR')),
    ('6b · PLACEHOLDER',         public.validate_tax_id('99999999999',   'AR')),
    ('6c · CHECKSUM INVÁLIDO',   public.validate_tax_id('20-12345678-0', 'AR')),
    ('6d · UNKNOWN_COUNTRY (FR)', public.validate_tax_id('12345678901',   'FR'))
) AS t(caso, j);


-- ============================================================================
-- PASO 7 — Cambiar de tenant: aislamiento RLS en acción
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 7 — SET tenant context = Globex, correr las MISMAS queries   ║'
\echo '║ Esperado: resultados COMPLETAMENTE distintos, sin tocar el SQL.    ║'
\echo '║ Los datos de Acme desaparecen; aparecen Pedro, John, João.         ║'
\echo '║ Las alerts pre-cargadas? 0 visibles (todas son de Acme).           ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

SET app.tenant_id = '10000000-0000-0000-0000-000000000002';

\echo ''
\echo '── Tenant activo:'
SELECT COALESCE(
    (SELECT name FROM public.tenant WHERE id = public.current_tenant_id()),
    '(sin contexto)'
) AS tenant_activo;

\echo ''
\echo '--- 7a) Personas visibles desde Globex ---'
SELECT first_name, last_name, country FROM public.person ORDER BY last_name;

\echo ''
\echo '--- 7b) Alertas visibles desde Globex ---'
SELECT COUNT(*) AS alerts_visibles FROM public.alert;


-- ============================================================================
-- PASO 8 — Vistas de reporting (volvemos a Acme)
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ PASO 8 — Dashboards: las vistas que consume el frontend            ║'
\echo '║ Respetan RLS transitivamente (consultan tablas con policies).      ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

SET app.tenant_id = '10000000-0000-0000-0000-000000000001';

\echo ''
\echo '── Tenant activo:'
SELECT COALESCE(
    (SELECT name FROM public.tenant WHERE id = public.current_tenant_id()),
    '(sin contexto)'
) AS tenant_activo;

\echo ''
\echo '--- 8a) Aging de alertas pendientes ---'
SELECT * FROM public.vw_alert_aging;

\echo ''
\echo '--- 8b) Workload por analista ---'
SELECT * FROM public.vw_pending_alerts_by_analyst;

\echo ''
\echo '--- 8c) KPIs globales del tenant ---'
SELECT * FROM public.vw_screening_metrics;


-- ============================================================================
-- Fin del tour
-- ============================================================================
\echo ''
\echo '╔════════════════════════════════════════════════════════════════════╗'
\echo '║ Tour completo. Próximos pasos:                                     ║'
\echo '║   - migrations/tests/  — cobertura de tests por migración          ║'
\echo '║   - baseline/functions/p_calculate_similarity.sql  — core matching ║'
\echo '║   - migrations/V009__run_screening_country_aware_validation.sql    ║'
\echo '║     — versión final de run_screening con validación cross-country  ║'
\echo '╚════════════════════════════════════════════════════════════════════╝'

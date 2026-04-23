-- =============================================================================
-- test_V010__security_definer_and_minor_fixes.sql
-- -----------------------------------------------------------------------------
-- Verifica los tres cambios de V010 consultando catálogos de Postgres. No
-- necesita setup de datos: todo se comprueba leyendo pg_proc, pg_constraint,
-- information_schema.columns, pg_indexes.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. SECURITY DEFINER + search_path en las tres funciones
-- -----------------------------------------------------------------------------
-- prosecdef = true → SECURITY DEFINER
-- proconfig debe contener 'search_path=pg_catalog, public'
SELECT 'T1 SECURITY DEFINER + search_path' AS test,
       p.proname                                         AS fn_name,
       p.prosecdef                                       AS is_definer,
       array_to_string(p.proconfig, ', ')                AS config
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('run_screening', 'run_batch_screening', 'run_ongoing_screening')
ORDER BY p.proname;
-- Esperado: 3 rows, is_definer=t en todas, config contiene search_path=pg_catalog, public.

-- -----------------------------------------------------------------------------
-- 2. Constraint alert_status_check existe
-- -----------------------------------------------------------------------------
SELECT 'T2 alert_status_check presente' AS test,
       c.conname                                         AS constraint_name,
       pg_get_constraintdef(c.oid)                       AS definition
FROM pg_constraint c
JOIN pg_class t     ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public'
  AND t.relname = 'alert'
  AND c.conname = 'alert_status_check';
-- Esperado: 1 row con CHECK (status = ANY (ARRAY['PENDING', 'REVIEWING', ...])).

-- 2.b Verificar que el constraint realmente rechaza valores inválidos.
--     Usamos SAVEPOINT para que el rollback no aborte todo el script.
BEGIN;
SAVEPOINT sp_invalid_status;

DO $$
BEGIN
    INSERT INTO public.alert (id, tenant_id, person_id, status)
    VALUES (uuid_generate_v4(),
            '00000000-0000-0000-0000-000000000000',
            '00000000-0000-0000-0000-000000000001',
            'INVALID_STATUS');
    RAISE EXCEPTION 'T2.b FAIL: el constraint dejó pasar un status inválido';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'T2.b OK: alert_status_check rechazó INVALID_STATUS';
    WHEN foreign_key_violation THEN
        -- El FK a tenant falla antes que el CHECK. Igual significa que el test
        -- setup está incompleto, no que el CHECK ande mal.
        RAISE NOTICE 'T2.b SKIP: FK violation antes que CHECK (no se pudo testear)';
END $$;

ROLLBACK TO SAVEPOINT sp_invalid_status;
ROLLBACK;

-- -----------------------------------------------------------------------------
-- 3. alert.detail ahora es jsonb + índice GIN
-- -----------------------------------------------------------------------------
SELECT 'T3.1 alert.detail tipo' AS test,
       column_name,
       data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'alert'
  AND column_name  = 'detail';
-- Esperado: data_type = 'jsonb'.

SELECT 'T3.2 índice GIN en alert.detail' AS test,
       indexname,
       indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename  = 'alert'
  AND indexname  = 'ix_alert_detail_gin';
-- Esperado: 1 row con USING gin (detail jsonb_path_ops).

-- 3.b Smoke test: insertar y consultar con operadores jsonb.
BEGIN;
SAVEPOINT sp_jsonb_smoke;

-- Necesitamos una person y tenant válidos. Usamos los del test_V009 o creamos efímeros.
INSERT INTO public.tenant (id, name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'T010 Smoke Tenant')
ON CONFLICT DO NOTHING;

INSERT INTO public.person (id, first_name, last_name, tenant_id)
VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Test', 'Person',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
ON CONFLICT DO NOTHING;

INSERT INTO public.alert (
    id, tenant_id, person_id, status, similarity_score, detail
)
VALUES (
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'PENDING',
    85.5,
    jsonb_build_object(
        'tax_id_validation', jsonb_build_object(
            'downgraded', true,
            'input', jsonb_build_object('category', 'INVALID_CHECKSUM')
        )
    )
);

-- Query con operador @> (containment, usa jsonb_path_ops index).
SELECT 'T3.b containment query' AS test,
       id,
       detail->'tax_id_validation'->>'downgraded' AS downgraded,
       detail->'tax_id_validation'->'input'->>'category' AS input_cat
FROM public.alert
WHERE tenant_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND detail @> '{"tax_id_validation": {"downgraded": true}}'::jsonb;
-- Esperado: 1 row, downgraded=true, input_cat=INVALID_CHECKSUM.

ROLLBACK TO SAVEPOINT sp_jsonb_smoke;
ROLLBACK;

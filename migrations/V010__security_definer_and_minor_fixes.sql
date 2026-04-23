-- =============================================================================
-- V010__security_definer_and_minor_fixes.sql
-- -----------------------------------------------------------------------------
-- Tres cambios consolidados:
--
--   1. SECURITY DEFINER + SET search_path en funciones que escriben en tablas
--      sensibles (alert, screening_run_log). Permite que un rol de app con
--      GRANT EXECUTE pueda disparar screenings sin tener INSERT directo en
--      alert. El SET search_path es obligatorio para evitar search_path
--      injection (sin él, SECURITY DEFINER es vulnerable: un schema temporal
--      con un similarity() malicioso se resolvería primero).
--
--   2. Constraint faltante alert_status_check. En el DDL original de alert
--      había una coma faltante entre alert_owner_check y alert_status_check,
--      así que el segundo CHECK quedó sin aplicar. Lo agregamos idempotente.
--
--   3. alert.detail de varchar a jsonb. calculate_similarity devuelve jsonb
--      con datos estructurados (tax_id_validation, weights_applied, etc).
--      Guardarlo como varchar lo coerce a texto y perdemos indexación GIN y
--      queries tipo `detail->'tax_id_validation'->>'category'`. Con jsonb,
--      un analista puede filtrar alertas por categoría de validación.
--
-- Idempotencia: DROP IF EXISTS + ADD para constraint; ALTER FUNCTION es
-- idempotente; el ALTER COLUMN TYPE va dentro de un DO block con check de
-- tipo actual para no fallar en reruns.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. SECURITY DEFINER + search_path en funciones que modifican datos
-- =============================================================================

-- run_screening (V009): INSERT en alert.
ALTER FUNCTION public.run_screening(text, uuid, text[])
    SECURITY DEFINER
    SET search_path = pg_catalog, public;

-- run_batch_screening (V007): INSERT en alert + screening_run_log.
ALTER FUNCTION public.run_batch_screening(uuid, text, int)
    SECURITY DEFINER
    SET search_path = pg_catalog, public;

-- run_ongoing_screening (V007): INSERT en alert + screening_run_log.
ALTER FUNCTION public.run_ongoing_screening(uuid[])
    SECURITY DEFINER
    SET search_path = pg_catalog, public;

-- Nota: funciones puras (calculate_similarity, validate_tax_id, normalize_*,
-- search_by_tax_id) quedan como SECURITY INVOKER. No escriben, no necesitan
-- privilegios elevados, y mantenerlas INVOKER es el principio de mínimo
-- privilegio: si el caller no puede leer la tabla, la función tampoco debería.

COMMENT ON FUNCTION public.run_screening(text, uuid, text[]) IS
    'Ejecuta screening de un entity. V010: SECURITY DEFINER con search_path '
    'fijado para permitir ejecución por roles con solo GRANT EXECUTE.';


-- =============================================================================
-- 2. Agregar alert_status_check (constraint perdido por coma faltante en DDL)
-- =============================================================================

ALTER TABLE public.alert
    DROP CONSTRAINT IF EXISTS alert_status_check;

ALTER TABLE public.alert
    ADD CONSTRAINT alert_status_check
    CHECK (status IN ('PENDING', 'REVIEWING', 'CONFIRMED', 'DISMISSED'));


-- =============================================================================
-- 3. alert.detail: varchar → jsonb
-- =============================================================================

-- Idempotencia: solo convertimos si todavía es character varying.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'alert'
          AND column_name  = 'detail'
          AND data_type    = 'character varying'
    ) THEN
        -- USING defensivo: detail puede contener NULL, '', o texto JSON válido
        -- generado por calculate_similarity. Strings vacíos los mapeamos a NULL
        -- porque '' no es JSON válido y haría fallar el cast.
        ALTER TABLE public.alert
            ALTER COLUMN detail TYPE jsonb
            USING CASE
                WHEN detail IS NULL OR detail = '' THEN NULL::jsonb
                ELSE detail::jsonb
            END;
    END IF;
END $$;

COMMENT ON COLUMN public.alert.detail IS
    'Payload estructurado con breakdown del match: name_similarity, '
    'tax_id_match, birth_date_score, weights_applied, tax_id_validation. '
    'V010: migrado de varchar a jsonb para indexación GIN y queries nativos.';

-- Índice GIN para queries del tipo:
--   SELECT * FROM alert WHERE detail @> '{"tax_id_validation": {"downgraded": true}}';
--   SELECT * FROM alert WHERE detail->'tax_id_validation'->>'category' = 'INVALID_CHECKSUM';
-- jsonb_path_ops es más chico y rápido que el default para containment queries,
-- que es el 90% del use case de un analista buscando patrones en alertas.
CREATE INDEX IF NOT EXISTS ix_alert_detail_gin
    ON public.alert USING GIN (detail jsonb_path_ops);

COMMIT;

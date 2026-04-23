-- =============================================================================
-- V007__screening_batch_and_ongoing.sql
-- -----------------------------------------------------------------------------
-- Dos modos operativos del motor de screening además del screening on-demand
-- implementado en V006:
--
--   A) BATCH: correr screening sobre muchas entidades de un tenant a la vez.
--      Caso de uso: onboarding de un cliente con base histórica, re-screening
--      periódico de cartera, job nocturno del día.
--
--   B) ONGOING: cuando una lista publica nuevas entries (OFAC/UN/EU publican
--      updates diarios), buscar REVERSE qué entidades ya onboardeadas matchean
--      con esas entries nuevas. Este modo es la razón por la que V003 creó
--      los índices GIN trigram sobre person.fullname y company.name.
--
-- Contenido de esta migration:
--
--   1. Tabla screening_run_log: audit trail de cada corrida. Habilita
--      saber "cuándo fue la última vez que screeneamos a este cliente".
--   2. Función run_batch_screening: wrapper que itera entidades y llama
--      run_screening, registrando cada invocación en el log.
--   3. Función run_ongoing_screening: reverse lookup. Dado un array de
--      sle_ids nuevas, busca matches eficientemente vía GIN trigram.
--   4. Vista vw_entities_pending_screening: entidades que nunca fueron
--      screeneadas o cuya última corrida es vieja (> 30 días).
--
-- Scope note: run_screening (de V006) no se modifica en V007. El logging
-- lo hacen las funciones wrapper (batch, ongoing). Callers "manuales" a
-- run_screening que quieran audit trail deben hacer el INSERT en
-- screening_run_log desde la app. Decisión tomada para no acoplar V007
-- con el core de V006.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Tabla screening_run_log
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.screening_run_log (
    id               uuid         PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id        uuid         NOT NULL,
    entity_type      text         NOT NULL
        CHECK (entity_type IN ('PERSON', 'COMPANY')),
    entity_id        uuid         NOT NULL,
    run_at           timestamptz  NOT NULL DEFAULT now(),
    alerts_matched   int          NOT NULL DEFAULT 0,  -- nuevas + preexistentes
    alerts_created   int          NOT NULL DEFAULT 0,  -- solo nuevas
    triggered_by     text         NOT NULL DEFAULT 'MANUAL'
        CHECK (triggered_by IN ('MANUAL', 'BATCH', 'ONGOING')),
    list_ids_scanned uuid[]                            -- NULL = todas las listas
);

COMMENT ON TABLE public.screening_run_log IS
    'Audit trail de screening: una fila por cada invocación de screening sobre '
    'una entidad. Habilita "last_screened_at", detección de entidades stale, '
    'y cumplimiento regulatorio (poder demostrar cuándo se screeneó a cada cliente).';

COMMENT ON COLUMN public.screening_run_log.alerts_matched IS
    'Total de matches (nuevos + preexistentes) que superaron el threshold.';
COMMENT ON COLUMN public.screening_run_log.alerts_created IS
    'Solo alerts creados en esta corrida (excluye dedup).';
COMMENT ON COLUMN public.screening_run_log.triggered_by IS
    'Origen de la corrida: MANUAL (API/UI), BATCH (run_batch_screening), '
    'ONGOING (run_ongoing_screening).';

-- Índices: las queries típicas son "última corrida por entidad" y "corridas del tenant".
CREATE INDEX IF NOT EXISTS ix_srl_tenant_entity_runat
    ON public.screening_run_log (tenant_id, entity_type, entity_id, run_at DESC);

CREATE INDEX IF NOT EXISTS ix_srl_tenant_runat
    ON public.screening_run_log (tenant_id, run_at DESC);

-- RLS (mismo patrón que V004 para tablas tenant-scoped)
ALTER TABLE public.screening_run_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.screening_run_log FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS srl_tenant_isolation ON public.screening_run_log;
CREATE POLICY srl_tenant_isolation ON public.screening_run_log
    USING      (tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id = public.current_tenant_id());

-- -----------------------------------------------------------------------------
-- 2. run_batch_screening
-- -----------------------------------------------------------------------------
-- Itera sobre las entidades de un tenant (personas, empresas, o ambas) y llama
-- run_screening. Registra cada invocación en screening_run_log.
--
-- Implementación: una sola transacción. Para producción con volúmenes grandes
-- (> 10k entidades), conviene que el orquestador externo llame este wrapper
-- en chunks (p_limit=500) y loopee, así cada chunk tiene su propia transacción
-- y los locks sobre alert son de corta duración.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_batch_screening(
    p_tenant_id   uuid,
    p_entity_type text DEFAULT NULL,   -- 'PERSON', 'COMPANY', NULL = ambos
    p_limit       int  DEFAULT NULL    -- NULL = todas las entidades
)
RETURNS TABLE (
    entity_type     text,
    entity_id       uuid,
    alerts_matched  int,
    alerts_created  int
)
LANGUAGE plpgsql
AS $$
DECLARE
    r                 record;
    v_matched         int;
    v_created         int;
    v_alerts_before   int;
    v_alerts_after    int;
BEGIN
    -- PERSON branch
    IF p_entity_type IS NULL OR p_entity_type = 'PERSON' THEN
        FOR r IN
            SELECT p.id, 'PERSON'::text AS etype
            FROM public.person p
            WHERE p.tenant_id = p_tenant_id
            ORDER BY p.id
            LIMIT p_limit
        LOOP
            SELECT count(*) INTO v_alerts_before
            FROM public.alert
            WHERE person_id = r.id;

            SELECT count(*) INTO v_matched
            FROM public.run_screening('PERSON', r.id);

            SELECT count(*) INTO v_alerts_after
            FROM public.alert
            WHERE person_id = r.id;

            v_created := v_alerts_after - v_alerts_before;

            INSERT INTO public.screening_run_log
                (tenant_id, entity_type, entity_id,
                 alerts_matched, alerts_created, triggered_by)
            VALUES
                (p_tenant_id, 'PERSON', r.id,
                 v_matched, v_created, 'BATCH');

            entity_type    := r.etype;
            entity_id      := r.id;
            alerts_matched := v_matched;
            alerts_created := v_created;
            RETURN NEXT;
        END LOOP;
    END IF;

    -- COMPANY branch
    IF p_entity_type IS NULL OR p_entity_type = 'COMPANY' THEN
        FOR r IN
            SELECT c.id, 'COMPANY'::text AS etype
            FROM public.company c
            WHERE c.tenant_id = p_tenant_id
            ORDER BY c.id
            LIMIT p_limit
        LOOP
            SELECT count(*) INTO v_alerts_before
            FROM public.alert
            WHERE company_id = r.id;

            SELECT count(*) INTO v_matched
            FROM public.run_screening('COMPANY', r.id);

            SELECT count(*) INTO v_alerts_after
            FROM public.alert
            WHERE company_id = r.id;

            v_created := v_alerts_after - v_alerts_before;

            INSERT INTO public.screening_run_log
                (tenant_id, entity_type, entity_id,
                 alerts_matched, alerts_created, triggered_by)
            VALUES
                (p_tenant_id, 'COMPANY', r.id,
                 v_matched, v_created, 'BATCH');

            entity_type    := r.etype;
            entity_id      := r.id;
            alerts_matched := v_matched;
            alerts_created := v_created;
            RETURN NEXT;
        END LOOP;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.run_batch_screening(uuid, text, int) IS
    'Corre screening sobre todas (o las primeras p_limit) entidades de un '
    'tenant. Registra cada corrida en screening_run_log con triggered_by=BATCH. '
    'Para producción con alto volumen, invocar en chunks desde un orquestador externo.';

-- -----------------------------------------------------------------------------
-- 3. run_ongoing_screening
-- -----------------------------------------------------------------------------
-- Reverse lookup: dado un array de sle_ids (entries recién agregadas o
-- actualizadas en una lista), busca qué entidades ya existentes matchean.
--
-- Eficiencia: usa el operador % de pg_trgm contra la MISMA expresión que
-- indexaron en V003 (ix_person_fullname_trgm, ix_company_name_trgm), lo cual
-- permite al planner usar el GIN trigram para pre-filtrar candidatos. Después
-- calculate_similarity calcula el score real sobre un conjunto chico.
--
-- Visibilidad cross-tenant: las entries de listas globales (list.tenant_id IS
-- NULL) generan alerts en TODOS los tenants que tengan entidades similares.
-- Las entries de listas tenant-specific solo afectan al tenant dueño de la lista.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_ongoing_screening(
    p_sle_ids uuid[]
)
RETURNS TABLE (
    sle_id              uuid,
    matched_entity_type text,
    matched_entity_id   uuid,
    alert_id            uuid,
    similarity_score    numeric
)
LANGUAGE plpgsql
AS $$
-- Directiva: si un identificador colisiona con un OUT param (similarity_score,
-- sle_id, alert_id, etc.), PL/pgSQL prefiere la columna sobre la variable.
-- Sin esto, la query interna falla con "referencia ambigua" (SQLSTATE 42702).
#variable_conflict use_column
DECLARE
    r record;
BEGIN
    -- Iteramos cada entry a procesar.
    FOR r IN
        SELECT sle.id           AS sle_id,
               sle.full_name,
               sle.tax_id       AS sle_tax_id,
               sle.birth_date,
               sle.entry_type,
               l.id             AS list_id,
               l.name           AS list_name,
               l.tenant_id      AS list_tenant_id
        FROM public.screening_list_entry sle
        JOIN public.list l ON l.id = sle.list_id
        WHERE sle.id = ANY(p_sle_ids)
    LOOP
        IF r.entry_type = 'PERSON' THEN
            RETURN QUERY
            WITH candidates AS (
                -- Pre-filtro por GIN trigram. La expresión normalize_name(COALESCE(...))
                -- debe coincidir EXACTAMENTE con la de ix_person_fullname_trgm (V003).
                SELECT
                    p.tenant_id,
                    p.id           AS person_id,
                    cs.similarity_score,
                    cs.match_type,
                    cs.details
                FROM public.person p
                CROSS JOIN LATERAL public.calculate_similarity(
                    concat_ws(' ', p.first_name, p.last_name),
                    r.full_name,
                    p.tax_id,
                    r.sle_tax_id,
                    p.birth_date,
                    r.birth_date
                ) cs
                WHERE public.normalize_name(
                          COALESCE(p.first_name, '') || ' ' || COALESCE(p.last_name, '')
                      ) % public.normalize_name(r.full_name)
                  AND (r.list_tenant_id IS NULL OR p.tenant_id = r.list_tenant_id)
            ),
            filtered AS (
                SELECT *
                FROM candidates
                WHERE similarity_score >=
                      public.resolve_similarity_threshold(r.list_id) * 100
            ),
            inserted AS (
                INSERT INTO public.alert AS a (
                    id, created_at, updated_at, name, type,
                    person_id, company_id, tenant_id,
                    screening_list_entry_id, status, analyst_id,
                    similarity_score, detail
                )
                SELECT
                    uuid_generate_v4(), now(), now(),
                    r.list_name, f.match_type,
                    f.person_id, NULL, f.tenant_id,
                    r.sle_id, 'PENDING', NULL,
                    f.similarity_score, f.details
                FROM filtered f
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.alert a2
                    WHERE a2.person_id               = f.person_id
                      AND a2.screening_list_entry_id = r.sle_id
                      AND a2.tenant_id               = f.tenant_id
                )
                RETURNING a.id, a.person_id, a.tenant_id, a.similarity_score
            ),
            logged AS (
                -- Log ONGOING por cada match encontrado (una fila por entity_id único).
                INSERT INTO public.screening_run_log
                    (tenant_id, entity_type, entity_id,
                     alerts_matched, alerts_created, triggered_by, list_ids_scanned)
                SELECT
                    i.tenant_id, 'PERSON', i.person_id,
                    1, 1, 'ONGOING', ARRAY[r.list_id]
                FROM inserted i
                RETURNING 1
            )
            SELECT r.sle_id, 'PERSON'::text, i.person_id, i.id, i.similarity_score
            FROM inserted i;

        ELSIF r.entry_type = 'COMPANY' THEN
            RETURN QUERY
            WITH candidates AS (
                SELECT
                    c.tenant_id,
                    c.id           AS company_id,
                    cs.similarity_score,
                    cs.match_type,
                    cs.details
                FROM public.company c
                CROSS JOIN LATERAL public.calculate_similarity(
                    c.name, r.full_name,
                    c.tax_id, r.sle_tax_id,
                    NULL, NULL
                ) cs
                WHERE public.normalize_name(c.name) % public.normalize_name(r.full_name)
                  AND (r.list_tenant_id IS NULL OR c.tenant_id = r.list_tenant_id)
            ),
            filtered AS (
                SELECT *
                FROM candidates
                WHERE similarity_score >=
                      public.resolve_similarity_threshold(r.list_id) * 100
            ),
            inserted AS (
                INSERT INTO public.alert AS a (
                    id, created_at, updated_at, name, type,
                    person_id, company_id, tenant_id,
                    screening_list_entry_id, status, analyst_id,
                    similarity_score, detail
                )
                SELECT
                    uuid_generate_v4(), now(), now(),
                    r.list_name, f.match_type,
                    NULL, f.company_id, f.tenant_id,
                    r.sle_id, 'PENDING', NULL,
                    f.similarity_score, f.details
                FROM filtered f
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.alert a2
                    WHERE a2.company_id              = f.company_id
                      AND a2.screening_list_entry_id = r.sle_id
                      AND a2.tenant_id               = f.tenant_id
                )
                RETURNING a.id, a.company_id, a.tenant_id, a.similarity_score
            ),
            logged AS (
                INSERT INTO public.screening_run_log
                    (tenant_id, entity_type, entity_id,
                     alerts_matched, alerts_created, triggered_by, list_ids_scanned)
                SELECT
                    i.tenant_id, 'COMPANY', i.company_id,
                    1, 1, 'ONGOING', ARRAY[r.list_id]
                FROM inserted i
                RETURNING 1
            )
            SELECT r.sle_id, 'COMPANY'::text, i.company_id, i.id, i.similarity_score
            FROM inserted i;
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION public.run_ongoing_screening(uuid[]) IS
    'Reverse screening: dado un conjunto de entries nuevas en listas, busca '
    'qué entidades (persons/companies) existentes las matchean. Usa los GIN '
    'trigram de V003 como pre-filtro. Registra en screening_run_log con '
    'triggered_by=ONGOING. Llamar desde el backend después de un bulk import de '
    'listas (OFAC/UN/EU), con los IDs de las entries recién insertadas.';

-- -----------------------------------------------------------------------------
-- 4. vw_entities_pending_screening
-- -----------------------------------------------------------------------------
-- Entidades que nunca fueron screeneadas o cuya última corrida es > 30 días.
-- Sirve de input para el job batch periódico.
--
-- security_invoker=true (PG 15+) hace que la vista respete la RLS del invocador,
-- no la del owner. Imprescindible acá: un usuario del Tenant A no debe ver
-- pending entities del Tenant B.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vw_entities_pending_screening
WITH (security_invoker = true) AS
WITH last_runs AS (
    SELECT entity_type,
           entity_id,
           max(run_at) AS last_run_at
    FROM public.screening_run_log
    GROUP BY entity_type, entity_id
)
SELECT
    'PERSON'::text    AS entity_type,
    p.id              AS entity_id,
    p.tenant_id,
    lr.last_run_at,
    CASE
        WHEN lr.last_run_at IS NULL                        THEN 'NEVER_SCREENED'
        WHEN lr.last_run_at < now() - interval '30 days'   THEN 'STALE'
    END               AS reason
FROM public.person p
LEFT JOIN last_runs lr
    ON lr.entity_type = 'PERSON' AND lr.entity_id = p.id
WHERE lr.last_run_at IS NULL
   OR lr.last_run_at < now() - interval '30 days'

UNION ALL

SELECT
    'COMPANY'::text, c.id, c.tenant_id,
    lr.last_run_at,
    CASE
        WHEN lr.last_run_at IS NULL                        THEN 'NEVER_SCREENED'
        WHEN lr.last_run_at < now() - interval '30 days'   THEN 'STALE'
    END
FROM public.company c
LEFT JOIN last_runs lr
    ON lr.entity_type = 'COMPANY' AND lr.entity_id = c.id
WHERE lr.last_run_at IS NULL
   OR lr.last_run_at < now() - interval '30 days';

COMMENT ON VIEW public.vw_entities_pending_screening IS
    'Entidades pendientes de screening: nunca screeneadas (NEVER_SCREENED) o '
    'con última corrida > 30 días (STALE). Input del batch job periódico. '
    'La vista usa security_invoker=true para que RLS aplique en el contexto '
    'del usuario que consulta, no del owner.';

COMMIT;

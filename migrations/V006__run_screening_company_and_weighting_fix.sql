-- =============================================================================
-- V006__run_screening_company_and_weighting_fix.sql
-- -----------------------------------------------------------------------------
-- Contiene tres cambios acoplados (van juntos porque se afectan entre sí):
--
--   1. FIX en calculate_similarity: normalización de pesos según señales
--      disponibles. El formato actual (name*0.5 + tax*0.3 + bday*0.2) * 100
--      tope un score máximo de 50 para matches name-only, dejando inaccesible
--      todo el filtrado basado en similaridad de nombre con el threshold
--      hardcodeado de 80. Con la fix, los pesos se reescalan sobre las
--      señales realmente presentes (si solo hay nombre, name-weight = 100%).
--
--   2. EXTENSIÓN de run_screening: soporte para entity_type = 'COMPANY'.
--      Antes devolvía vacío para cualquier tipo distinto de 'PERSON'.
--      Ahora ramifica en dos branches con la misma lógica de CTEs pero
--      adaptada al tipo. Si llega un valor inválido, se lanza excepción.
--
--   3. INTEGRACIÓN con V005: el threshold deja de ser 80 hardcodeado y
--      pasa a ser public.resolve_similarity_threshold(list_id) * 100
--      (se multiplica por 100 porque calculate_similarity devuelve 0..100
--      y resolve_similarity_threshold devuelve 0..1).
--
-- Nota sobre compatibilidad:
--   - Firmas de ambas funciones se mantienen → callers no se rompen.
--   - Alerts ya existentes conservan su similarity_score original (calculado
--     con la fórmula vieja). Los nuevos usan la fórmula normalizada.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. FIX calculate_similarity: normalización de pesos
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculate_similarity(
    p_name1       text,
    p_name2       text,
    p_tax_id1     text    DEFAULT NULL,
    p_tax_id2     text    DEFAULT NULL,
    p_birth_date1 date    DEFAULT NULL,
    p_birth_date2 date    DEFAULT NULL,
    p_threshold   numeric DEFAULT 0.8
)
RETURNS TABLE(similarity_score numeric, match_type text, details jsonb)
LANGUAGE plpgsql
AS $$
DECLARE
    v_name_similarity  numeric := 0;
    v_tax_id_score     numeric := 0;
    v_birth_date_score numeric := 0;
    v_total_weight     numeric := 0;
    v_weighted_sum     numeric := 0;
    v_has_tax_id       boolean := (p_tax_id1 IS NOT NULL AND p_tax_id2 IS NOT NULL);
    v_has_birth_date   boolean := (p_birth_date1 IS NOT NULL AND p_birth_date2 IS NOT NULL);
    v_final_score      numeric := 0;
BEGIN
    -- Nombre: siempre contribuye. Usa normalize_name (vía f_unaccent IMMUTABLE).
    v_name_similarity := similarity(
        public.normalize_name(p_name1),
        public.normalize_name(p_name2)
    );
    v_total_weight := v_total_weight + 0.5;
    v_weighted_sum := v_weighted_sum + v_name_similarity * 0.5;

    -- Tax ID: contribuye solo si ambos lados proveen valor.
    IF v_has_tax_id THEN
        IF public.normalize_tax_id(p_tax_id1) = public.normalize_tax_id(p_tax_id2) THEN
            v_tax_id_score := 1;
        END IF;
        v_total_weight := v_total_weight + 0.3;
        v_weighted_sum := v_weighted_sum + v_tax_id_score * 0.3;
    END IF;

    -- Fecha de nacimiento: contribuye solo si ambos lados proveen valor.
    IF v_has_birth_date THEN
        IF p_birth_date1 = p_birth_date2 THEN
            v_birth_date_score := 1;
        ELSIF EXTRACT(YEAR FROM p_birth_date1) = EXTRACT(YEAR FROM p_birth_date2) THEN
            v_birth_date_score := 0.5;
        END IF;
        v_total_weight := v_total_weight + 0.2;
        v_weighted_sum := v_weighted_sum + v_birth_date_score * 0.2;
    END IF;

    -- Score final = promedio ponderado NORMALIZADO * 100.
    -- v_total_weight siempre es >= 0.5 (nombre siempre presente), nunca 0.
    v_final_score := (v_weighted_sum / v_total_weight) * 100;
    similarity_score := round(v_final_score, 2);

    -- Clasificación del tipo de match (independiente del filtrado por threshold).
    IF v_tax_id_score = 1 THEN
        match_type := 'TAX_ID_EXACT';
    ELSIF v_name_similarity >= p_threshold AND v_birth_date_score = 1 THEN
        match_type := 'NAME_AND_BIRTHDATE';
    ELSIF v_name_similarity >= p_threshold THEN
        match_type := 'NAME_FUZZY';
    ELSE
        match_type := 'NO_MATCH';
    END IF;

    -- Details incluye los pesos aplicados → útil para debugging y auditoría.
    details := jsonb_build_object(
        'name_similarity',  round(v_name_similarity::numeric, 4),
        'tax_id_match',     v_tax_id_score,
        'birth_date_score', v_birth_date_score,
        'threshold',        p_threshold,
        'weights_applied',  jsonb_build_object(
            'name',       0.5,
            'tax_id',     CASE WHEN v_has_tax_id     THEN 0.3 ELSE 0 END,
            'birth_date', CASE WHEN v_has_birth_date THEN 0.2 ELSE 0 END,
            'total',      v_total_weight
        )
    );

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.calculate_similarity(text, text, text, text, date, date, numeric) IS
    'Calcula un score compuesto (0..100) entre dos entidades. Los pesos de '
    '(name 0.5, tax_id 0.3, birth_date 0.2) se normalizan contra las señales '
    'realmente disponibles, permitiendo scores sensatos en matches name-only. '
    'Devuelve score, match_type y details jsonb con pesos aplicados.';

-- -----------------------------------------------------------------------------
-- 2. EXTENSIÓN run_screening: PERSON + COMPANY
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_screening(
    p_entity_type text,
    p_entity_id   uuid,
    p_lists       text[] DEFAULT NULL
)
RETURNS TABLE(
    alert_id         uuid,
    list_name        text,
    matched_entry_id uuid,
    similarity_score numeric,
    match_details    jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_entity_type = 'PERSON' THEN
        RETURN QUERY
        WITH matches AS (
            SELECT
                p.tenant_id,
                p.id          AS person_id,
                sle.id        AS screening_list_entry_id,
                l.id          AS list_id,
                l.name        AS list_name,
                cs.similarity_score,
                cs.match_type,
                cs.details
            FROM public.person p
            CROSS JOIN public.screening_list_entry sle
            JOIN public.list l ON l.id = sle.list_id
            CROSS JOIN LATERAL public.calculate_similarity(
                concat_ws(' ', p.first_name, p.last_name),
                sle.full_name,
                p.tax_id,
                sle.tax_id,
                p.birth_date,
                sle.birth_date
            ) cs
            WHERE p.id = p_entity_id
              AND sle.entry_type = 'PERSON'
              AND (p_lists IS NULL OR l.name = ANY(p_lists))
        ),
        filtered_matches AS (
            SELECT *
            FROM matches m
            WHERE m.similarity_score >= public.resolve_similarity_threshold(m.list_id) * 100
        ),
        inserted_alerts AS (
            INSERT INTO public.alert AS a (
                id, created_at, updated_at, name, type,
                person_id, company_id, tenant_id,
                screening_list_entry_id, status, analyst_id,
                similarity_score, detail
            )
            SELECT
                uuid_generate_v4(), now(), now(), fm.list_name, fm.match_type,
                fm.person_id, NULL, fm.tenant_id,
                fm.screening_list_entry_id, 'PENDING', NULL,
                fm.similarity_score, fm.details
            FROM filtered_matches fm
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.alert a2
                WHERE a2.person_id               = fm.person_id
                  AND a2.screening_list_entry_id = fm.screening_list_entry_id
                  AND a2.tenant_id               = fm.tenant_id
            )
            RETURNING a.id, a.name, a.screening_list_entry_id, a.similarity_score, a.detail
        ),
        existing_alerts AS (
            SELECT a.id, a.name, a.screening_list_entry_id, a.similarity_score, a.detail
            FROM public.alert a
            JOIN filtered_matches fm
              ON a.person_id               = fm.person_id
             AND a.screening_list_entry_id = fm.screening_list_entry_id
             AND a.tenant_id               = fm.tenant_id
        )
        SELECT
            x.id::uuid                        AS alert_id,
            x.name::text                      AS list_name,
            x.screening_list_entry_id::uuid   AS matched_entry_id,
            x.similarity_score::numeric,
            x.detail::jsonb                   AS match_details
        FROM (
            SELECT * FROM inserted_alerts
            UNION
            SELECT * FROM existing_alerts
        ) x;

    ELSIF p_entity_type = 'COMPANY' THEN
        RETURN QUERY
        WITH matches AS (
            SELECT
                c.tenant_id,
                c.id          AS company_id,
                sle.id        AS screening_list_entry_id,
                l.id          AS list_id,
                l.name        AS list_name,
                cs.similarity_score,
                cs.match_type,
                cs.details
            FROM public.company c
            CROSS JOIN public.screening_list_entry sle
            JOIN public.list l ON l.id = sle.list_id
            CROSS JOIN LATERAL public.calculate_similarity(
                c.name,
                sle.full_name,
                c.tax_id,
                sle.tax_id,
                NULL,   -- las empresas no tienen birth_date
                NULL
            ) cs
            WHERE c.id = p_entity_id
              AND sle.entry_type = 'COMPANY'
              AND (p_lists IS NULL OR l.name = ANY(p_lists))
        ),
        filtered_matches AS (
            SELECT *
            FROM matches m
            WHERE m.similarity_score >= public.resolve_similarity_threshold(m.list_id) * 100
        ),
        inserted_alerts AS (
            INSERT INTO public.alert AS a (
                id, created_at, updated_at, name, type,
                person_id, company_id, tenant_id,
                screening_list_entry_id, status, analyst_id,
                similarity_score, detail
            )
            SELECT
                uuid_generate_v4(), now(), now(), fm.list_name, fm.match_type,
                NULL, fm.company_id, fm.tenant_id,
                fm.screening_list_entry_id, 'PENDING', NULL,
                fm.similarity_score, fm.details
            FROM filtered_matches fm
            WHERE NOT EXISTS (
                SELECT 1
                FROM public.alert a2
                WHERE a2.company_id              = fm.company_id
                  AND a2.screening_list_entry_id = fm.screening_list_entry_id
                  AND a2.tenant_id               = fm.tenant_id
            )
            RETURNING a.id, a.name, a.screening_list_entry_id, a.similarity_score, a.detail
        ),
        existing_alerts AS (
            SELECT a.id, a.name, a.screening_list_entry_id, a.similarity_score, a.detail
            FROM public.alert a
            JOIN filtered_matches fm
              ON a.company_id              = fm.company_id
             AND a.screening_list_entry_id = fm.screening_list_entry_id
             AND a.tenant_id               = fm.tenant_id
        )
        SELECT
            x.id::uuid                        AS alert_id,
            x.name::text                      AS list_name,
            x.screening_list_entry_id::uuid   AS matched_entry_id,
            x.similarity_score::numeric,
            x.detail::jsonb                   AS match_details
        FROM (
            SELECT * FROM inserted_alerts
            UNION
            SELECT * FROM existing_alerts
        ) x;

    ELSE
        RAISE EXCEPTION
            'run_screening: p_entity_type debe ser PERSON o COMPANY, recibido: %',
            p_entity_type;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.run_screening(text, uuid, text[]) IS
    'Corre screening para una entity (PERSON o COMPANY), computa similarity '
    'contra todas las entries relevantes, filtra con threshold por lista '
    '(resolve_similarity_threshold), deduplica contra alerts existentes y '
    'retorna matches (incluyendo los recien creados y los preexistentes).';

COMMIT;

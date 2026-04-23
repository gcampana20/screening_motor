-- =============================================================================
-- V009__run_screening_country_aware_validation.sql
-- -----------------------------------------------------------------------------
-- Cierra el loop de V008: hace que calculate_similarity valide cada tax_id con
-- su propio país (no un solo p_country compartido), y que run_screening pase
-- esos países desde person/company/screening_list_entry.
--
-- Gap de V008 que V009 arregla:
--   En V008, calculate_similarity recibía un único p_country y validaba
--   ambos tax_ids con él. Eso es incorrecto cuando el entity y el entry son de
--   jurisdicciones distintas (ej: person AR vs entry OFAC con country=US):
--   validar un CUIT argentino con reglas US-SSN da INVALID_FORMAT espurio.
--
-- Cambios:
--   1. calculate_similarity recibe p_country1 (entity) y p_country2 (entry).
--   2. La validación corre SIEMPRE (no solo cuando se pasa country), porque:
--      - validate_tax_id con country NULL igual detecta PLACEHOLDER/SEQUENTIAL
--        vía checks genéricos.
--      - Beneficio colateral: arregla el bug latente V006 donde un match de
--        placeholder "99999999999 = 99999999999" inflaba el score aún sin
--        country especificado.
--   3. run_screening pasa:
--      - Person branch: p.country, sle.country.
--      - Company branch: c.country, sle.country.
--
-- Sobre la columna usada:
--   Elegimos `country` (residencia/domicilio) y NO `nationality` (ciudadanía),
--   porque el tax_id está ligado a dónde fue emitido, que típicamente coincide
--   con residencia. Si en el futuro se quiere incluir nationality para EDD
--   (Enhanced Due Diligence), va en un motor separado — no se mezcla con
--   identity matching.
--
-- Compatibilidad:
--   DROP explícito de los dos overloads previos de calculate_similarity
--   (V006: 7 args; V008: 8 args) para eliminar ambigüedad de resolución.
--   La versión final es 9 args.
--
-- Idempotencia:
--   V009 re-runnable: los DROP son IF EXISTS, los CREATE son OR REPLACE.
-- =============================================================================

BEGIN;

-- =============================================================================
-- SECCIÓN 1: calculate_similarity con dos países
-- =============================================================================

-- Limpiamos cualquier overload previo para que la resolución quede inequívoca.
-- CREATE OR REPLACE no sirve acá porque cambia la signature (cantidad de args).
DROP FUNCTION IF EXISTS public.calculate_similarity(
    text, text, text, text, date, date, numeric
);
DROP FUNCTION IF EXISTS public.calculate_similarity(
    text, text, text, text, date, date, numeric, text
);

CREATE OR REPLACE FUNCTION public.calculate_similarity(
    p_name1       text,
    p_name2       text,
    p_tax_id1     text    DEFAULT NULL,
    p_tax_id2     text    DEFAULT NULL,
    p_birth_date1 date    DEFAULT NULL,
    p_birth_date2 date    DEFAULT NULL,
    p_threshold   numeric DEFAULT 0.8,
    p_country1    text    DEFAULT NULL,  -- país del entity (input)
    p_country2    text    DEFAULT NULL   -- país del entry (list)
)
RETURNS TABLE(
    similarity_score numeric,
    match_type       text,
    details          jsonb
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_name_similarity   numeric := 0;
    v_tax_id_score      numeric := 0;
    v_birth_date_score  numeric := 0;
    v_total_weight      numeric := 0;
    v_weighted_sum      numeric := 0;
    v_has_tax_id        boolean := (p_tax_id1 IS NOT NULL AND p_tax_id2 IS NOT NULL);
    v_has_birth_date    boolean := (p_birth_date1 IS NOT NULL AND p_birth_date2 IS NOT NULL);
    v_final_score       numeric := 0;

    -- Tax-id validation state
    v_input_validation  jsonb   := NULL;
    v_entry_validation  jsonb   := NULL;
    v_tax_id_weight     numeric := 0.3;  -- default full weight
    v_tax_id_downgraded boolean := false;
    v_tax_id_reason     text    := NULL;
    v_input_cat         text;
    v_entry_cat         text;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Nombre: siempre contribuye.
    -- -------------------------------------------------------------------------
    v_name_similarity := similarity(
        public.normalize_name(p_name1),
        public.normalize_name(p_name2)
    );
    v_total_weight := v_total_weight + 0.5;
    v_weighted_sum := v_weighted_sum + v_name_similarity * 0.5;

    -- -------------------------------------------------------------------------
    -- 2. Tax ID: contribuye si ambos lados proveen valor, con ajuste por
    --    validación INDEPENDIENTE por país (input usa p_country1, entry
    --    usa p_country2). Validamos siempre — si country es NULL, los
    --    checks genéricos igual detectan PLACEHOLDER/SEQUENTIAL.
    -- -------------------------------------------------------------------------
    IF v_has_tax_id THEN
        IF public.normalize_tax_id(p_tax_id1) = public.normalize_tax_id(p_tax_id2) THEN
            v_tax_id_score := 1;
        END IF;

        v_input_validation := public.validate_tax_id(p_tax_id1, p_country1);
        v_entry_validation := public.validate_tax_id(p_tax_id2, p_country2);
        v_input_cat := v_input_validation->>'category';
        v_entry_cat := v_entry_validation->>'category';

        -- Placeholders / rotos / ausentes en cualquier lado → peso 0.
        -- El match no informa identidad (colisión altísima o comparabilidad rota).
        IF v_input_cat IN ('PLACEHOLDER','SEQUENTIAL','INVALID_FORMAT',
                           'TOO_SHORT','TOO_LONG','MISSING')
           OR v_entry_cat IN ('PLACEHOLDER','SEQUENTIAL','INVALID_FORMAT',
                              'TOO_SHORT','TOO_LONG','MISSING') THEN
            v_tax_id_weight := 0;
            v_tax_id_downgraded := true;
            v_tax_id_reason := 'untrusted_tax_id_zero_weight';

        -- Checksum inválido en alguno, sin placeholders → peso mitad.
        -- Colisión baja entre checksums inválidos random → algo de signal
        -- de identidad persiste.
        ELSIF v_input_cat = 'INVALID_CHECKSUM'
           OR v_entry_cat = 'INVALID_CHECKSUM' THEN
            v_tax_id_weight := 0.15;
            v_tax_id_downgraded := true;
            v_tax_id_reason := 'invalid_checksum_half_weight';

        -- VALID o UNKNOWN_COUNTRY (pasó genérico pero no se validó por país):
        -- peso completo. UNKNOWN_COUNTRY significa "no pudimos validar con
        -- reglas country-specific", no "es inválido".
        END IF;

        v_total_weight := v_total_weight + v_tax_id_weight;
        v_weighted_sum := v_weighted_sum + v_tax_id_score * v_tax_id_weight;
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Fecha de nacimiento: contribuye si ambos lados proveen valor.
    -- -------------------------------------------------------------------------
    IF v_has_birth_date THEN
        IF p_birth_date1 = p_birth_date2 THEN
            v_birth_date_score := 1;
        ELSIF EXTRACT(YEAR FROM p_birth_date1) = EXTRACT(YEAR FROM p_birth_date2) THEN
            v_birth_date_score := 0.5;
        END IF;
        v_total_weight := v_total_weight + 0.2;
        v_weighted_sum := v_weighted_sum + v_birth_date_score * 0.2;
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Score final normalizado. v_total_weight siempre >= 0.5.
    -- -------------------------------------------------------------------------
    v_final_score := (v_weighted_sum / v_total_weight) * 100;
    similarity_score := round(v_final_score, 2);

    -- -------------------------------------------------------------------------
    -- 5. Clasificación del tipo de match. TAX_ID_EXACT solo si el peso
    --    efectivo fue > 0 (no reportar TAX_ID_EXACT para matches que quedaron
    --    degradados a 0).
    -- -------------------------------------------------------------------------
    IF v_tax_id_score = 1 AND v_tax_id_weight > 0 THEN
        match_type := 'TAX_ID_EXACT';
    ELSIF v_name_similarity >= p_threshold AND v_birth_date_score = 1 THEN
        match_type := 'NAME_AND_BIRTHDATE';
    ELSIF v_name_similarity >= p_threshold THEN
        match_type := 'NAME_FUZZY';
    ELSE
        match_type := 'NO_MATCH';
    END IF;

    -- -------------------------------------------------------------------------
    -- 6. Details jsonb con toda la info (weighting + validación tax_id).
    --    tax_id_validation.input / entry exponen el país y categoría usados.
    -- -------------------------------------------------------------------------
    details := jsonb_build_object(
        'name_similarity',  round(v_name_similarity::numeric, 4),
        'tax_id_match',     v_tax_id_score,
        'birth_date_score', v_birth_date_score,
        'threshold',        p_threshold,
        'weights_applied',  jsonb_build_object(
            'name',       0.5,
            'tax_id',     CASE WHEN v_has_tax_id     THEN v_tax_id_weight ELSE 0 END,
            'birth_date', CASE WHEN v_has_birth_date THEN 0.2             ELSE 0 END,
            'total',      v_total_weight
        ),
        'tax_id_validation', CASE
            WHEN v_input_validation IS NULL AND v_entry_validation IS NULL THEN NULL
            ELSE jsonb_build_object(
                'input',             v_input_validation,
                'entry',             v_entry_validation,
                'effective_weight',  v_tax_id_weight,
                'downgraded',        v_tax_id_downgraded,
                'downgrade_reason',  v_tax_id_reason
            )
        END
    );
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.calculate_similarity(
    text, text, text, text, date, date, numeric, text, text
) IS
    'Calcula similaridad ponderada entre dos entidades. Cada tax_id se valida '
    'con su propio país (p_country1 para el input, p_country2 para el entry). '
    'Peso del tax_id se ajusta según validación: 0 si placeholder/secuencial/roto, '
    '0.15 si invalid_checksum, 0.30 si valid. details.tax_id_validation expone '
    'la decisión para auditoría.';


-- =============================================================================
-- SECCIÓN 2: run_screening pasando país del entity y del entry
-- =============================================================================

CREATE OR REPLACE FUNCTION public.run_screening(
    p_entity_type text,
    p_entity_id   uuid,
    p_lists       text[] DEFAULT NULL::text[]
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
                sle.birth_date,
                0.8,            -- threshold default (explícito por claridad)
                p.country,      -- V009: país del entity (lado 1)
                sle.country     -- V009: país del entry (lado 2)
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
            x.id::uuid                      AS alert_id,
            x.name::text                    AS list_name,
            x.screening_list_entry_id::uuid AS matched_entry_id,
            x.similarity_score::numeric,
            x.detail::jsonb                 AS match_details
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
                NULL,           -- companies no tienen birth_date
                NULL,
                0.8,            -- threshold default
                c.country,      -- V009: país del entity (lado 1)
                sle.country     -- V009: país del entry (lado 2)
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
            x.id::uuid                      AS alert_id,
            x.name::text                    AS list_name,
            x.screening_list_entry_id::uuid AS matched_entry_id,
            x.similarity_score::numeric,
            x.detail::jsonb                 AS match_details
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
    'Ejecuta screening de un entity (PERSON o COMPANY) contra las listas. '
    'V009: pasa country del entity y del entry a calculate_similarity para '
    'validación country-aware del tax_id.';

COMMIT;

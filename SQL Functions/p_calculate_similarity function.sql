DROP FUNCTION IF EXISTS public.calculate_similarity(
    TEXT, TEXT, TEXT, TEXT, DATE, DATE, NUMERIC
);

CREATE OR REPLACE FUNCTION public.calculate_similarity(
    p_name1 TEXT,
    p_name2 TEXT,
    p_tax_id1 TEXT DEFAULT NULL,
    p_tax_id2 TEXT DEFAULT NULL,
    p_birth_date1 DATE DEFAULT NULL,
    p_birth_date2 DATE DEFAULT NULL,
    p_threshold NUMERIC DEFAULT 0.8
)
RETURNS TABLE (
    similarity_score NUMERIC,
    match_type TEXT,
    details JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_name_similarity NUMERIC := 0;
    v_tax_id_score NUMERIC := 0;
    v_birth_date_score NUMERIC := 0;
    v_final_score NUMERIC := 0;
BEGIN
    -- Similaridad de nombres (0 a 1)
    v_name_similarity := similarity(
        public.normalize_name(p_name1),
        public.normalize_name(p_name2)
    );

    -- Match exacto de tax_id normalizado
    IF p_tax_id1 IS NOT NULL
       AND p_tax_id2 IS NOT NULL
       AND public.normalize_tax_id(p_tax_id1) = public.normalize_tax_id(p_tax_id2) THEN
        v_tax_id_score := 1;
    END IF;

    -- Match de fecha de nacimiento
    IF p_birth_date1 IS NOT NULL AND p_birth_date2 IS NOT NULL THEN
        IF p_birth_date1 = p_birth_date2 THEN
            v_birth_date_score := 1;
        ELSIF EXTRACT(YEAR FROM p_birth_date1) = EXTRACT(YEAR FROM p_birth_date2) THEN
            v_birth_date_score := 0.5;
        END IF;
    END IF;

    -- Score final (0 a 100)
    v_final_score := (
        v_name_similarity * 0.5 +
        v_tax_id_score * 0.3 +
        v_birth_date_score * 0.2
    ) * 100;

    similarity_score := round(v_final_score, 2);

    IF v_tax_id_score = 1 THEN
        match_type := 'TAX_ID_EXACT';
    ELSIF v_name_similarity >= p_threshold AND v_birth_date_score = 1 THEN
        match_type := 'NAME_AND_BIRTHDATE';
    ELSIF v_name_similarity >= p_threshold THEN
        match_type := 'NAME_FUZZY';
    ELSE
        match_type := 'NO_MATCH';
    END IF;

    details := jsonb_build_object(
        'name_similarity', round(v_name_similarity::numeric, 4),
        'tax_id_match', v_tax_id_score,
        'birth_date_score', v_birth_date_score,
        'threshold', p_threshold
    );

    RETURN NEXT;
END;
$$;
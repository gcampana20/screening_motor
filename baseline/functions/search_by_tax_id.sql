DROP FUNCTION IF EXISTS public.search_by_tax_id(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.search_by_tax_id(
    p_tax_id TEXT,
    p_country TEXT DEFAULT NULL
)
RETURNS TABLE (
    list_name TEXT,
    entry_id UUID,
    matched_tax_id TEXT,
    match_type TEXT,
    confidence NUMERIC
)
LANGUAGE sql
AS $$
    SELECT
        l.name AS list_name,
        sle.id AS entry_id,
        sle.tax_id AS matched_tax_id,
        CASE
            WHEN sle.tax_id = p_tax_id THEN 'EXACT'
            WHEN sle.tax_id_normalized = public.normalize_tax_id(p_tax_id) THEN 'NORMALIZED'
            ELSE 'FUZZY'
        END AS match_type,
        CASE
            WHEN sle.tax_id = p_tax_id THEN 100
            WHEN sle.tax_id_normalized = public.normalize_tax_id(p_tax_id) THEN 95
            ELSE 80
        END AS confidence
    FROM public.screening_list_entry sle
    JOIN public.list l
        ON l.id = sle.list_id
    WHERE
        sle.tax_id_normalized = public.normalize_tax_id(p_tax_id)
        AND (
            p_country IS NULL
            OR sle.country = p_country
        );
$$;
CREATE OR REPLACE FUNCTION public.normalize_tax_id(tax_id TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN tax_id IS NULL THEN NULL
        ELSE regexp_replace(lower(trim(tax_id)),'[^a-z0-9\s]', '', 'g')
    END;
$$;
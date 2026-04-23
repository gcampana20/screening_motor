CREATE OR REPLACE FUNCTION public.normalize_name(p_name TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_name IS NULL THEN NULL
        ELSE trim(
            regexp_replace(
                regexp_replace(
                    lower(unaccent(p_name)),
                    '[^a-z0-9]+', ' ', 'g'
                ),
                '\s+', ' ', 'g'
            )
        )
    END;
$$;
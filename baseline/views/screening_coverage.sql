CREATE OR REPLACE VIEW public.vw_screening_coverage AS
SELECT
    p.tenant_id,
    COUNT(*) AS total_persons,
    COUNT(*) FILTER (
        WHERE EXISTS (
            SELECT 1
            FROM public.alert a
            WHERE a.person_id = p.id
        )
    ) AS screened_persons,
    ROUND(
        COUNT(*) FILTER (
            WHERE EXISTS (
                SELECT 1
                FROM public.alert a
                WHERE a.person_id = p.id
            )
        )::numeric
        / NULLIF(COUNT(*), 0)::numeric,
        4
    ) AS screening_coverage_rate
FROM public.person p
GROUP BY p.tenant_id;
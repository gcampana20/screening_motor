CREATE OR REPLACE VIEW public.vw_screening_metrics AS
SELECT
    a.tenant_id,
    a.name AS list_name,
    COUNT(*) AS total_alerts,
    COUNT(*) FILTER (WHERE a.status = 'PENDING') AS pending_alerts,
    COUNT(*) FILTER (WHERE a.status = 'REVIEWING') AS reviewing_alerts,
    COUNT(*) FILTER (WHERE a.status = 'CONFIRMED') AS confirmed_alerts,
    COUNT(*) FILTER (WHERE a.status = 'DISMISSED') AS dismissed_alerts,
    ROUND(
        COUNT(*) FILTER (WHERE a.status = 'DISMISSED')::numeric
        / NULLIF(
            COUNT(*) FILTER (WHERE a.status IN ('CONFIRMED', 'DISMISSED')),
            0
        )::numeric,
        4
    ) AS false_positive_rate
FROM public.alert a
GROUP BY
    a.tenant_id,
    a.name;
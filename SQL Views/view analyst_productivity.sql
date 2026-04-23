CREATE OR REPLACE VIEW public.vw_analyst_productivity AS
SELECT
    a.tenant_id,
    a.analyst_id,
    an.name AS analyst_name,
    COUNT(*) AS total_alerts_assigned,
    COUNT(*) FILTER (WHERE a.status = 'PENDING') AS pending_alerts,
    COUNT(*) FILTER (WHERE a.status = 'REVIEWING') AS reviewing_alerts,
    COUNT(*) FILTER (WHERE a.status = 'CONFIRMED') AS confirmed_alerts,
    COUNT(*) FILTER (WHERE a.status = 'DISMISSED') AS dismissed_alerts
FROM public.alert a
LEFT JOIN public.analyst an
    ON an.id = a.analyst_id
GROUP BY
    a.tenant_id,
    a.analyst_id,
    an.name;
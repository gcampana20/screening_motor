CREATE OR REPLACE VIEW public.vw_pending_alerts_by_analyst AS
SELECT
    a.tenant_id,
    a.analyst_id,
    an.name AS analyst_name,
    COUNT(*) AS pending_alerts
FROM public.alert a
LEFT JOIN public.analyst an
    ON an.id = a.analyst_id
WHERE a.status IN ('PENDING', 'REVIEWING')
GROUP BY
    a.tenant_id,
    a.analyst_id,
    an.name;
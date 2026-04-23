CREATE OR REPLACE VIEW public.vw_alert_aging AS
SELECT
    a.id AS alert_id,
    a.tenant_id,
    a.person_id,
    a.company_id,
    a.name AS list_name,
    a.status,
    a.created_at,
    a.updated_at,
    now() - a.created_at AS aging_interval,
    EXTRACT(DAY FROM now() - a.created_at) AS aging_days
FROM public.alert a;
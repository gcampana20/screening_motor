-- =============================================================================
-- seeds/seed_data.sql
-- -----------------------------------------------------------------------------
-- Dataset de demo que ejercita las features del motor:
--   - Multi-tenancy (2 tenants, aislamiento RLS).
--   - Jurisdicciones múltiples (AR, CL, US, BR) para validación country-aware.
--   - Un tax_id placeholder para ejercitar V008/V009 (colapso de peso).
--   - Listas globales (SANCTIONS, PEP con tenant_id NULL) + tenant-scoped
--     (INTERNAL).
--   - Alertas pre-existentes para popular los dashboards (alert_aging,
--     pending_alerts_by_analyst).
--
-- Todo con ON CONFLICT DO NOTHING para permitir reruns seguros. UUIDs
-- hardcoded y legibles para facilitar debugging manual.
--
-- Para resetear y recargar: docker compose down -v && docker compose up -d
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Tenants
-- -----------------------------------------------------------------------------
INSERT INTO public.tenant (id, name) VALUES
    ('10000000-0000-0000-0000-000000000001', 'Acme Compliance AR'),
    ('10000000-0000-0000-0000-000000000002', 'Globex Compliance LATAM')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2. Analistas (2 por tenant)
-- -----------------------------------------------------------------------------
INSERT INTO public.analyst (id, name, tenant_id) VALUES
    ('20000000-0000-0000-0000-000000000001', 'Ana Torres',      '10000000-0000-0000-0000-000000000001'),
    ('20000000-0000-0000-0000-000000000002', 'Martín Lopez',    '10000000-0000-0000-0000-000000000001'),
    ('20000000-0000-0000-0000-000000000003', 'Sofía Rodríguez', '10000000-0000-0000-0000-000000000002'),
    ('20000000-0000-0000-0000-000000000004', 'Carlos Díaz',     '10000000-0000-0000-0000-000000000002')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. Persons — mix de jurisdicciones y edge cases
-- -----------------------------------------------------------------------------
-- tax_id es TEXT post V001 para soportar CUIT con guiones, SSN, etc.
INSERT INTO public.person (id, first_name, last_name, tax_id, birth_date, country, tenant_id) VALUES
    -- AR válidos
    ('30000000-0000-0000-0000-000000000001', 'Juan',    'Pérez',      '20-12345678-6', '1980-01-15', 'AR',
     '10000000-0000-0000-0000-000000000001'),
    ('30000000-0000-0000-0000-000000000002', 'María',   'González',   '27-30123456-4', '1985-03-22', 'AR',
     '10000000-0000-0000-0000-000000000001'),
    -- AR con placeholder (ejercita V008: peso tax_id colapsa a 0)
    ('30000000-0000-0000-0000-000000000003', 'Ricardo', 'Fernández',  '99999999999',   '1975-07-10', 'AR',
     '10000000-0000-0000-0000-000000000001'),
    -- CL válido
    ('30000000-0000-0000-0000-000000000004', 'Pedro',   'Muñoz',      '12.345.678-5',  '1990-11-05', 'CL',
     '10000000-0000-0000-0000-000000000002'),
    -- US válido
    ('30000000-0000-0000-0000-000000000005', 'John',    'Smith',      '547-82-9341',   '1978-09-20', 'US',
     '10000000-0000-0000-0000-000000000002'),
    -- BR válido (CPF)
    ('30000000-0000-0000-0000-000000000006', 'João',    'Silva',      '123.456.789-09','1982-04-12', 'BR',
     '10000000-0000-0000-0000-000000000002')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4. Companies
-- -----------------------------------------------------------------------------
-- Nota: company.tax_id es bigint en el DDL base; guardamos solo dígitos.
INSERT INTO public.company (id, name, tax_id, country, tenant_id) VALUES
    ('40000000-0000-0000-0000-000000000001', 'Constructora del Sur SA',    30712345674, 'AR',
     '10000000-0000-0000-0000-000000000001'),
    ('40000000-0000-0000-0000-000000000002', 'Globex Latam Holdings LLC',  12345678901, 'US',
     '10000000-0000-0000-0000-000000000002')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 5. Listas de screening
-- -----------------------------------------------------------------------------
-- Listas globales (tenant_id = NULL): visibles a todos los tenants via RLS.
-- Listas tenant-scoped: solo visibles para ese tenant.
INSERT INTO public.list (id, name, type, tenant_id) VALUES
    -- Globales
    ('50000000-0000-0000-0000-000000000001', 'OFAC SDN',        'SANCTIONS',     NULL),
    ('50000000-0000-0000-0000-000000000002', 'UN Consolidated', 'SANCTIONS',     NULL),
    ('50000000-0000-0000-0000-000000000003', 'PEP Global',      'PEP',           NULL),
    ('50000000-0000-0000-0000-000000000004', 'Adverse Media',   'ADVERSE_MEDIA', NULL),
    -- Tenant-scoped (INTERNAL: una blacklist propia de cada compliance team)
    ('50000000-0000-0000-0000-000000000005', 'Acme Internal Blacklist', 'INTERNAL',
     '10000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 6. Screening list entries
-- -----------------------------------------------------------------------------
-- Mix diseñado para que los seeds generen matches cuando se corre run_screening
-- contra las persons/companies de arriba. Notar que el screening_list_entry NO
-- tiene tenant_id: hereda visibilidad via list.
INSERT INTO public.screening_list_entry
    (id, list_id, entry_type, full_name, tax_id, birth_date, country) VALUES

    -- OFAC SDN entries (global)
    ('60000000-0000-0000-0000-000000000001',
     '50000000-0000-0000-0000-000000000001', 'PERSON',
     'Juan Pérez',   '20-12345678-6', '1980-01-15', 'AR'),     -- match exacto p.30...01

    ('60000000-0000-0000-0000-000000000002',
     '50000000-0000-0000-0000-000000000001', 'PERSON',
     'Jon Smyth',    '547-82-9341',   '1978-09-20', 'US'),     -- match fuzzy p.30...05

    ('60000000-0000-0000-0000-000000000003',
     '50000000-0000-0000-0000-000000000001', 'COMPANY',
     'Globex Latam Holdings', '12345678901', NULL, 'US'),      -- match company c.40...02

    -- UN Consolidated
    ('60000000-0000-0000-0000-000000000004',
     '50000000-0000-0000-0000-000000000002', 'PERSON',
     'Ricardo Hernández', '99999999999', '1975-07-10', 'AR'),  -- match fuzzy p.30...03
                                                               -- pero con placeholder → peso 0

    -- PEP Global
    ('60000000-0000-0000-0000-000000000005',
     '50000000-0000-0000-0000-000000000003', 'PERSON',
     'Maria Gonzales', '27-30123456-4', NULL, 'AR'),           -- match p.30...02

    ('60000000-0000-0000-0000-000000000006',
     '50000000-0000-0000-0000-000000000003', 'PERSON',
     'Pedro Muñoz', '12.345.678-5', '1990-11-05', 'CL'),       -- match p.30...04

    -- Adverse Media
    ('60000000-0000-0000-0000-000000000007',
     '50000000-0000-0000-0000-000000000004', 'PERSON',
     'João Silva', '123.456.789-09', '1982-04-12', 'BR'),      -- match p.30...06

    -- Acme Internal Blacklist (tenant 1)
    ('60000000-0000-0000-0000-000000000008',
     '50000000-0000-0000-0000-000000000005', 'COMPANY',
     'Constructora Del Sur', '30712345674', NULL, 'AR')        -- match c.40...01
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 7. Alerts pre-existentes (para popular dashboards)
-- -----------------------------------------------------------------------------
-- Una alerta PENDING vieja (aging), una REVIEWING reciente, una CONFIRMED
-- cerrada. Así alert_aging y pending_alerts_by_analyst devuelven data visible.
-- detail ya es jsonb post V010.
INSERT INTO public.alert (
    id, created_at, updated_at, name, type,
    person_id, company_id, tenant_id, screening_list_entry_id,
    status, analyst_id, similarity_score, detail
) VALUES
    -- Alerta PENDING vieja (30 días) — aparecerá en alert_aging bucket >30d.
    ('70000000-0000-0000-0000-000000000001',
     now() - interval '30 days', now() - interval '30 days',
     'OFAC SDN', 'TAX_ID_EXACT',
     '30000000-0000-0000-0000-000000000001', NULL,
     '10000000-0000-0000-0000-000000000001',
     '60000000-0000-0000-0000-000000000001',
     'PENDING', NULL, 100.00,
     jsonb_build_object(
         'name_similarity', 1.0, 'tax_id_match', 1, 'birth_date_score', 1,
         'weights_applied', jsonb_build_object('name', 0.5, 'tax_id', 0.3, 'birth_date', 0.2, 'total', 1.0))),

    -- Alerta REVIEWING reciente, asignada a un analista.
    ('70000000-0000-0000-0000-000000000002',
     now() - interval '3 days', now() - interval '1 day',
     'PEP Global', 'NAME_AND_BIRTHDATE',
     '30000000-0000-0000-0000-000000000002', NULL,
     '10000000-0000-0000-0000-000000000001',
     '60000000-0000-0000-0000-000000000005',
     'REVIEWING', '20000000-0000-0000-0000-000000000001', 82.50,
     jsonb_build_object(
         'name_similarity', 0.95, 'tax_id_match', 1, 'birth_date_score', 0,
         'weights_applied', jsonb_build_object('name', 0.5, 'tax_id', 0.3, 'birth_date', 0.2, 'total', 1.0))),

    -- Alerta CONFIRMED (cerrada) — ejercita analyst_productivity.
    ('70000000-0000-0000-0000-000000000003',
     now() - interval '10 days', now() - interval '2 days',
     'Acme Internal Blacklist', 'NAME_FUZZY',
     NULL, '40000000-0000-0000-0000-000000000001',
     '10000000-0000-0000-0000-000000000001',
     '60000000-0000-0000-0000-000000000008',
     'CONFIRMED', '20000000-0000-0000-0000-000000000002', 91.30,
     jsonb_build_object(
         'name_similarity', 0.91, 'tax_id_match', 1, 'birth_date_score', 0,
         'weights_applied', jsonb_build_object('name', 0.5, 'tax_id', 0.3, 'birth_date', 0.2, 'total', 0.8)))
ON CONFLICT (id) DO NOTHING;

COMMIT;

-- -----------------------------------------------------------------------------
-- Resumen para verificación manual post-seed (logs informativos).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_tenants  int;
    v_persons  int;
    v_entries  int;
    v_alerts   int;
BEGIN
    SELECT count(*) INTO v_tenants  FROM public.tenant;
    SELECT count(*) INTO v_persons  FROM public.person;
    SELECT count(*) INTO v_entries  FROM public.screening_list_entry;
    SELECT count(*) INTO v_alerts   FROM public.alert;
    RAISE NOTICE 'Seeds OK: % tenants, % persons, % sle, % alerts',
                 v_tenants, v_persons, v_entries, v_alerts;
END $$;

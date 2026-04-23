-- =============================================================================
-- test_V009__run_screening_country_aware_validation.sql
-- -----------------------------------------------------------------------------
-- Valida V009: calculate_similarity con dos países (p_country1/p_country2)
-- y run_screening propagando country del entity y del entry.
--
-- Secciones:
--   1. calculate_similarity: dos países independientes.
--   2. calculate_similarity: fix del bug latente de V006 (placeholder
--      colisiona con NULL country → peso 0 por checks genéricos).
--   3. calculate_similarity: cross-jurisdiction sin falsos positivos.
--   4. calculate_similarity: clasificación TAX_ID_EXACT no se dispara
--      cuando el tax_id fue degradado a peso 0.
--   5. run_screening: integración end-to-end con person AR / entry AR.
--   6. run_screening: integración end-to-end con person AR / entry US
--      (jurisdicciones distintas, no debe romper por reglas cruzadas).
--   7. Cleanup.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. calculate_similarity: dos países independientes
-- =============================================================================

-- 1.1 AR válido vs AR válido (mismos CUITs válidos) → peso tax_id = 0.30,
--     score alto.
SELECT 'T1.1 AR-AR válido' AS test, similarity_score, match_type,
       details->'tax_id_validation'->>'effective_weight' AS eff_weight,
       details->'tax_id_validation'->'input'->>'category'  AS input_cat,
       details->'tax_id_validation'->'entry'->>'category'  AS entry_cat
FROM public.calculate_similarity(
    'Juan Perez', 'Juan Perez',
    '20-12345678-6', '20-12345678-6',
    NULL, NULL,
    0.8, 'AR', 'AR'
);
-- Esperado: similarity_score=100, match_type=TAX_ID_EXACT, eff_weight=0.30,
--           input_cat=VALID, entry_cat=VALID.

-- 1.2 AR válido vs US válido, nombres distintos, tax_ids distintos:
--     ambos validan con sus propios países, peso pleno, match_type=NO_MATCH.
-- Nota: el SSN canónico 123-45-6789 califica como SEQUENTIAL (dígitos
--       consecutivos ascendentes) por el check genérico, así que usamos
--       un SSN sintético que no dispara placeholder/sequential.
SELECT 'T1.2 AR-US válidos, distintos' AS test, similarity_score, match_type,
       details->'tax_id_validation'->>'effective_weight' AS eff_weight,
       details->'tax_id_validation'->'input'->>'category'  AS input_cat,
       details->'tax_id_validation'->'entry'->>'category'  AS entry_cat
FROM public.calculate_similarity(
    'Juan Perez', 'John Smith',
    '20-12345678-6', '547-82-9341',
    NULL, NULL,
    0.8, 'AR', 'US'
);
-- Esperado: eff_weight=0.30, input_cat=VALID, entry_cat=VALID,
--           match_type=NO_MATCH (nombres no se parecen).

-- =============================================================================
-- 2. Bug latente de V006: placeholder colisiona con NULL country
-- =============================================================================

-- 2.1 Dos placeholders idénticos SIN country declarado.
--     Pre-V009: v_tax_id_score=1, peso 0.30 → inflaba score.
--     Post-V009: validación corre igual, detecta PLACEHOLDER vía check
--                genérico, peso 0, match_type≠TAX_ID_EXACT.
SELECT 'T2.1 placeholder colisiona sin country' AS test,
       similarity_score, match_type,
       details->'tax_id_validation'->>'effective_weight' AS eff_weight,
       details->'tax_id_validation'->>'downgrade_reason' AS reason,
       details->'tax_id_validation'->'input'->>'category'  AS input_cat,
       details->'tax_id_validation'->'entry'->>'category'  AS entry_cat
FROM public.calculate_similarity(
    'Juan Perez', 'Pedro Gomez',
    '99999999999', '99999999999',
    NULL, NULL,
    0.8, NULL, NULL
);
-- Esperado: eff_weight=0, reason=untrusted_tax_id_zero_weight,
--           input_cat=PLACEHOLDER, entry_cat=PLACEHOLDER,
--           match_type=NO_MATCH (solo pesa el nombre, que no matchea).

-- 2.2 Secuencial "12345678901" colisiona.
SELECT 'T2.2 sequential colisiona' AS test,
       similarity_score, match_type,
       details->'tax_id_validation'->>'effective_weight' AS eff_weight,
       details->'tax_id_validation'->'input'->>'category' AS input_cat,
       details->'tax_id_validation'->'entry'->>'category' AS entry_cat
FROM public.calculate_similarity(
    'Juan Perez', 'Pedro Gomez',
    '12345678901', '12345678901',
    NULL, NULL,
    0.8, NULL, NULL
);
-- Esperado: eff_weight=0, input_cat=SEQUENTIAL, entry_cat=SEQUENTIAL.

-- =============================================================================
-- 3. Cross-jurisdiction: validación por país no genera falsos positivos
-- =============================================================================

-- 3.1 CUIT AR válido como input, entry con country=US.
--     Pre-V009 (p_country único): si llamás con p_country='US',
--     validás el CUIT como SSN → INVALID_FORMAT espurio.
--     Post-V009: input se valida con AR → VALID, entry con US → VALID.
SELECT 'T3.1 input AR / entry US, ambos válidos' AS test,
       similarity_score, match_type,
       details->'tax_id_validation'->'input'->>'category' AS input_cat,
       details->'tax_id_validation'->'entry'->>'category' AS entry_cat,
       details->'tax_id_validation'->>'effective_weight' AS eff_weight
FROM public.calculate_similarity(
    'Juan Perez', 'Juan Perez',
    '20-12345678-6', '547-82-9341',
    NULL, NULL,
    0.8, 'AR', 'US'
);
-- Esperado: input_cat=VALID (AR), entry_cat=VALID (US),
--           eff_weight=0.30, match_type=NAME_FUZZY (tax_ids distintos,
--           nombre idéntico).

-- 3.2 Input AR con checksum inválido, entry US válido.
--     Peso baja a 0.15 (invalid_checksum en un lado, sin placeholders).
SELECT 'T3.2 input AR bad checksum / entry US ok' AS test,
       similarity_score, match_type,
       details->'tax_id_validation'->'input'->>'category' AS input_cat,
       details->'tax_id_validation'->'entry'->>'category' AS entry_cat,
       details->'tax_id_validation'->>'effective_weight' AS eff_weight,
       details->'tax_id_validation'->>'downgrade_reason' AS reason
FROM public.calculate_similarity(
    'Juan Perez', 'Juan Perez',
    '20-12345678-0', '547-82-9341',    -- CUIT con dígito verif. errado
    NULL, NULL,
    0.8, 'AR', 'US'
);
-- Esperado: input_cat=INVALID_CHECKSUM, entry_cat=VALID,
--           eff_weight=0.15, reason=invalid_checksum_half_weight.

-- =============================================================================
-- 4. TAX_ID_EXACT no dispara cuando el peso fue degradado a 0
-- =============================================================================

-- 4.1 Nombres iguales + placeholders iguales → NO TAX_ID_EXACT.
--     v_tax_id_score=1 pero v_tax_id_weight=0, por regla del CASE.
SELECT 'T4.1 TAX_ID_EXACT suprimido si peso 0' AS test,
       similarity_score, match_type,
       details->'tax_id_validation'->>'effective_weight' AS eff_weight
FROM public.calculate_similarity(
    'Juan Perez', 'Juan Perez',
    '99999999999', '99999999999',
    NULL, NULL,
    0.8, 'AR', 'AR'
);
-- Esperado: match_type=NAME_FUZZY (no TAX_ID_EXACT), eff_weight=0.

-- =============================================================================
-- 5. run_screening end-to-end: person AR / entry AR
-- =============================================================================

-- Setup: tenant, list, entry, person.
INSERT INTO public.tenant (id, name)
VALUES ('11111111-1111-1111-1111-111111111111', 'Test Tenant V009')
ON CONFLICT DO NOTHING;

INSERT INTO public.list (id, name, type, tenant_id)
VALUES (
    '22222222-2222-2222-2222-222222222222',
    'Test Sanctions V009',
    'SANCTIONS',
    '11111111-1111-1111-1111-111111111111'
)
ON CONFLICT DO NOTHING;

-- screening_list_entry no tiene tenant_id: hereda visibilidad vía list_id.
INSERT INTO public.screening_list_entry (
    id, list_id, entry_type, full_name, tax_id,
    birth_date, country
)
VALUES (
    '33333333-3333-3333-3333-333333333333',
    '22222222-2222-2222-2222-222222222222',
    'PERSON',
    'Juan Perez',
    '20-12345678-6',
    '1980-01-15',
    'AR'
)
ON CONFLICT DO NOTHING;

INSERT INTO public.person (
    id, first_name, last_name, tax_id, birth_date, country, tenant_id
)
VALUES (
    '44444444-4444-4444-4444-444444444444',
    'Juan',
    'Perez',
    '20-12345678-6',
    '1980-01-15',
    'AR',
    '11111111-1111-1111-1111-111111111111'
)
ON CONFLICT DO NOTHING;

-- 5.1 run_screening dispara match con TAX_ID_EXACT y score 100.
SELECT 'T5.1 run_screening AR-AR match' AS test,
       list_name, similarity_score,
       match_details->'tax_id_validation'->>'effective_weight' AS eff_weight,
       match_details->'tax_id_validation'->'input'->>'category' AS input_cat,
       match_details->'tax_id_validation'->'entry'->>'category' AS entry_cat,
       match_details->>'threshold' AS threshold
FROM public.run_screening(
    'PERSON',
    '44444444-4444-4444-4444-444444444444'::uuid,
    ARRAY['Test Sanctions V009']
);
-- Esperado: similarity_score=100, eff_weight=0.30,
--           input_cat=VALID, entry_cat=VALID.

-- =============================================================================
-- 6. run_screening end-to-end: person AR / entry US (cross-jurisdiction)
-- =============================================================================

INSERT INTO public.screening_list_entry (
    id, list_id, entry_type, full_name, tax_id,
    birth_date, country
)
VALUES (
    '55555555-5555-5555-5555-555555555555',
    '22222222-2222-2222-2222-222222222222',
    'PERSON',
    'Juan Perez',
    '547-82-9341',
    '1980-01-15',
    'US'
)
ON CONFLICT DO NOTHING;

-- 6.1 Mismo person AR matchea entry US: cada tax_id se valida con su país,
--     ambos VALID, pero no son iguales → peso pleno, match_type=NAME_AND_BIRTHDATE.
SELECT 'T6.1 run_screening AR entity / US entry' AS test,
       list_name, similarity_score,
       match_details->'tax_id_validation'->'input'->>'category' AS input_cat,
       match_details->'tax_id_validation'->'entry'->>'category' AS entry_cat,
       match_details->'tax_id_validation'->>'effective_weight' AS eff_weight,
       match_details->>'tax_id_match' AS tax_id_match
FROM public.run_screening(
    'PERSON',
    '44444444-4444-4444-4444-444444444444'::uuid,
    ARRAY['Test Sanctions V009']
);
-- Esperado (para el row con entry US):
--   input_cat=VALID (AR), entry_cat=VALID (US), eff_weight=0.30,
--   tax_id_match=0 (distintos).
-- Nota: este SELECT devuelve TODOS los matches de la lista, incluyendo el AR.
--       El interesante es el que corresponde a screening_list_entry 555...

-- =============================================================================
-- 7. Cleanup (dejar la DB limpia para reruns)
-- =============================================================================

DELETE FROM public.alert
WHERE tenant_id = '11111111-1111-1111-1111-111111111111';

DELETE FROM public.person
WHERE id = '44444444-4444-4444-4444-444444444444';

DELETE FROM public.screening_list_entry
WHERE id IN (
    '33333333-3333-3333-3333-333333333333',
    '55555555-5555-5555-5555-555555555555'
);

DELETE FROM public.list
WHERE id = '22222222-2222-2222-2222-222222222222';

DELETE FROM public.tenant
WHERE id = '11111111-1111-1111-1111-111111111111';

ROLLBACK;  -- toda la sección se ejecuta dentro de una tx descartable.

-- =============================================================================
-- V001__tax_id_to_text.sql
-- -----------------------------------------------------------------------------
-- Cambios:
--   1. person.tax_id:  bigint -> text
--   2. company.tax_id: bigint -> text
--   3. Agrega tax_id_normalized como columna GENERATED STORED en person,
--      company y screening_list_entry (reemplaza la manual de sle).
--   4. Agrega country a person (código ISO 3166-1 alpha-2: 'AR', 'US', ...).
--
-- PRECONDICIÓN: la función public.normalize_tax_id(text) debe existir y
-- estar declarada IMMUTABLE (requisito de PostgreSQL para columnas GENERATED).
-- =============================================================================

BEGIN;

-- 1. person.tax_id: bigint -> text.
-- USING tax_id::text convierte los valores existentes. Los ceros iniciales
-- se preservan desde este punto en adelante para datos nuevos.
ALTER TABLE public.person
    ALTER COLUMN tax_id TYPE text USING tax_id::text;

-- 2. company.tax_id: bigint -> text.
ALTER TABLE public.company
    ALTER COLUMN tax_id TYPE text USING tax_id::text;

-- 3. tax_id_normalized en person (columna generada).
ALTER TABLE public.person
    ADD COLUMN tax_id_normalized text
    GENERATED ALWAYS AS (public.normalize_tax_id(tax_id)) STORED;

-- 4. tax_id_normalized en company (columna generada).
ALTER TABLE public.company
    ADD COLUMN tax_id_normalized text
    GENERATED ALWAYS AS (public.normalize_tax_id(tax_id)) STORED;

-- 5. screening_list_entry.tax_id_normalized: hoy es columna común mantenida
-- manualmente en los INSERTs. La reemplazamos por una columna generada.
-- DROP + ADD es seguro: el valor se recalcula desde tax_id sin pérdida.
ALTER TABLE public.screening_list_entry
    DROP COLUMN tax_id_normalized;

ALTER TABLE public.screening_list_entry
    ADD COLUMN tax_id_normalized text
    GENERATED ALWAYS AS (public.normalize_tax_id(tax_id)) STORED;

-- 6. country en person. No se marca NOT NULL porque puede haber filas
-- preexistentes sin valor; endurecer el constraint queda para una migración
-- posterior de data cleanup.
ALTER TABLE public.person
    ADD COLUMN country varchar;

COMMIT;

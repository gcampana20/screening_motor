-- =============================================================================
-- V008__tax_id_validation.sql
-- -----------------------------------------------------------------------------
-- Detección de documentos inválidos/sospechosos (tax_id) y su integración con
-- search_by_tax_id + calculate_similarity.
--
-- Motivación:
--   Un tax_id placeholder (99999999999), inválido por checksum (20-12345678-9
--   con verificador errado) o formato malformado genera dos problemas:
--     1. Colisiones espurias en similarity matching (dos entidades distintas
--        que comparten "99999999999" no son la misma persona).
--     2. Red flag de calidad de onboarding que compliance quiere ver.
--
--   La solución en dos capas:
--     - calculate_similarity colapsa el peso del tax_id a 0 (o 0.15 para
--       INVALID_CHECKSUM no-placeholder) cuando detecta que el signal no es
--       confiable para identity matching → evita alertas fantasma.
--     - La validación queda expuesta en alert.details para que el analista
--       vea la red flag → el fraude no se pierde, solo se categoriza en la
--       dimensión correcta (data quality, no identity matching).
--
-- Países soportados en esta migration:
--   AR  (CUIT/CUIL, 11 dígitos, mod-11 con pesos [5,4,3,2,7,6,5,4,3,2])
--   CL  (RUT, 7-9 chars incl. verificador K/0-9, mod-11 serie 2..7 cíclica)
--   US  (SSN 9 dígitos con reglas area/group/serial; ITIN 9XX-[70-88|90-92|94-99]-XXXX)
--   BR  (CPF 11 dígitos doble mod-11; CNPJ 14 dígitos doble mod-11 con pesos específicos)
--
-- Países no soportados: validate_tax_id cae a chequeos genéricos (longitud,
-- placeholders, secuenciales). category = 'UNKNOWN_COUNTRY' si p_country NULL.
--
-- Contrato del jsonb retornado:
--   {
--     "is_valid":       bool,    // pasa validación técnica (checksum, formato)
--     "is_suspicious":  bool,    // placeholder, secuencial, prefijo raro, etc.
--     "category":       text,    // VALID | INVALID_FORMAT | INVALID_CHECKSUM |
--                                //  PLACEHOLDER | SEQUENTIAL | TOO_SHORT |
--                                //  TOO_LONG | MISSING | UNKNOWN_COUNTRY
--     "reasons":        text[],  // códigos específicos por falla
--     "normalized":     text,    // tax_id tras regex de separadores
--     "country":        text,    // AR | CL | US | BR | null
--     "doc_type":       text     // CUIT | RUT | SSN | ITIN | CPF | CNPJ | UNKNOWN
--   }
--
-- Idempotencia:
--   Todas las funciones usan CREATE OR REPLACE. Firmas no cambian vs V006
--   (salvo calculate_similarity que SUMA un param con DEFAULT NULL, compat).
--   search_by_tax_id cambia su RETURNS TABLE (columnas nuevas al final) →
--   incompatible con DROP + CREATE pero preserva comportamiento para callers
--   que seleccionen columnas explícitas.
-- =============================================================================

BEGIN;

-- =============================================================================
-- SECCIÓN 1: HELPERS GENÉRICOS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 _is_sequential_digits: detecta secuencias asc/desc (incluyendo wrap mod 10)
-- -----------------------------------------------------------------------------
-- "12345678901"  → true  (asc con wrap 9→0→1)
-- "98765432109"  → true  (desc con wrap 0→9 invertido)
-- "01234567890"  → true
-- "12342178901"  → false
-- IMMUTABLE porque depende solo del input.
CREATE OR REPLACE FUNCTION public._is_sequential_digits(p_digits text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_len int := length(p_digits);
    v_asc boolean := true;
    v_desc boolean := true;
    c1 int;
    c2 int;
    i int;
BEGIN
    IF v_len < 3 THEN
        RETURN false;
    END IF;

    FOR i IN 1..v_len - 1 LOOP
        c1 := substr(p_digits, i,     1)::int;
        c2 := substr(p_digits, i + 1, 1)::int;

        -- Ascendente con wrap mod 10: c2 = (c1 + 1) mod 10
        IF c2 <> (c1 + 1) % 10 THEN
            v_asc := false;
        END IF;

        -- Descendente con wrap mod 10: c2 = (c1 - 1 + 10) mod 10
        IF c2 <> (c1 - 1 + 10) % 10 THEN
            v_desc := false;
        END IF;

        -- Early exit si ya falló en ambos
        IF NOT v_asc AND NOT v_desc THEN
            RETURN false;
        END IF;
    END LOOP;

    RETURN v_asc OR v_desc;
END;
$$;

COMMENT ON FUNCTION public._is_sequential_digits(text) IS
    'Detecta secuencias numéricas estrictas asc/desc con wrap mod 10. '
    'Usada para flagear tax_ids tipo 12345678901 como placeholder.';

-- -----------------------------------------------------------------------------
-- 1.2 _validate_tax_id_generic: chequeos agnósticos al país
-- -----------------------------------------------------------------------------
-- Normaliza (quita separadores, mantiene 0-9 y K para CL), aplica:
--   - MISSING:     NULL o vacío
--   - TOO_SHORT:   < 3 dígitos post-normalización
--   - TOO_LONG:    > 20 dígitos post-normalización
--   - PLACEHOLDER: todos el mismo dígito (00...0, 11...1, etc.)
--   - SEQUENTIAL:  secuencial asc/desc con wrap mod 10
--
-- Preserva letra K si existe (CL RUT) pero los checks de secuencial/placeholder
-- solo aplican si todo el string es numérico (la K rompe la secuencia).
CREATE OR REPLACE FUNCTION public._validate_tax_id_generic(p_tax_id text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_normalized text;
    v_len        int;
BEGIN
    IF p_tax_id IS NULL OR length(trim(p_tax_id)) = 0 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'MISSING',
            'reasons',       to_jsonb(ARRAY['EMPTY_OR_NULL']),
            'normalized',    NULL
        );
    END IF;

    v_normalized := upper(regexp_replace(p_tax_id, '[^0-9Kk]', '', 'g'));
    v_len := length(v_normalized);

    IF v_len = 0 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_FORMAT',
            'reasons',       to_jsonb(ARRAY['NO_DIGITS_AFTER_NORMALIZE']),
            'normalized',    v_normalized
        );
    END IF;

    IF v_len < 3 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'TOO_SHORT',
            'reasons',       to_jsonb(ARRAY['LENGTH_BELOW_MIN']),
            'normalized',    v_normalized
        );
    END IF;

    IF v_len > 20 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'TOO_LONG',
            'reasons',       to_jsonb(ARRAY['LENGTH_ABOVE_MAX']),
            'normalized',    v_normalized
        );
    END IF;

    -- Placeholder: todos el mismo dígito (solo aplica si es all-digits)
    IF v_normalized ~ '^([0-9])\1+$' THEN
        RETURN jsonb_build_object(
            'is_valid',      true,   -- formalmente pasa longitud
            'is_suspicious', true,
            'category',      'PLACEHOLDER',
            'reasons',       to_jsonb(ARRAY['ALL_SAME_DIGIT']),
            'normalized',    v_normalized
        );
    END IF;

    -- Secuencial: solo evaluamos si es all-digits (la K rompería la secuencia)
    IF v_normalized ~ '^[0-9]+$'
       AND public._is_sequential_digits(v_normalized) THEN
        RETURN jsonb_build_object(
            'is_valid',      true,
            'is_suspicious', true,
            'category',      'SEQUENTIAL',
            'reasons',       to_jsonb(ARRAY['SEQUENTIAL_DIGITS']),
            'normalized',    v_normalized
        );
    END IF;

    -- Pasa todos los checks genéricos
    RETURN jsonb_build_object(
        'is_valid',      true,
        'is_suspicious', false,
        'category',      'VALID',
        'reasons',       '[]'::jsonb,
        'normalized',    v_normalized
    );
END;
$$;

COMMENT ON FUNCTION public._validate_tax_id_generic(text) IS
    'Validación agnóstica al país (longitud, placeholders, secuenciales). '
    'Los helpers country-specific llaman a este primero y agregan sus reglas.';


-- =============================================================================
-- SECCIÓN 2: VALIDADORES COUNTRY-SPECIFIC
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 AR: CUIT/CUIL (11 dígitos)
-- -----------------------------------------------------------------------------
-- Formato: XX-XXXXXXXX-V
-- Prefijos:
--   20, 23, 24, 27  → CUIL (personas físicas)
--   25, 26          → personas (menos comunes, nacidos en el exterior, etc.)
--   30, 33, 34      → CUIT (personas jurídicas)
--   Otros           → suspicious (no necesariamente inválido)
-- Checksum:
--   sum = d1*5 + d2*4 + d3*3 + d4*2 + d5*7 + d6*6 + d7*5 + d8*4 + d9*3 + d10*2
--   rem = sum mod 11
--   v   = 11 - rem
--   Si v = 11 → verificador debe ser 0
--   Si v = 10 → CUIT inválido por diseño (AFIP no los asigna)
CREATE OR REPLACE FUNCTION public._validate_tax_id_ar(p_tax_id text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_generic    jsonb;
    v_category   text;
    v_normalized text;
    v_prefix     text;
    v_weights    int[] := ARRAY[5,4,3,2,7,6,5,4,3,2];
    v_sum        int   := 0;
    v_expected   int;
    v_actual     int;
    v_reasons    text[] := ARRAY[]::text[];
    v_suspicious boolean := false;
    i            int;
BEGIN
    v_generic  := public._validate_tax_id_generic(p_tax_id);
    v_category := v_generic->>'category';

    -- Opción B: primero short-circuit solo para fails absolutos del genérico
    -- (los que no dependen de la longitud country-specific).
    IF v_category IN ('MISSING','TOO_SHORT','TOO_LONG','INVALID_FORMAT') THEN
        RETURN v_generic
            || jsonb_build_object('country','AR','doc_type','CUIT');
    END IF;

    v_normalized := v_generic->>'normalized';

    -- Longitud exacta 11 (country-specific, precede a PLACEHOLDER/SEQUENTIAL).
    -- Ejemplo: "12345" con country=AR → INVALID_FORMAT (no SEQUENTIAL), porque
    -- el analista quiere saber "esto no es un CUIT AR" antes que "es una serie".
    IF length(v_normalized) <> 11 OR v_normalized !~ '^[0-9]{11}$' THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_FORMAT',
            'reasons',       to_jsonb(ARRAY['AR_CUIT_LENGTH_NOT_11']),
            'normalized',    v_normalized,
            'country',       'AR',
            'doc_type',      'CUIT'
        );
    END IF;

    -- Longitud OK: ahora sí propagamos PLACEHOLDER/SEQUENTIAL del genérico.
    IF v_category IN ('PLACEHOLDER','SEQUENTIAL') THEN
        RETURN v_generic
            || jsonb_build_object('country','AR','doc_type','CUIT');
    END IF;

    -- Prefijo
    v_prefix := substr(v_normalized, 1, 2);
    IF v_prefix NOT IN ('20','23','24','25','26','27','30','33','34') THEN
        v_reasons := array_append(v_reasons, 'AR_CUIT_UNKNOWN_PREFIX');
        v_suspicious := true;
    END IF;

    -- Checksum
    FOR i IN 1..10 LOOP
        v_sum := v_sum + (substr(v_normalized, i, 1)::int * v_weights[i]);
    END LOOP;
    v_expected := 11 - (v_sum % 11);
    IF v_expected = 11 THEN
        v_expected := 0;
    END IF;

    -- v_expected = 10 significa que AFIP NO asigna este CUIT (regla interna).
    IF v_expected = 10 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_CHECKSUM',
            'reasons',       to_jsonb(array_append(v_reasons, 'AR_CUIT_CHECKSUM_EQUALS_10')),
            'normalized',    v_normalized,
            'country',       'AR',
            'doc_type',      'CUIT'
        );
    END IF;

    v_actual := substr(v_normalized, 11, 1)::int;
    IF v_expected <> v_actual THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_CHECKSUM',
            'reasons',       to_jsonb(array_append(v_reasons, 'AR_CUIT_CHECKSUM_MISMATCH')),
            'normalized',    v_normalized,
            'country',       'AR',
            'doc_type',      'CUIT'
        );
    END IF;

    -- Checksum OK. Si hubo warnings previos (prefijo raro), es_valid=true
    -- pero is_suspicious=true.
    RETURN jsonb_build_object(
        'is_valid',      true,
        'is_suspicious', v_suspicious,
        'category',      'VALID',
        'reasons',       to_jsonb(v_reasons),
        'normalized',    v_normalized,
        'country',       'AR',
        'doc_type',      CASE
                            WHEN v_prefix IN ('30','33','34') THEN 'CUIT'
                            WHEN v_prefix IN ('20','23','24','25','26','27')
                                 THEN 'CUIL'
                            ELSE 'CUIT'
                         END
    );
END;
$$;


-- -----------------------------------------------------------------------------
-- 2.2 CL: RUT (7-9 chars incluyendo verificador)
-- -----------------------------------------------------------------------------
-- Formato: XX.XXX.XXX-V donde V = [0-9] ó K
-- Checksum: mod-11 con serie [2,3,4,5,6,7,2,3,4,5,6,7,...] cíclica,
--           aplicada al body en reversa.
--   rem = sum mod 11
--   v_expected:
--     11 - rem → si 11 → "0"; si 10 → "K"; resto → dígito.
CREATE OR REPLACE FUNCTION public._validate_tax_id_cl(p_tax_id text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_normalized text;
    v_body       text;
    v_verifier   text;
    v_sum        int := 0;
    v_mult       int := 2;
    v_mod        int;
    v_expected   text;
    v_len        int;
    i            int;
BEGIN
    IF p_tax_id IS NULL OR length(trim(p_tax_id)) = 0 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'MISSING',
            'reasons',       to_jsonb(ARRAY['EMPTY_OR_NULL']),
            'normalized',    NULL,
            'country',       'CL',
            'doc_type',      'RUT'
        );
    END IF;

    v_normalized := upper(regexp_replace(p_tax_id, '[^0-9Kk]', '', 'g'));
    v_len := length(v_normalized);

    -- RUT chileno: body 6-8 dígitos + 1 verificador → total 7-9 chars.
    IF v_len < 7 OR v_len > 9 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      CASE WHEN v_len < 7 THEN 'TOO_SHORT'
                                  ELSE 'TOO_LONG' END,
            'reasons',       to_jsonb(ARRAY['CL_RUT_INVALID_LENGTH']),
            'normalized',    v_normalized,
            'country',       'CL',
            'doc_type',      'RUT'
        );
    END IF;

    v_body     := substr(v_normalized, 1, v_len - 1);
    v_verifier := substr(v_normalized, v_len, 1);

    -- Body debe ser puramente numérico
    IF v_body !~ '^[0-9]+$' THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_FORMAT',
            'reasons',       to_jsonb(ARRAY['CL_RUT_BODY_NOT_NUMERIC']),
            'normalized',    v_normalized,
            'country',       'CL',
            'doc_type',      'RUT'
        );
    END IF;

    -- Placeholder check sobre el body (no sobre el verificador)
    IF v_body ~ '^([0-9])\1+$' THEN
        RETURN jsonb_build_object(
            'is_valid',      true,
            'is_suspicious', true,
            'category',      'PLACEHOLDER',
            'reasons',       to_jsonb(ARRAY['CL_RUT_BODY_ALL_SAME_DIGIT']),
            'normalized',    v_normalized,
            'country',       'CL',
            'doc_type',      'RUT'
        );
    END IF;

    IF public._is_sequential_digits(v_body) THEN
        RETURN jsonb_build_object(
            'is_valid',      true,
            'is_suspicious', true,
            'category',      'SEQUENTIAL',
            'reasons',       to_jsonb(ARRAY['CL_RUT_BODY_SEQUENTIAL']),
            'normalized',    v_normalized,
            'country',       'CL',
            'doc_type',      'RUT'
        );
    END IF;

    -- Checksum mod-11, serie cíclica 2..7, aplicada al body de derecha a izquierda
    v_mult := 2;
    FOR i IN REVERSE length(v_body)..1 LOOP
        v_sum := v_sum + (substr(v_body, i, 1)::int * v_mult);
        v_mult := v_mult + 1;
        IF v_mult > 7 THEN
            v_mult := 2;
        END IF;
    END LOOP;

    v_mod := 11 - (v_sum % 11);
    v_expected := CASE
                     WHEN v_mod = 11 THEN '0'
                     WHEN v_mod = 10 THEN 'K'
                     ELSE v_mod::text
                  END;

    IF v_expected <> v_verifier THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_CHECKSUM',
            'reasons',       to_jsonb(ARRAY['CL_RUT_CHECKSUM_MISMATCH']),
            'normalized',    v_normalized,
            'country',       'CL',
            'doc_type',      'RUT'
        );
    END IF;

    RETURN jsonb_build_object(
        'is_valid',      true,
        'is_suspicious', false,
        'category',      'VALID',
        'reasons',       '[]'::jsonb,
        'normalized',    v_normalized,
        'country',       'CL',
        'doc_type',      'RUT'
    );
END;
$$;


-- -----------------------------------------------------------------------------
-- 2.3 US: SSN y ITIN (9 dígitos)
-- -----------------------------------------------------------------------------
-- US no tiene checksum aritmético como AR/CL/BR; validamos reglas estructurales.
-- SSN (Social Security Number): AAA-GG-SSSS
--   - AAA (area):   001-665 y 667-899 válidos; 000, 666, 900-999 inválidos.
--   - GG  (group):  01-99 válidos; 00 inválido.
--   - SSSS (serial): 0001-9999 válidos; 0000 inválido.
-- ITIN (Individual Taxpayer ID): 9XX-[70-88|90-92|94-99]-XXXX
--   - Emitido por IRS a no-residentes. Se detecta por prefijo 9 y rango de group.
-- EIN (Employer ID): 9 dígitos, estructura XX-XXXXXXX. Los 2 primeros son un
--   prefijo IRS pero cualquier rango se considera válido acá (el set es amplio
--   y cambia con el tiempo; la validación exhaustiva no aporta vs costo).
CREATE OR REPLACE FUNCTION public._validate_tax_id_us(p_tax_id text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_generic    jsonb;
    v_category   text;
    v_normalized text;
    v_first      int;
    v_area       int;
    v_group      int;
    v_serial     int;
    v_doc_type   text;
    v_reasons    text[] := ARRAY[]::text[];
BEGIN
    v_generic  := public._validate_tax_id_generic(p_tax_id);
    v_category := v_generic->>'category';

    -- Opción B: fails absolutos solo.
    IF v_category IN ('MISSING','TOO_SHORT','TOO_LONG','INVALID_FORMAT') THEN
        RETURN v_generic
            || jsonb_build_object('country','US','doc_type','UNKNOWN');
    END IF;

    v_normalized := v_generic->>'normalized';

    -- Longitud exacta 9 (country-specific, precede a PLACEHOLDER/SEQUENTIAL).
    IF length(v_normalized) <> 9 OR v_normalized !~ '^[0-9]{9}$' THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_FORMAT',
            'reasons',       to_jsonb(ARRAY['US_TAX_ID_LENGTH_NOT_9']),
            'normalized',    v_normalized,
            'country',       'US',
            'doc_type',      'UNKNOWN'
        );
    END IF;

    -- Longitud OK: propagamos PLACEHOLDER/SEQUENTIAL del genérico.
    IF v_category IN ('PLACEHOLDER','SEQUENTIAL') THEN
        RETURN v_generic
            || jsonb_build_object('country','US','doc_type','UNKNOWN');
    END IF;

    v_first  := substr(v_normalized, 1, 1)::int;
    v_area   := substr(v_normalized, 1, 3)::int;
    v_group  := substr(v_normalized, 4, 2)::int;
    v_serial := substr(v_normalized, 6, 4)::int;

    IF v_first = 9 THEN
        -- ITIN path
        v_doc_type := 'ITIN';
        IF NOT (v_group BETWEEN 70 AND 88
                OR v_group BETWEEN 90 AND 92
                OR v_group BETWEEN 94 AND 99) THEN
            v_reasons := array_append(v_reasons, 'US_ITIN_INVALID_GROUP');
        END IF;
        IF v_serial = 0 THEN
            v_reasons := array_append(v_reasons, 'US_ITIN_INVALID_SERIAL');
        END IF;
    ELSE
        -- SSN path
        v_doc_type := 'SSN';
        IF v_area = 0 OR v_area = 666 OR v_area >= 900 THEN
            v_reasons := array_append(v_reasons, 'US_SSN_INVALID_AREA');
        END IF;
        IF v_group = 0 THEN
            v_reasons := array_append(v_reasons, 'US_SSN_INVALID_GROUP');
        END IF;
        IF v_serial = 0 THEN
            v_reasons := array_append(v_reasons, 'US_SSN_INVALID_SERIAL');
        END IF;
    END IF;

    IF array_length(v_reasons, 1) > 0 THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_FORMAT',
            'reasons',       to_jsonb(v_reasons),
            'normalized',    v_normalized,
            'country',       'US',
            'doc_type',      v_doc_type
        );
    END IF;

    RETURN jsonb_build_object(
        'is_valid',      true,
        'is_suspicious', false,
        'category',      'VALID',
        'reasons',       '[]'::jsonb,
        'normalized',    v_normalized,
        'country',       'US',
        'doc_type',      v_doc_type
    );
END;
$$;


-- -----------------------------------------------------------------------------
-- 2.4 BR: CPF (11 dígitos) y CNPJ (14 dígitos)
-- -----------------------------------------------------------------------------
-- CPF  (persona física):     XXX.XXX.XXX-VV
-- CNPJ (persona jurídica):   XX.XXX.XXX/YYYY-VV
--
-- CPF checksum (doble dígito):
--   d10: sum = sum_{i=1..9}(d_i * (11 - i));  rem = sum mod 11
--        d10 = 0 si rem < 2, si no 11 - rem.
--   d11: sum = sum_{i=1..10}(d_i * (12 - i)); rem = sum mod 11
--        d11 = 0 si rem < 2, si no 11 - rem.
--
-- CNPJ checksum (doble dígito, pesos específicos):
--   pesos d13: [5,4,3,2,9,8,7,6,5,4,3,2]
--   pesos d14: [6,5,4,3,2,9,8,7,6,5,4,3,2]
--   rem = sum mod 11; dígito = 0 si rem < 2, si no 11 - rem.
CREATE OR REPLACE FUNCTION public._validate_tax_id_br(p_tax_id text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_generic     jsonb;
    v_category    text;
    v_normalized  text;
    v_len         int;
    v_sum         int;
    v_rem         int;
    v_d1          int;
    v_d2          int;
    v_weights_13  int[] := ARRAY[5,4,3,2,9,8,7,6,5,4,3,2];
    v_weights_14  int[] := ARRAY[6,5,4,3,2,9,8,7,6,5,4,3,2];
    v_doc_type    text;
    i             int;
BEGIN
    v_generic  := public._validate_tax_id_generic(p_tax_id);
    v_category := v_generic->>'category';

    -- Opción B: fails absolutos solo.
    IF v_category IN ('MISSING','TOO_SHORT','TOO_LONG','INVALID_FORMAT') THEN
        RETURN v_generic
            || jsonb_build_object('country','BR','doc_type','UNKNOWN');
    END IF;

    v_normalized := v_generic->>'normalized';
    v_len := length(v_normalized);

    -- Longitud 11 (CPF) o 14 (CNPJ), country-specific, precede a PLACEHOLDER/SEQUENTIAL.
    IF v_normalized !~ '^[0-9]+$' OR v_len NOT IN (11, 14) THEN
        RETURN jsonb_build_object(
            'is_valid',      false,
            'is_suspicious', false,
            'category',      'INVALID_FORMAT',
            'reasons',       to_jsonb(ARRAY['BR_TAX_ID_INVALID_LENGTH']),
            'normalized',    v_normalized,
            'country',       'BR',
            'doc_type',      'UNKNOWN'
        );
    END IF;

    -- Longitud OK: propagamos PLACEHOLDER/SEQUENTIAL del genérico.
    IF v_category IN ('PLACEHOLDER','SEQUENTIAL') THEN
        RETURN v_generic
            || jsonb_build_object(
                'country',  'BR',
                'doc_type', CASE WHEN v_len = 11 THEN 'CPF' ELSE 'CNPJ' END
            );
    END IF;

    IF v_len = 11 THEN
        v_doc_type := 'CPF';

        -- Primer verificador (d10)
        v_sum := 0;
        FOR i IN 1..9 LOOP
            v_sum := v_sum + (substr(v_normalized, i, 1)::int * (11 - i));
        END LOOP;
        v_rem := v_sum % 11;
        v_d1  := CASE WHEN v_rem < 2 THEN 0 ELSE 11 - v_rem END;
        IF v_d1 <> substr(v_normalized, 10, 1)::int THEN
            RETURN jsonb_build_object(
                'is_valid',      false,
                'is_suspicious', false,
                'category',      'INVALID_CHECKSUM',
                'reasons',       to_jsonb(ARRAY['BR_CPF_D10_MISMATCH']),
                'normalized',    v_normalized,
                'country',       'BR',
                'doc_type',      'CPF'
            );
        END IF;

        -- Segundo verificador (d11)
        v_sum := 0;
        FOR i IN 1..10 LOOP
            v_sum := v_sum + (substr(v_normalized, i, 1)::int * (12 - i));
        END LOOP;
        v_rem := v_sum % 11;
        v_d2  := CASE WHEN v_rem < 2 THEN 0 ELSE 11 - v_rem END;
        IF v_d2 <> substr(v_normalized, 11, 1)::int THEN
            RETURN jsonb_build_object(
                'is_valid',      false,
                'is_suspicious', false,
                'category',      'INVALID_CHECKSUM',
                'reasons',       to_jsonb(ARRAY['BR_CPF_D11_MISMATCH']),
                'normalized',    v_normalized,
                'country',       'BR',
                'doc_type',      'CPF'
            );
        END IF;

    ELSE  -- v_len = 14 → CNPJ
        v_doc_type := 'CNPJ';

        -- Primer verificador (d13)
        v_sum := 0;
        FOR i IN 1..12 LOOP
            v_sum := v_sum + (substr(v_normalized, i, 1)::int * v_weights_13[i]);
        END LOOP;
        v_rem := v_sum % 11;
        v_d1  := CASE WHEN v_rem < 2 THEN 0 ELSE 11 - v_rem END;
        IF v_d1 <> substr(v_normalized, 13, 1)::int THEN
            RETURN jsonb_build_object(
                'is_valid',      false,
                'is_suspicious', false,
                'category',      'INVALID_CHECKSUM',
                'reasons',       to_jsonb(ARRAY['BR_CNPJ_D13_MISMATCH']),
                'normalized',    v_normalized,
                'country',       'BR',
                'doc_type',      'CNPJ'
            );
        END IF;

        -- Segundo verificador (d14)
        v_sum := 0;
        FOR i IN 1..13 LOOP
            v_sum := v_sum + (substr(v_normalized, i, 1)::int * v_weights_14[i]);
        END LOOP;
        v_rem := v_sum % 11;
        v_d2  := CASE WHEN v_rem < 2 THEN 0 ELSE 11 - v_rem END;
        IF v_d2 <> substr(v_normalized, 14, 1)::int THEN
            RETURN jsonb_build_object(
                'is_valid',      false,
                'is_suspicious', false,
                'category',      'INVALID_CHECKSUM',
                'reasons',       to_jsonb(ARRAY['BR_CNPJ_D14_MISMATCH']),
                'normalized',    v_normalized,
                'country',       'BR',
                'doc_type',      'CNPJ'
            );
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'is_valid',      true,
        'is_suspicious', false,
        'category',      'VALID',
        'reasons',       '[]'::jsonb,
        'normalized',    v_normalized,
        'country',       'BR',
        'doc_type',      v_doc_type
    );
END;
$$;


-- =============================================================================
-- SECCIÓN 3: DISPATCHER PÚBLICO
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 validate_tax_id(p_tax_id, p_country)
-- -----------------------------------------------------------------------------
-- Entry point. Rutea al helper country-specific o cae a genérico.
-- p_country se matchea case-insensitive con 'AR' | 'CL' | 'US' | 'BR'.
-- Cualquier otro valor (o NULL) → solo chequeos genéricos, category puede
-- terminar en UNKNOWN_COUNTRY si el input era estructuralmente válido.
CREATE OR REPLACE FUNCTION public.validate_tax_id(
    p_tax_id  text,
    p_country text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_country text;
    v_result  jsonb;
BEGIN
    v_country := upper(coalesce(p_country, ''));

    CASE v_country
        WHEN 'AR' THEN RETURN public._validate_tax_id_ar(p_tax_id);
        WHEN 'CL' THEN RETURN public._validate_tax_id_cl(p_tax_id);
        WHEN 'US' THEN RETURN public._validate_tax_id_us(p_tax_id);
        WHEN 'BR' THEN RETURN public._validate_tax_id_br(p_tax_id);
        ELSE
            -- Sin país: solo genéricos. Si pasó genérico con VALID, marcamos
            -- UNKNOWN_COUNTRY para que el caller sepa que no pudimos validar
            -- checksum country-specific.
            v_result := public._validate_tax_id_generic(p_tax_id);
            IF (v_result->>'category') = 'VALID' THEN
                v_result := v_result || jsonb_build_object(
                    'category',  'UNKNOWN_COUNTRY',
                    'reasons',   to_jsonb(ARRAY['NO_COUNTRY_SPECIFIC_VALIDATION']),
                    'country',   NULLIF(p_country, ''),
                    'doc_type',  'UNKNOWN'
                );
            ELSE
                v_result := v_result || jsonb_build_object(
                    'country',  NULLIF(p_country, ''),
                    'doc_type', 'UNKNOWN'
                );
            END IF;
            RETURN v_result;
    END CASE;
END;
$$;

COMMENT ON FUNCTION public.validate_tax_id(text, text) IS
    'Valida un tax_id contra reglas de formato, checksum y heurísticas de '
    'placeholder/secuencial. Países soportados: AR (CUIT/CUIL), CL (RUT), '
    'US (SSN/ITIN), BR (CPF/CNPJ). Retorna jsonb con is_valid, is_suspicious, '
    'category, reasons[], normalized, country, doc_type. IMMUTABLE.';


-- =============================================================================
-- SECCIÓN 4: search_by_tax_id EXTENDIDO CON VALIDACIÓN
-- =============================================================================

-- Drop necesario porque cambia la signature del RETURNS TABLE.
DROP FUNCTION IF EXISTS public.search_by_tax_id(text, text);

-- -----------------------------------------------------------------------------
-- 4.1 search_by_tax_id(p_tax_id, p_country)
-- -----------------------------------------------------------------------------
-- Mantiene el comportamiento original (buscar por tax_id_normalized en
-- screening_list_entry) y suma 3 columnas:
--   input_validation jsonb: resultado de validate_tax_id sobre el input.
--   entry_validation jsonb: resultado sobre el tax_id del entry matcheado.
--   trust_level text:
--     TRUSTED   → ambos validan OK
--     WEAK      → alguno es_suspicious (placeholder, secuencial, prefijo raro)
--                 pero ninguno es formal-inválido
--     UNTRUSTED → alguno es is_valid=false (checksum o formato)
--
-- Caller existente que SELECT solo las 5 columnas originales sigue funcionando.
CREATE OR REPLACE FUNCTION public.search_by_tax_id(
    p_tax_id  text,
    p_country text DEFAULT NULL
)
RETURNS TABLE (
    list_name         text,
    entry_id          uuid,
    matched_tax_id    text,
    match_type        text,
    confidence        numeric,
    input_validation  jsonb,
    entry_validation  jsonb,
    trust_level       text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_normalized_tax_id text;
    v_input_validation  jsonb;
BEGIN
    v_normalized_tax_id := public.normalize_tax_id(p_tax_id);
    IF v_normalized_tax_id IS NULL THEN
        RETURN;
    END IF;

    -- Validamos el input una sola vez (no depende de los entries).
    v_input_validation := public.validate_tax_id(p_tax_id, p_country);

    RETURN QUERY
    WITH matches AS (
        SELECT
            l.name::text      AS list_name,
            sle.id            AS entry_id,
            sle.tax_id::text  AS matched_tax_id,
            CASE
                WHEN sle.tax_id = p_tax_id THEN 'EXACT'
                ELSE 'NORMALIZED'
            END::text AS match_type,
            CASE
                WHEN sle.tax_id = p_tax_id THEN 100
                ELSE 95
            END::numeric AS confidence,
            -- Validamos el tax_id del entry usando el country DEL ENTRY
            -- (sle.country), que puede diferir del p_country del search.
            -- Fallback a p_country si sle.country es NULL.
            public.validate_tax_id(sle.tax_id, COALESCE(sle.country, p_country))
                AS entry_validation
        FROM public.screening_list_entry sle
        JOIN public.list l ON l.id = sle.list_id
        WHERE sle.tax_id_normalized = v_normalized_tax_id
          AND (p_country IS NULL OR sle.country = p_country)
    )
    SELECT
        m.list_name,
        m.entry_id,
        m.matched_tax_id,
        m.match_type,
        m.confidence,
        v_input_validation AS input_validation,
        m.entry_validation,
        CASE
            WHEN (v_input_validation->>'is_valid')::boolean = false
              OR (m.entry_validation->>'is_valid')::boolean = false
                THEN 'UNTRUSTED'
            WHEN (v_input_validation->>'is_suspicious')::boolean = true
              OR (m.entry_validation->>'is_suspicious')::boolean = true
                THEN 'WEAK'
            ELSE 'TRUSTED'
        END AS trust_level
    FROM matches m;
END;
$$;

COMMENT ON FUNCTION public.search_by_tax_id(text, text) IS
    'Busca tax_id en screening_list_entry y adjunta validación (input + entry) '
    'y trust_level (TRUSTED/WEAK/UNTRUSTED). Las columnas originales (list_name, '
    'entry_id, matched_tax_id, match_type, confidence) se preservan para compat.';


-- =============================================================================
-- SECCIÓN 5: calculate_similarity CON VALIDACIÓN POR PAÍS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 5.1 calculate_similarity(...) -- ahora con p_country
-- -----------------------------------------------------------------------------
-- Agrega p_country text DEFAULT NULL al final (backwards-compatible).
--
-- Lógica de weighting del tax_id cuando p_country IS NOT NULL y ambos tax_ids
-- están presentes:
--   - Validamos input y entry.
--   - Si CUALQUIERA tiene category IN (PLACEHOLDER, SEQUENTIAL, INVALID_FORMAT,
--     TOO_SHORT, TOO_LONG): peso de tax_id = 0 (colapsa, el match no informa
--     identidad por colisión altísima o comparabilidad rota).
--   - Si CUALQUIERA tiene category = INVALID_CHECKSUM y NINGUNO es placeholder:
--     peso de tax_id = 0.15 (mitad), el match aún tiene algo de signal porque
--     la colisión de checksums inválidos random es baja.
--   - Si ambos VALID (incluso con is_suspicious=true por prefijo raro): peso
--     completo 0.30.
--   - Si p_country IS NULL: comportamiento idéntico al de V006 (full weight).
--
-- details.tax_id_validation expone la decisión para auditoría en alert.details.
CREATE OR REPLACE FUNCTION public.calculate_similarity(
    p_name1       text,
    p_name2       text,
    p_tax_id1     text    DEFAULT NULL,
    p_tax_id2     text    DEFAULT NULL,
    p_birth_date1 date    DEFAULT NULL,
    p_birth_date2 date    DEFAULT NULL,
    p_threshold   numeric DEFAULT 0.8,
    p_country     text    DEFAULT NULL
)
RETURNS TABLE(
    similarity_score numeric,
    match_type       text,
    details          jsonb
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_name_similarity   numeric := 0;
    v_tax_id_score      numeric := 0;
    v_birth_date_score  numeric := 0;
    v_total_weight      numeric := 0;
    v_weighted_sum      numeric := 0;
    v_has_tax_id        boolean := (p_tax_id1 IS NOT NULL AND p_tax_id2 IS NOT NULL);
    v_has_birth_date    boolean := (p_birth_date1 IS NOT NULL AND p_birth_date2 IS NOT NULL);
    v_final_score       numeric := 0;

    -- Tax-id validation state
    v_input_validation  jsonb   := NULL;
    v_entry_validation  jsonb   := NULL;
    v_tax_id_weight     numeric := 0.3;  -- default full weight
    v_tax_id_downgraded boolean := false;
    v_tax_id_reason     text    := NULL;
    v_input_cat         text;
    v_entry_cat         text;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Nombre: siempre contribuye
    -- -------------------------------------------------------------------------
    v_name_similarity := similarity(
        public.normalize_name(p_name1),
        public.normalize_name(p_name2)
    );
    v_total_weight := v_total_weight + 0.5;
    v_weighted_sum := v_weighted_sum + v_name_similarity * 0.5;

    -- -------------------------------------------------------------------------
    -- 2. Tax ID: contribuye si ambos lados proveen valor, con ajuste por
    --    validación cuando p_country está presente.
    -- -------------------------------------------------------------------------
    IF v_has_tax_id THEN
        IF public.normalize_tax_id(p_tax_id1) = public.normalize_tax_id(p_tax_id2) THEN
            v_tax_id_score := 1;
        END IF;

        -- Ajustar peso según validación (solo si p_country provisto)
        IF p_country IS NOT NULL THEN
            v_input_validation := public.validate_tax_id(p_tax_id1, p_country);
            v_entry_validation := public.validate_tax_id(p_tax_id2, p_country);
            v_input_cat := v_input_validation->>'category';
            v_entry_cat := v_entry_validation->>'category';

            -- Placeholders y rotos → peso 0
            IF v_input_cat IN ('PLACEHOLDER','SEQUENTIAL','INVALID_FORMAT',
                               'TOO_SHORT','TOO_LONG','MISSING')
               OR v_entry_cat IN ('PLACEHOLDER','SEQUENTIAL','INVALID_FORMAT',
                                  'TOO_SHORT','TOO_LONG','MISSING') THEN
                v_tax_id_weight := 0;
                v_tax_id_downgraded := true;
                v_tax_id_reason := 'untrusted_tax_id_zero_weight';

            -- Checksum inválido sin placeholder → peso mitad
            ELSIF v_input_cat = 'INVALID_CHECKSUM'
               OR v_entry_cat = 'INVALID_CHECKSUM' THEN
                v_tax_id_weight := 0.15;
                v_tax_id_downgraded := true;
                v_tax_id_reason := 'invalid_checksum_half_weight';
            END IF;
        END IF;

        v_total_weight := v_total_weight + v_tax_id_weight;
        v_weighted_sum := v_weighted_sum + v_tax_id_score * v_tax_id_weight;
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Fecha de nacimiento: contribuye si ambos lados proveen valor.
    -- -------------------------------------------------------------------------
    IF v_has_birth_date THEN
        IF p_birth_date1 = p_birth_date2 THEN
            v_birth_date_score := 1;
        ELSIF EXTRACT(YEAR FROM p_birth_date1) = EXTRACT(YEAR FROM p_birth_date2) THEN
            v_birth_date_score := 0.5;
        END IF;
        v_total_weight := v_total_weight + 0.2;
        v_weighted_sum := v_weighted_sum + v_birth_date_score * 0.2;
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Score final normalizado.
    --    v_total_weight siempre >= 0.5 (nombre siempre presente), nunca 0.
    -- -------------------------------------------------------------------------
    v_final_score := (v_weighted_sum / v_total_weight) * 100;
    similarity_score := round(v_final_score, 2);

    -- -------------------------------------------------------------------------
    -- 5. Clasificación del tipo de match.
    --    Importante: TAX_ID_EXACT solo si el tax_id tuvo peso efectivo > 0.
    --    Si el tax_id match fue degradado a 0, no lo contamos como "la razón
    --    del match" — sería engañoso para el analista.
    -- -------------------------------------------------------------------------
    IF v_tax_id_score = 1 AND v_tax_id_weight > 0 THEN
        match_type := 'TAX_ID_EXACT';
    ELSIF v_name_similarity >= p_threshold AND v_birth_date_score = 1 THEN
        match_type := 'NAME_AND_BIRTHDATE';
    ELSIF v_name_similarity >= p_threshold THEN
        match_type := 'NAME_FUZZY';
    ELSE
        match_type := 'NO_MATCH';
    END IF;

    -- -------------------------------------------------------------------------
    -- 6. Details jsonb con toda la info (weighting + validación tax_id).
    -- -------------------------------------------------------------------------
    details := jsonb_build_object(
        'name_similarity',  round(v_name_similarity::numeric, 4),
        'tax_id_match',     v_tax_id_score,
        'birth_date_score', v_birth_date_score,
        'threshold',        p_threshold,
        'weights_applied',  jsonb_build_object(
            'name',       0.5,
            'tax_id',     CASE WHEN v_has_tax_id     THEN v_tax_id_weight ELSE 0 END,
            'birth_date', CASE WHEN v_has_birth_date THEN 0.2             ELSE 0 END,
            'total',      v_total_weight
        ),
        'tax_id_validation', CASE
            WHEN v_input_validation IS NULL AND v_entry_validation IS NULL THEN NULL
            ELSE jsonb_build_object(
                'input',             v_input_validation,
                'entry',             v_entry_validation,
                'effective_weight',  v_tax_id_weight,
                'downgraded',        v_tax_id_downgraded,
                'downgrade_reason',  v_tax_id_reason
            )
        END
    );
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.calculate_similarity(
    text, text, text, text, date, date, numeric, text
) IS
    'Calcula similaridad ponderada entre dos entidades. Con p_country provisto, '
    'valida tax_ids y ajusta el peso: 0 si placeholder/secuencial/roto, 0.15 '
    'si invalid_checksum, 0.30 si valid. details.tax_id_validation expone la '
    'decisión para auditoría.';

COMMIT;

-- =============================================================================
-- PENDIENTE (V009): patch a run_screening para pasar p_country al llamar
-- calculate_similarity. Hasta entonces calculate_similarity se llama sin country
-- y el comportamiento es el mismo que V006 (weight completo siempre).
-- =============================================================================

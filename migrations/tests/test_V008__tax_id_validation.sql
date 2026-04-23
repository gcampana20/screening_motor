-- =============================================================================
-- test_V008__tax_id_validation.sql
-- -----------------------------------------------------------------------------
-- Test suite para V008. Ejecutar en DataGrip/pgAdmin (sin \echo, todo SELECT).
-- Cada sección es un bloque independiente. Leé el output columna por columna.
--
-- No requiere data previa (las validaciones son puras; los tests de search_by_tax_id
-- usan BEGIN/ROLLBACK con data inyectada).
-- =============================================================================

-- =============================================================================
-- SECCIÓN 1: CHEQUEOS GENÉRICOS (agnósticos al país)
-- =============================================================================
SELECT '== 1. CHEQUEOS GENÉRICOS ==' AS section;

-- 1.1 NULL → MISSING
SELECT 'T1.1 null → MISSING' AS test,
       public.validate_tax_id(NULL, 'AR') AS result;

-- 1.2 Empty string → MISSING
SELECT 'T1.2 empty → MISSING' AS test,
       public.validate_tax_id('', 'AR') AS result;

-- 1.3 Too short (2 dígitos)
SELECT 'T1.3 "12" → TOO_SHORT' AS test,
       public.validate_tax_id('12', 'AR') AS result;

-- 1.4 Too long (>20 dígitos)
SELECT 'T1.4 21 dígitos → TOO_LONG' AS test,
       public.validate_tax_id(repeat('1', 21), 'AR') AS result;

-- 1.5 Placeholder todos 9's (11 dígitos, CUIT-like)
SELECT 'T1.5 "99999999999" → PLACEHOLDER' AS test,
       public.validate_tax_id('99999999999', 'AR') AS result;

-- 1.6 Sequential con wrap (12345678901)
SELECT 'T1.6 "12345678901" → SEQUENTIAL' AS test,
       public.validate_tax_id('12345678901', 'BR') AS result;

-- 1.7 Sequential descendente
SELECT 'T1.7 "98765432109" → SEQUENTIAL' AS test,
       public.validate_tax_id('98765432109', 'BR') AS result;


-- =============================================================================
-- SECCIÓN 2: AR CUIT
-- =============================================================================
SELECT '== 2. AR CUIT ==' AS section;

-- 2.1 CUIT válido (20-12345678-6 verificado a mano: sum=148, mod=5, v=6)
SELECT 'T2.1 "20-12345678-6" → VALID CUIL' AS test,
       public.validate_tax_id('20-12345678-6', 'AR') AS result;

-- 2.2 CUIT válido sin separadores
SELECT 'T2.2 "20123456786" → VALID CUIL' AS test,
       public.validate_tax_id('20123456786', 'AR') AS result;

-- 2.3 CUIT con checksum inválido (dígito verificador errado)
SELECT 'T2.3 "20-12345678-9" → INVALID_CHECKSUM' AS test,
       public.validate_tax_id('20-12345678-9', 'AR') AS result;

-- 2.4 CUIT con prefijo raro (99 no está en la lista AFIP)
--     Si checksum coincidiera sería VALID + is_suspicious; elegimos uno que
--     falle ambos para mostrar el short-circuit.
SELECT 'T2.4 "99-12345678-6" → INVALID_CHECKSUM (y prefijo raro en reasons)' AS test,
       public.validate_tax_id('99-12345678-6', 'AR') AS result;

-- 2.5 CUIT prefijo persona jurídica (30)
--     30123456780: sum = 15+0+3+4+21+24+25+24+21+16 = 153; 153%11 = 10; 11-10 = 1
--     Ajustamos el verificador a "1"
SELECT 'T2.5 "30-12345678-1" → VALID CUIT' AS test,
       public.validate_tax_id('30-12345678-1', 'AR') AS result;

-- 2.6 Longitud incorrecta (10 dígitos)
SELECT 'T2.6 "2012345678" → INVALID_FORMAT (length)' AS test,
       public.validate_tax_id('2012345678', 'AR') AS result;


-- =============================================================================
-- SECCIÓN 3: CL RUT
-- =============================================================================
SELECT '== 3. CL RUT ==' AS section;

-- 3.1 RUT válido (11.222.333-9 verificado: body 11222333, sum=68, mod=6, v=9)
SELECT 'T3.1 "11.222.333-9" → VALID' AS test,
       public.validate_tax_id('11.222.333-9', 'CL') AS result;

-- 3.2 RUT válido con verificador K
--     Caso elegido: body 1234566 (7 dígitos, no sequential)
--     Reverso: 6,6,5,4,3,2,1; weights 2,3,4,5,6,7,2
--     Products: 12,18,20,20,18,14,2 = 104; 104%11 = 5; 11-5=6 → "6"
--     Ajustamos: busquemos un body donde mod=1 → v="K"
--     Body 6666660 (no all-same porque termina en 0). Reverso: 0,6,6,6,6,6,6
--     Products: 0, 18, 24, 30, 36, 42, 12 = 162; 162%11 = 9; 11-9=2 → "2"
--     Probamos body 9999990: reverso 0,9,9,9,9,9,9; products 0,27,36,45,54,63,18 = 243
--     243%11 = 1 (243-22*11=243-242=1); 11-1=10 → "K" ✓
SELECT 'T3.2 "9999990-K" → VALID (verificador K)' AS test,
       public.validate_tax_id('9999990-K', 'CL') AS result;

-- 3.3 RUT con verificador errado
SELECT 'T3.3 "11.222.333-5" → INVALID_CHECKSUM' AS test,
       public.validate_tax_id('11.222.333-5', 'CL') AS result;

-- 3.4 RUT placeholder (body todo 1's)
SELECT 'T3.4 "11.111.111-1" → PLACEHOLDER' AS test,
       public.validate_tax_id('11.111.111-1', 'CL') AS result;

-- 3.5 RUT muy corto
SELECT 'T3.5 "1234-5" → TOO_SHORT' AS test,
       public.validate_tax_id('1234-5', 'CL') AS result;


-- =============================================================================
-- SECCIÓN 4: US SSN/ITIN
-- =============================================================================
SELECT '== 4. US SSN/ITIN ==' AS section;

-- 4.1 SSN válido
SELECT 'T4.1 "123-45-6789" → VALID SSN' AS test,
       public.validate_tax_id('123-45-6789', 'US') AS result;

-- 4.2 SSN con area 666 (inválido)
SELECT 'T4.2 "666-45-6789" → INVALID_FORMAT (area 666)' AS test,
       public.validate_tax_id('666-45-6789', 'US') AS result;

-- 4.3 SSN con area 000
SELECT 'T4.3 "000-45-6789" → INVALID_FORMAT (area 000)' AS test,
       public.validate_tax_id('000-45-6789', 'US') AS result;

-- 4.4 SSN con group 00
SELECT 'T4.4 "123-00-6789" → INVALID_FORMAT (group 00)' AS test,
       public.validate_tax_id('123-00-6789', 'US') AS result;

-- 4.5 ITIN válido (9XX con group 70)
SELECT 'T4.5 "912-70-6789" → VALID ITIN' AS test,
       public.validate_tax_id('912-70-6789', 'US') AS result;

-- 4.6 ITIN con group fuera de rango
SELECT 'T4.6 "912-45-6789" → INVALID_FORMAT (ITIN group)' AS test,
       public.validate_tax_id('912-45-6789', 'US') AS result;

-- 4.7 Longitud incorrecta → INVALID_FORMAT con razón country-specific (Opción B).
SELECT 'T4.7 "12345" → INVALID_FORMAT (US_TAX_ID_LENGTH_NOT_9)' AS test,
       public.validate_tax_id('12345', 'US') AS result;


-- =============================================================================
-- SECCIÓN 5: BR CPF/CNPJ
-- =============================================================================
SELECT '== 5. BR CPF/CNPJ ==' AS section;

-- 5.1 CPF válido (111.444.777-35: verificado a mano d10=3, d11=5)
SELECT 'T5.1 "111.444.777-35" → VALID CPF' AS test,
       public.validate_tax_id('111.444.777-35', 'BR') AS result;

-- 5.2 CPF con d11 errado
SELECT 'T5.2 "111.444.777-30" → INVALID_CHECKSUM' AS test,
       public.validate_tax_id('111.444.777-30', 'BR') AS result;

-- 5.3 CNPJ válido (11.444.777/0001-61: verificado a mano d13=6, d14=1)
SELECT 'T5.3 "11.444.777/0001-61" → VALID CNPJ' AS test,
       public.validate_tax_id('11.444.777/0001-61', 'BR') AS result;

-- 5.4 CNPJ con verificador errado
SELECT 'T5.4 "11.444.777/0001-99" → INVALID_CHECKSUM' AS test,
       public.validate_tax_id('11.444.777/0001-99', 'BR') AS result;

-- 5.5 Longitud que no es 11 ni 14 → INVALID_FORMAT (country-specific length
-- precede a SEQUENTIAL gracias a Opción B del reordenamiento en V008).
SELECT 'T5.5 "12345" → INVALID_FORMAT (BR_TAX_ID_INVALID_LENGTH)' AS test,
       public.validate_tax_id('12345', 'BR') AS result;


-- =============================================================================
-- SECCIÓN 6: UNKNOWN COUNTRY
-- =============================================================================
SELECT '== 6. UNKNOWN_COUNTRY ==' AS section;

-- 6.1 País no soportado pero input estructuralmente válido
SELECT 'T6.1 "20123456786" país "XX" → UNKNOWN_COUNTRY' AS test,
       public.validate_tax_id('20123456786', 'XX') AS result;

-- 6.2 País no soportado con placeholder (genéricos igual lo captan)
SELECT 'T6.2 "99999999999" país "XX" → PLACEHOLDER (genérico pega primero)' AS test,
       public.validate_tax_id('99999999999', 'XX') AS result;

-- 6.3 País NULL
SELECT 'T6.3 "20123456786" país NULL → UNKNOWN_COUNTRY' AS test,
       public.validate_tax_id('20123456786', NULL) AS result;


-- =============================================================================
-- SECCIÓN 7: calculate_similarity — COMPORTAMIENTO CON/SIN p_country
-- =============================================================================
SELECT '== 7. calculate_similarity weighting con placeholder ==' AS section;

-- Escenario A: dos entidades DIFERENTES con mismo placeholder "99999999999".
-- Sin p_country (comportamiento V006): peso completo → score alto falso positivo.
-- Con p_country='AR' (comportamiento V008): peso tax_id colapsa a 0 → score bajo.

-- 7.1 Sin country → score contaminado por el placeholder match
SELECT 'T7.1 sin country: placeholder contamina el score' AS test,
       s.similarity_score,
       s.match_type,
       s.details->'weights_applied' AS weights
FROM public.calculate_similarity(
    'Juan Pérez', 'John Smith',
    '99999999999', '99999999999',
    NULL, NULL,
    0.8,
    NULL
) s;

-- 7.2 Con country AR → peso colapsa, score refleja solo el nombre
SELECT 'T7.2 con AR: placeholder colapsa, score limpio' AS test,
       s.similarity_score,
       s.match_type,
       s.details->'weights_applied' AS weights,
       s.details->'tax_id_validation'->>'downgrade_reason' AS downgrade_reason
FROM public.calculate_similarity(
    'Juan Pérez', 'John Smith',
    '99999999999', '99999999999',
    NULL, NULL,
    0.8,
    'AR'
) s;

-- 7.3 Ambos CUIT válidos idénticos → TAX_ID_EXACT, peso completo
SELECT 'T7.3 CUIT valid + exact match → TAX_ID_EXACT' AS test,
       s.similarity_score,
       s.match_type,
       s.details->'weights_applied' AS weights
FROM public.calculate_similarity(
    'Juan Pérez', 'Juan Perez',
    '20-12345678-6', '20-12345678-6',
    NULL, NULL,
    0.8,
    'AR'
) s;

-- 7.4 Un lado con checksum inválido → peso tax_id = 0.15 (mitad)
SELECT 'T7.4 un lado INVALID_CHECKSUM → peso 0.15' AS test,
       s.similarity_score,
       s.match_type,
       s.details->'weights_applied' AS weights,
       s.details->'tax_id_validation'->>'downgrade_reason' AS downgrade_reason
FROM public.calculate_similarity(
    'Juan Pérez', 'Juan Perez',
    '20-12345678-6', '20-12345678-9',  -- checksum errado del lado 2
    NULL, NULL,
    0.8,
    'AR'
) s;

-- 7.5 Placeholder + nombre muy parecido → debería ser NAME_FUZZY, no TAX_ID_EXACT
SELECT 'T7.5 placeholder + nombre similar → match_type NAME_* (no TAX_ID_EXACT)' AS test,
       s.similarity_score,
       s.match_type,
       s.details->'weights_applied' AS weights
FROM public.calculate_similarity(
    'Juan Pérez', 'Juan Perez',
    '99999999999', '99999999999',
    NULL, NULL,
    0.8,
    'AR'
) s;


-- =============================================================================
-- SECCIÓN 8: search_by_tax_id con validación
-- =============================================================================
SELECT '== 8. search_by_tax_id con trust_level ==' AS section;

BEGIN;

-- Setup: creamos una lista y dos entries (uno valid, uno placeholder).
-- Importante: esto corre como superuser → RLS bypasseada, FK de list.type a
-- list_type_config cumplida con SANCTIONS.
-- Nota: las columnas mínimas asumidas son id/name/type/tenant_id.
-- Si tu schema de list tiene más columnas NOT NULL (ej. source),
-- agregalas acá.
INSERT INTO public.list (id, name, type, tenant_id)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'TEST_LIST_V008', 'SANCTIONS', NULL
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.screening_list_entry (id, list_id, full_name, tax_id, country)
VALUES
    ('22222222-2222-2222-2222-222222222221',
     '11111111-1111-1111-1111-111111111111',
     'John Doe', '20-12345678-6', 'AR'),
    ('22222222-2222-2222-2222-222222222222',
     '11111111-1111-1111-1111-111111111111',
     'Junk Entry', '99999999999', 'AR')
ON CONFLICT (id) DO NOTHING;

-- 8.1 Match con tax_id válido → trust_level = TRUSTED
SELECT 'T8.1 match valid → TRUSTED' AS test,
       list_name, match_type, confidence, trust_level,
       input_validation->>'category' AS input_cat,
       entry_validation->>'category' AS entry_cat
FROM public.search_by_tax_id('20-12345678-6', 'AR');

-- 8.2 Match con placeholder → trust_level = WEAK (is_valid=true, is_suspicious=true)
SELECT 'T8.2 match placeholder → WEAK' AS test,
       list_name, match_type, confidence, trust_level,
       input_validation->>'category' AS input_cat,
       entry_validation->>'category' AS entry_cat
FROM public.search_by_tax_id('99999999999', 'AR');

-- 8.3 Input con checksum inválido buscando un entry válido
SELECT 'T8.3 input INVALID_CHECKSUM → UNTRUSTED' AS test,
       list_name, match_type, confidence, trust_level,
       input_validation->>'category' AS input_cat
FROM public.search_by_tax_id('20-12345678-9', 'AR');
-- Nota: probablemente devuelva 0 filas porque tax_id_normalized del input no
-- va a matchear ningún entry (el input tiene un dígito distinto). Esto es
-- comportamiento esperado: search_by_tax_id sigue devolviendo solo matches
-- reales; la validación NO habilita "matches fantasma".

ROLLBACK;

-- =============================================================================
-- FIN DE TESTS
-- =============================================================================
SELECT 'Tests V008 completados' AS status;

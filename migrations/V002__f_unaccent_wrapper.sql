-- =============================================================================
-- V003__f_unaccent_wrapper.sql
-- -----------------------------------------------------------------------------
-- Problema:
--   La función unaccent(text) expuesta por la extensión unaccent NO es IMMUTABLE
--   (es STABLE), porque internamente resuelve el diccionario de unaccent por
--   search_path en cada llamada. Postgres no permite usar funciones STABLE
--   en índices funcionales ni en columnas GENERATED STORED.
--
--   Al crear el índice GIN trigram sobre normalize_name(full_name), Postgres
--   rechazaba el CREATE INDEX con:
--     "no existe la función unaccent(text)"
--   (mensaje engañoso: en realidad falla porque la variante IMMUTABLE no existe;
--   solo existe la STABLE, que no puede usarse en un índice).
--
-- Solución:
--   1. Wrapper f_unaccent(text) declarado IMMUTABLE que llama a la variante
--      unaccent(regdictionary, text), la cual sí es IMMUTABLE porque el
--      diccionario queda fijo ('public.unaccent'::regdictionary).
--   2. Redefinir normalize_name(text) para usar f_unaccent en lugar de
--      unaccent(text) directo. El resto de la lógica (lower, regexp_replace,
--      trim, NULLIF) queda igual.
--
-- Este script es idempotente: CREATE OR REPLACE FUNCTION puede correrse
-- múltiples veces sin efectos colaterales.
-- =============================================================================

BEGIN;

-- 1. Wrapper IMMUTABLE sobre unaccent(regdictionary, text).
CREATE OR REPLACE FUNCTION public.f_unaccent(text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
STRICT
AS $$
    SELECT public.unaccent('public.unaccent'::regdictionary, $1);
$$;

COMMENT ON FUNCTION public.f_unaccent(text) IS
    'Wrapper IMMUTABLE de unaccent(regdictionary, text). Necesario para usar '
    'unaccent dentro de índices funcionales y columnas GENERATED STORED.';

-- 2. Redefinir normalize_name para usar f_unaccent.
CREATE OR REPLACE FUNCTION public.normalize_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_name IS NULL THEN NULL
        ELSE NULLIF(
            trim(
                regexp_replace(
                    regexp_replace(
                        lower(public.f_unaccent(p_name)),
                        '[^a-z0-9]+', ' ', 'g'
                    ),
                    '\s+', ' ', 'g'
                )
            ),
            ''
        )
    END;
$$;

COMMENT ON FUNCTION public.normalize_name(text) IS
    'Normaliza un nombre para matching: quita acentos (via f_unaccent), '
    'pasa a minúsculas, colapsa cualquier carácter no alfanumérico a un '
    'espacio, colapsa espacios múltiples, trim y devuelve NULL para strings '
    'vacíos. IMMUTABLE: apta para índices y columnas generadas.';

COMMIT;

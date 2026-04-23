-- =============================================================================
-- V000__extensions.sql
-- -----------------------------------------------------------------------------
-- Habilita las extensiones de PostgreSQL que el motor de screening necesita.
-- Se ejecuta UNA sola vez al inicializar la base (idempotente gracias a IF NOT EXISTS: si ya existen, no falla).

-- NOTA: CREATE EXTENSION requiere privilegios de superuser. En Docker local corremos como postgres, en producción
-- este script se aplica con el superuser del cluster, no con el usuario de aplicación.
-- =============================================================================

-- pg_trgm: búsqueda por similitud basada en trigramas.
-- Aporta la función similarity(text, text) y los operadores % y <->,
-- además de soportar índices GIN/GIST con gin_trgm_ops sobre columnas text.
-- La usa directamente calculate_similarity() para comparar nombres.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- fuzzystrmatch: algoritmos fonéticos y de distancia de edición.
-- Aporta soundex(), metaphone(), dmetaphone() y levenshtein().
-- Complemento a pg_trgm para transliteraciones (Juan/Jhon,
-- Mohamed/Muhammad) y para detectar errores de tipeo clásicos.
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

-- unaccent: remueve acentos y diacríticos.
-- La usa normalize_name() para que "José" matchee con "Jose".
CREATE EXTENSION IF NOT EXISTS unaccent;

-- uuid-ossp: generación de UUIDs v1/v3/v4/v5.
-- Todas las PKs del modelo usan uuid_generate_v4() como default.
-- Alternativa moderna: pgcrypto + gen_random_uuid() (built-in desde PG13),
-- pero mantenemos uuid-ossp por consistencia con el schema existente.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

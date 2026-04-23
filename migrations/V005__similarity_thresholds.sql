-- =============================================================================
-- V005__similarity_thresholds.sql
-- -----------------------------------------------------------------------------
-- Modela los umbrales de similitud por tipo de lista, con override per-lista.
--
-- Motivación:
--   El motor de screening no puede usar un único umbral global. El trade-off
--   precision/recall depende del tipo de lista:
--     - SANCTIONS (OFAC, UN, EU): falso negativo = multa regulatoria.
--       Priorizamos recall → umbral BAJO (0.65).
--     - PEP: impacto reputacional, balance medio (0.75).
--     - INTERNAL_BLACKLIST: match bloquea operación. FPs bloquean clientes
--       legítimos. Priorizamos precisión → umbral ALTO (0.85).
--     - INTERNAL_WATCHLIST: match solo flagea, no bloquea. Recall medio (0.75).
--
-- Diseño (híbrido, dos niveles):
--   1. list_type_config: defaults por tipo. Un admin de compliance puede
--      ajustar el umbral de todo un tipo con un UPDATE.
--   2. list.min_similarity: override per-lista (nullable). Si un OFAC puntual
--      necesita 0.60 por muchas transliteraciones, se ajusta sin afectar
--      las demás listas de sanciones.
--   3. Función resolve_similarity_threshold(list_id) aplica el fallback:
--      COALESCE(list.min_similarity, list_type_config.default_min_similarity).
--
-- Nomenclatura:
--   Los valores del enum (INTERNAL_BLACKLIST, INTERNAL_WATCHLIST) llevan el
--   prefijo INTERNAL_ para que quede explícito que son listas del tenant
--   (vs SANCTIONS/PEP que son globales). Facilita queries tipo:
--     WHERE type LIKE 'INTERNAL_%'   -- todas las listas internas
--
-- PRECONDICIÓN:
--   list.type debe ser varchar sin límite (o con límite >= 20 chars).
--   Si es menor, agregar ALTER COLUMN type TYPE varchar(32) antes de V005.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Tabla de configuración por tipo de lista
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.list_type_config (
    list_type               varchar      PRIMARY KEY,
    default_min_similarity  numeric(4,3) NOT NULL
        CHECK (default_min_similarity >= 0 AND default_min_similarity <= 1),
    description             text
);

COMMENT ON TABLE public.list_type_config IS
    'Configuración por tipo de lista. Define umbrales de similitud default '
    'que pueden ser overrideados en list.min_similarity para listas puntuales.';

COMMENT ON COLUMN public.list_type_config.default_min_similarity IS
    'Umbral por defecto (0..1). Un match con similarity >= este valor genera alerta.';

-- -----------------------------------------------------------------------------
-- 2. Poblado inicial con los 4 tipos del challenge
-- -----------------------------------------------------------------------------
-- ON CONFLICT DO NOTHING hace que V005 sea re-runnable sin sobrescribir
-- overrides manuales que un admin haya aplicado después.
INSERT INTO public.list_type_config (list_type, default_min_similarity, description) VALUES
    ('SANCTIONS',          0.650,
        'Listas de sanciones globales (OFAC, UN, EU). Match genera alerta '
        'obligatoria para compliance regulatorio. Umbral bajo: priorizamos '
        'recall porque el costo de un falso negativo (no detectar un sancionado) '
        'es regulatoriamente altísimo.'),
    ('PEP',                0.750,
        'Personas Políticamente Expuestas, agrupadas por país. Impacto '
        'principalmente reputacional. Umbral medio: balance entre recall '
        'y ruido de falsos positivos.'),
    ('INTERNAL_BLACKLIST', 0.850,
        'Lista interna del tenant de entidades a BLOQUEAR. Match en screening '
        'deniega la operación (ej: no abrir cuenta). Umbral alto: un falso '
        'positivo bloquea a un cliente legítimo, por lo que priorizamos precisión.'),
    ('INTERNAL_WATCHLIST', 0.750,
        'Lista interna del tenant de entidades a MONITOREAR. Match flagea '
        'para revisión manual pero NO bloquea la operación. Podemos permitirnos '
        'recall más alto porque los falsos positivos solo generan trabajo al analista.')
ON CONFLICT (list_type) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. Columna min_similarity en list (override per-lista)
-- -----------------------------------------------------------------------------
-- Nullable: si está en NULL, la función resolver usa el default del tipo.
ALTER TABLE public.list
    ADD COLUMN IF NOT EXISTS min_similarity numeric(4,3)
    CHECK (min_similarity >= 0 AND min_similarity <= 1);

COMMENT ON COLUMN public.list.min_similarity IS
    'Umbral de similitud específico de esta lista. NULL = usar default de list_type_config.';

-- -----------------------------------------------------------------------------
-- 4. FK list.type -> list_type_config.list_type
-- -----------------------------------------------------------------------------
-- Paso defensivo: si existe alguna lista con un type no presente en el config
-- (ej. de data legacy), la insertamos con un default neutro antes de crear la FK.
-- Sin este step, el ALTER TABLE ADD FK fallaría con violación de integridad.
INSERT INTO public.list_type_config (list_type, default_min_similarity, description)
SELECT DISTINCT l.type, 0.750,
    'Auto-generado por V005: tipo preexistente sin config explícita. Ajustar.'
FROM public.list l
LEFT JOIN public.list_type_config c ON c.list_type = l.type
WHERE c.list_type IS NULL
  AND l.type IS NOT NULL
ON CONFLICT (list_type) DO NOTHING;

-- DROP + ADD para idempotencia (Postgres no tiene ADD CONSTRAINT IF NOT EXISTS).
ALTER TABLE public.list
    DROP CONSTRAINT IF EXISTS fk_list_type_config;

ALTER TABLE public.list
    ADD CONSTRAINT fk_list_type_config
    FOREIGN KEY (type)
    REFERENCES public.list_type_config (list_type)
    ON UPDATE CASCADE
    ON DELETE RESTRICT;

-- -----------------------------------------------------------------------------
-- 5. Función helper: resolve_similarity_threshold(list_id)
-- -----------------------------------------------------------------------------
-- Devuelve el umbral efectivo para una lista dada, aplicando el fallback
-- override → default. STABLE porque depende del contenido de list y config,
-- pero no cambia dentro de una query.
CREATE OR REPLACE FUNCTION public.resolve_similarity_threshold(p_list_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(l.min_similarity, c.default_min_similarity)
    FROM public.list l
    JOIN public.list_type_config c ON c.list_type = l.type
    WHERE l.id = p_list_id;
$$;

COMMENT ON FUNCTION public.resolve_similarity_threshold(uuid) IS
    'Devuelve el umbral de similitud efectivo para una lista: '
    'list.min_similarity si está seteado, si no list_type_config.default_min_similarity. '
    'Llamada desde run_screening para decidir qué matches generan alerta.';

COMMIT;

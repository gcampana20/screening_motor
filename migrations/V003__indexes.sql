-- =============================================================================
-- V002__indexes.sql
-- -----------------------------------------------------------------------------
-- Índices optimizados para las dos operaciones hot del motor de screening:
--   1. Búsqueda por similitud de nombres (GIN trigram con pg_trgm).
--   2. Búsqueda exacta por tax_id normalizado.
-- Además cubre las foreign keys más consultadas y agrega partial indexes
-- para el dashboard de alertas activas por analista.
--
-- NOTA: No se usa CREATE INDEX CONCURRENTLY porque no puede correr dentro
-- de una transacción y este script está pensado para deploy limpio (Docker).
-- En producción conviene migrar a CONCURRENTLY en un script aparte.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- GRUPO 1: GIN trigram (búsqueda por similitud)
-- -----------------------------------------------------------------------------
-- Índice funcional sobre normalize_name(full_name). Hot path: matching de
-- entidades del tenant contra entries de las listas.
CREATE INDEX IF NOT EXISTS ix_sle_fullname_trgm
    ON public.screening_list_entry
    USING GIN (public.normalize_name(full_name) gin_trgm_ops);

-- Reverse lookup: cuando una lista cambia, buscamos personas que matcheen
-- con las nuevas entries (screening ongoing, task #8).
CREATE INDEX IF NOT EXISTS ix_person_fullname_trgm
    ON public.person
    USING GIN (
        public.normalize_name(
            COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')
        ) gin_trgm_ops
    );

-- Idem para empresas.
CREATE INDEX IF NOT EXISTS ix_company_name_trgm
    ON public.company
    USING GIN (public.normalize_name(name) gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- GRUPO 2: B-tree sobre tax_id_normalized (búsqueda exacta por documento)
-- -----------------------------------------------------------------------------
-- Compuesto (tax_id_normalized, country) porque search_by_tax_id filtra por
-- ambos. tax_id_normalized va primero porque es mucho más selectivo.
-- Partial para ignorar filas sin tax_id: no tiene sentido indexar NULLs.
CREATE INDEX IF NOT EXISTS ix_sle_tax_id_country
    ON public.screening_list_entry (tax_id_normalized, country)
    WHERE tax_id_normalized IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_person_tax_id_country
    ON public.person (tax_id_normalized, country)
    WHERE tax_id_normalized IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_company_tax_id_country
    ON public.company (tax_id_normalized, country)
    WHERE tax_id_normalized IS NOT NULL;

-- -----------------------------------------------------------------------------
-- GRUPO 3: Foreign keys consultadas (JOINs y filtros por tenant)
-- -----------------------------------------------------------------------------
-- Multi-tenancy: casi todas las queries filtran por tenant_id.
CREATE INDEX IF NOT EXISTS ix_person_tenant        ON public.person        (tenant_id);
CREATE INDEX IF NOT EXISTS ix_company_tenant       ON public.company       (tenant_id);
CREATE INDEX IF NOT EXISTS ix_account_tenant       ON public.account       (tenant_id);
CREATE INDEX IF NOT EXISTS ix_analyst_tenant       ON public.analyst       (tenant_id);
CREATE INDEX IF NOT EXISTS ix_list_tenant          ON public.list          (tenant_id);
CREATE INDEX IF NOT EXISTS ix_alert_tenant         ON public.alert         (tenant_id);
CREATE INDEX IF NOT EXISTS ix_alert_comment_tenant ON public.alert_comment (tenant_id);

-- Joins list -> entries.
CREATE INDEX IF NOT EXISTS ix_sle_list ON public.screening_list_entry (list_id);

-- Joins desde alert a sus FKs (navegación y dedup check en run_screening).
CREATE INDEX IF NOT EXISTS ix_alert_person
    ON public.alert (person_id) WHERE person_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_alert_company
    ON public.alert (company_id) WHERE company_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_alert_sle
    ON public.alert (screening_list_entry_id);
CREATE INDEX IF NOT EXISTS ix_alert_analyst
    ON public.alert (analyst_id) WHERE analyst_id IS NOT NULL;

-- Historial y comentarios (lookups por alert).
CREATE INDEX IF NOT EXISTS ix_ash_alert
    ON public.alert_status_history (alert_id);
CREATE INDEX IF NOT EXISTS ix_alert_comment_alert
    ON public.alert_comment (alert_id);
CREATE INDEX IF NOT EXISTS ix_alert_comment_analyst
    ON public.alert_comment (analyst_id) WHERE analyst_id IS NOT NULL;

-- Account (persona/empresa dueña).
CREATE INDEX IF NOT EXISTS ix_account_person
    ON public.account (person_id) WHERE person_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_account_company
    ON public.account (company_id) WHERE company_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- GRUPO 4: Partial indexes para dashboard de alertas activas
-- -----------------------------------------------------------------------------
-- vw_pending_alerts_by_analyst filtra status IN ('PENDING','REVIEWING') y
-- agrupa por analista. Un partial index solo sobre alertas activas es
-- mucho más chico y rápido que uno completo.
CREATE INDEX IF NOT EXISTS ix_alert_active_by_analyst
    ON public.alert (tenant_id, analyst_id)
    WHERE status IN ('PENDING', 'REVIEWING');

-- Aging de alertas: solo nos interesa el created_at de las abiertas.
CREATE INDEX IF NOT EXISTS ix_alert_active_aging
    ON public.alert (created_at)
    WHERE status IN ('PENDING', 'REVIEWING');

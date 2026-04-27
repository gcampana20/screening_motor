-- =============================================================================
-- V004__rls_policies.sql
-- -----------------------------------------------------------------------------
-- Row Level Security (RLS) para multi-tenancy.
--
-- Objetivo:
--   Mover la garantía de aislamiento entre tenants desde el código de la app
--   a la base de datos. Si un dev se olvida de agregar WHERE tenant_id = X,
--   o un bug pasa el tenant equivocado, Postgres lo filtra igual.
--
-- Contrato con la aplicación:
--   Al iniciar cada request (después de autenticar al usuario), la app ejecuta:
--       SET LOCAL app.tenant_id = '<uuid-del-tenant>';
--   A partir de ese momento, cualquier query del backend solo ve filas del
--   tenant correspondiente. Si la variable no está seteada, fail-closed:
--   el usuario no ve nada (0 filas), no hay error.
--
-- Modo de enforcement:
--   Usamos FORCE ROW LEVEL SECURITY para que las policies se apliquen también
--   al owner de la tabla (postgres). Superuser todavía bypasea por definición
--   de Postgres (no se puede evitar con FORCE), lo que es correcto para
--   migraciones y tareas admin. Esto significa que:
--     - Desde la app (rol no-superuser): RLS aplica siempre → seguro.
--     - Desde psql como postgres (superuser): bypass → podemos correr migrations,
--       seeds y debugging sin trabas.
--   Para producción, se recomienda crear un rol app_screening no-superuser y
--   configurar la app para conectarse con ese rol. Documentar en README.
--
-- Clasificación de tablas:
--   A) Tenant-scoped directo (tenant_id NOT NULL, 1:1 con un tenant):
--        person, company, account, analyst, alert, alert_comment
--      → Policy: tenant_id = current_tenant_id()
--
--   B) Shared + tenant-scoped (tenant_id NULLABLE, NULL = global):
--        list                            (ej. OFAC, ONU son globales;
--                                         blacklist de un tenant es privada)
--      → Policy: tenant_id IS NULL OR tenant_id = current_tenant_id()
--
--   C) Child table sin tenant_id propio (se filtra via parent):
--        screening_list_entry            (hereda visibilidad de list)
--        alert_status_history            (hereda visibilidad de alert)
--      → Policy: EXISTS (SELECT 1 FROM parent WHERE ...)
--
--   D) Sin RLS: tenant (catálogo de tenants — todos los roles ven todas
--                las filas; el aislamiento se hace por las tablas que
--                referencian tenant.id, no por el catálogo en sí).
--                Si alguna vez se restringe, sería con un rol "admin app"
--                separado, no con RLS por tenant_id.
--
-- Idempotencia:
--   ALTER TABLE ... ENABLE/FORCE ROW LEVEL SECURITY es idempotente.
--   CREATE POLICY no soporta IF NOT EXISTS (hasta PG 17), así que usamos
--   DROP POLICY IF EXISTS + CREATE POLICY para que el script sea re-runnable.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Helper: current_tenant_id()
-- -----------------------------------------------------------------------------
-- Lee app.tenant_id de la sesión. Devuelve NULL si no está seteada
-- (o si es string vacío), gracias al segundo arg `true` de current_setting
-- que activa "missing_ok" y al NULLIF.
--
-- STABLE (no IMMUTABLE) porque current_setting puede cambiar entre queries
-- dentro de la misma sesión. Es suficiente para usar en policies.
CREATE OR REPLACE FUNCTION public.current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid;
$$;

COMMENT ON FUNCTION public.current_tenant_id() IS
    'Devuelve el tenant_id de la sesión actual (app.tenant_id) o NULL. '
    'La app debe setear SET LOCAL app.tenant_id = ''<uuid>'' al iniciar '
    'cada request. Usada por las policies de RLS.';

-- -----------------------------------------------------------------------------
-- 2. Grupo A — Tenant-scoped directo
-- -----------------------------------------------------------------------------
-- Tablas con tenant_id NOT NULL. Policy simple: tenant_id = current_tenant_id().
-- WITH CHECK espeja USING para evitar que alguien haga UPDATE/INSERT
-- poniendo un tenant_id ajeno.

-- person
ALTER TABLE public.person ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.person FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS person_tenant_isolation ON public.person;
CREATE POLICY person_tenant_isolation ON public.person
    USING      (tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id = public.current_tenant_id());

-- company
ALTER TABLE public.company ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS company_tenant_isolation ON public.company;
CREATE POLICY company_tenant_isolation ON public.company
    USING      (tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id = public.current_tenant_id());

-- account
ALTER TABLE public.account ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_tenant_isolation ON public.account;
CREATE POLICY account_tenant_isolation ON public.account
    USING      (tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id = public.current_tenant_id());

-- analyst
ALTER TABLE public.analyst ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analyst FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS analyst_tenant_isolation ON public.analyst;
CREATE POLICY analyst_tenant_isolation ON public.analyst
    USING      (tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id = public.current_tenant_id());

-- alert
ALTER TABLE public.alert ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alert FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS alert_tenant_isolation ON public.alert;
CREATE POLICY alert_tenant_isolation ON public.alert
    USING      (tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id = public.current_tenant_id());

-- alert_comment
ALTER TABLE public.alert_comment ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alert_comment FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS alert_comment_tenant_isolation ON public.alert_comment;
CREATE POLICY alert_comment_tenant_isolation ON public.alert_comment
    USING      (tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id = public.current_tenant_id());

-- -----------------------------------------------------------------------------
-- 3. Grupo B — Shared + tenant-scoped (list)
-- -----------------------------------------------------------------------------
-- list.tenant_id puede ser NULL (lista global: OFAC, ONU, PEP) o un uuid
-- específico (lista interna del tenant: blacklist, whitelist, etc.).
-- Todos los tenants ven las globales; las internas solo su dueño.
ALTER TABLE public.list ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.list FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS list_tenant_isolation ON public.list;
CREATE POLICY list_tenant_isolation ON public.list
    USING      (tenant_id IS NULL OR tenant_id = public.current_tenant_id())
    WITH CHECK (tenant_id IS NULL OR tenant_id = public.current_tenant_id());

-- -----------------------------------------------------------------------------
-- 4. Grupo C — Child tables (filtro via parent)
-- -----------------------------------------------------------------------------

-- screening_list_entry: hereda visibilidad de la lista a la que pertenece.
-- El EXISTS es barato por ix_sle_list (FK) + PK de list (btree único).
-- Si el benchmark muestra contención, se migra a denormalizar sle.tenant_id
-- en una migration posterior + trigger de sincronización.
ALTER TABLE public.screening_list_entry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.screening_list_entry FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sle_tenant_isolation ON public.screening_list_entry;
CREATE POLICY sle_tenant_isolation ON public.screening_list_entry
    USING (
        EXISTS (
            SELECT 1
            FROM public.list l
            WHERE l.id = screening_list_entry.list_id
              AND (l.tenant_id IS NULL OR l.tenant_id = public.current_tenant_id())
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.list l
            WHERE l.id = screening_list_entry.list_id
              AND (l.tenant_id IS NULL OR l.tenant_id = public.current_tenant_id())
        )
    );

-- alert_status_history: hereda del alert padre.
-- No tiene tenant_id propio (por eso no aparece en V003 con ix_ash_tenant).
-- EXISTS con ix_ash_alert (FK) + PK de alert.
ALTER TABLE public.alert_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alert_status_history FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ash_tenant_isolation ON public.alert_status_history;
CREATE POLICY ash_tenant_isolation ON public.alert_status_history
    USING (
        EXISTS (
            SELECT 1
            FROM public.alert a
            WHERE a.id = alert_status_history.alert_id
              AND a.tenant_id = public.current_tenant_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.alert a
            WHERE a.id = alert_status_history.alert_id
              AND a.tenant_id = public.current_tenant_id()
        )
    );

-- -----------------------------------------------------------------------------
-- 5. Tenant catalog — RLS explícitamente DESHABILITADA
-- -----------------------------------------------------------------------------
-- El baseline (exportado desde pgAdmin) viene con ENABLE ROW LEVEL SECURITY
-- en `tenant`, pero NO le creamos policies acá. Si dejáramos eso así, el
-- default de Postgres es "deny todo" para no-superusers → la app no podría
-- ni listar tenants, lo que rompe casos básicos como un dropdown de selección.
--
-- Disable explícito acá deja claro que es decisión consciente: el catálogo
-- es público para cualquier rol con SELECT. El aislamiento real está en las
-- tablas que referencian tenant.id (person, alert, etc.), no en el catálogo.
ALTER TABLE public.tenant DISABLE ROW LEVEL SECURITY;

COMMIT;

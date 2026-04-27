-- =============================================================================
-- V011__app_role.sql
-- -----------------------------------------------------------------------------
-- Rol de aplicación NOSUPERUSER para que RLS aplique en runtime.
--
-- Contexto del problema:
--   La imagen oficial de postgres crea POSTGRES_USER (complif_admin) como
--   SUPERUSER por default. Los superusers BYPASEAN RLS aunque la tabla tenga
--   FORCE ROW LEVEL SECURITY — es comportamiento documentado de Postgres y no
--   se puede evitar con configuración. Resultado: si la app/sesión se conecta
--   como complif_admin, las policies de V004 son letra muerta y se ven datos
--   cross-tenant. El comment de V004 ya recomendaba esta separación; esta
--   migration la materializa.
--
-- Modelo de roles:
--   - complif_admin (SUPERUSER, owner de las tablas):
--       Solo para migraciones, seeds, y tareas administrativas. Bypasea RLS,
--       eso es correcto para que el init script pueda hacer su trabajo sin
--       depender del valor de app.tenant_id.
--   - complif_app (NOSUPERUSER, aplicación):
--       El que usa la API en runtime. RLS aplica. Único contrato: setear
--       app.tenant_id antes de cualquier query de negocio.
--
-- Por qué va como migration y no en el init script:
--   - Versionado: si mañana queremos staging/prod, esta migration corre ahí
--     igual que en local.
--   - Discoverable: aparece en la lista de migrations cuando alguien revisa
--     el repo, no escondido en docker/init/.
--   - Idempotente: el DO block + IF NOT EXISTS hace que se pueda re-correr.
--
-- Password en el SQL:
--   complif_app_dev — solo para desarrollo local. En prod se inyecta vía
--   secret manager (Vault, AWS SM, etc.) y se rota. Documentado en README.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Crear el rol (idempotente)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'complif_app') THEN
        CREATE ROLE complif_app
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS
            PASSWORD 'complif_app_dev';
        RAISE NOTICE 'Rol complif_app creado.';
    ELSE
        -- Asegura que un rol pre-existente con el mismo nombre quede en el
        -- estado correcto (en caso de re-runs o entornos donde alguien lo
        -- creó a mano antes).
        ALTER ROLE complif_app
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
        RAISE NOTICE 'Rol complif_app ya existe — atributos normalizados.';
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 2. Privilegios sobre objetos existentes
-- -----------------------------------------------------------------------------
-- USAGE en el schema (sin esto, ni siquiera puede listar tablas).
GRANT USAGE ON SCHEMA public TO complif_app;

-- DML sobre todas las tablas. SELECT/INSERT/UPDATE/DELETE — sin TRUNCATE
-- ni REFERENCES (no necesita crear FKs hacia public).
GRANT SELECT, INSERT, UPDATE, DELETE
    ON ALL TABLES IN SCHEMA public
    TO complif_app;

-- USAGE sobre sequences (para que los DEFAULT uuid_generate_v4() y similares
-- funcionen al insertar).
GRANT USAGE, SELECT
    ON ALL SEQUENCES IN SCHEMA public
    TO complif_app;

-- EXECUTE sobre funciones (run_screening, validate_tax_id, vistas, etc.).
GRANT EXECUTE
    ON ALL FUNCTIONS IN SCHEMA public
    TO complif_app;

-- -----------------------------------------------------------------------------
-- 3. Default privileges para objetos FUTUROS
-- -----------------------------------------------------------------------------
-- Sin esto, la próxima migration que cree una tabla nueva la dejaría
-- inaccesible para complif_app hasta que alguien le grantee a mano.
-- Aplica a objetos creados por complif_admin (el owner del schema).
ALTER DEFAULT PRIVILEGES FOR ROLE complif_admin IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO complif_app;

ALTER DEFAULT PRIVILEGES FOR ROLE complif_admin IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO complif_app;

ALTER DEFAULT PRIVILEGES FOR ROLE complif_admin IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO complif_app;

-- -----------------------------------------------------------------------------
-- 4. Verificación (no-op si todo OK; RAISE si falla)
-- -----------------------------------------------------------------------------
-- Catch básico para detectar misconfiguración temprano: el rol existe y NO
-- bypasea RLS. Si alguien lo edita y le pone BYPASSRLS por error, el init
-- aborta acá.
DO $$
DECLARE
    v_bypassrls boolean;
    v_super     boolean;
BEGIN
    SELECT rolbypassrls, rolsuper
      INTO v_bypassrls, v_super
      FROM pg_roles
     WHERE rolname = 'complif_app';

    IF v_super THEN
        RAISE EXCEPTION 'complif_app quedó como SUPERUSER — RLS no aplicaría.';
    END IF;
    IF v_bypassrls THEN
        RAISE EXCEPTION 'complif_app tiene BYPASSRLS — RLS no aplicaría.';
    END IF;

    RAISE NOTICE 'OK: complif_app es NOSUPERUSER y NOBYPASSRLS.';
END
$$;

COMMIT;

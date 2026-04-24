#!/bin/bash
# =============================================================================
# docker/init/01-init.sh
# -----------------------------------------------------------------------------
# Script de inicialización del container Postgres. Se ejecuta UNA sola vez,
# en el primer boot (cuando el volumen está vacío). Ordena explícitamente:
#
#   1. Extensiones (V000)
#   2. Baseline DDL: tables → functions → triggers → views
#   3. Migraciones V001..V010
#   4. Seeds
#
# Usamos ON_ERROR_STOP=1 para que cualquier fallo corte el init y no dejemos
# una DB a medio construir. Si cambia el schema base, los paths hardcodeados
# de abajo hay que actualizarlos acá.
# =============================================================================

set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc -U ${POSTGRES_USER} -d ${POSTGRES_DB}"

# Los archivos de /repo/baseline/ fueron exportados desde pgAdmin y traen
# líneas `ALTER TABLE ... OWNER to postgres;` (o `OWNER TO postgres`) al
# final. Como este container corre como complif_admin y el rol "postgres"
# no existe, psql aborta con ON_ERROR_STOP=1. En lugar de tocar los SQL
# fuente, los preprocesamos in-flight: cualquier OWNER to postgres se
# reemplaza por el owner real (POSTGRES_USER). sed es no-op si el archivo
# no tiene la línea, así que da lo mismo usarlo para baseline, migrations
# o seeds.
run() {
    local f="$1"
    echo "  >> $f"
    sed -E "s/OWNER[[:space:]]+(to|TO)[[:space:]]+postgres/OWNER TO ${POSTGRES_USER}/g" "$f" \
        | $PSQL
}

# -----------------------------------------------------------------------------
# 1. Extensiones (V000 primero — DEFAULT uuid_generate_v4() en los CREATE TABLE
#    requiere uuid-ossp habilitado).
# -----------------------------------------------------------------------------
echo "=== 1/4  Extensiones ==="
run "/repo/migrations/V000__extensions.sql"

# -----------------------------------------------------------------------------
# 2. Baseline DDL en orden de dependencia (FKs, funciones antes de triggers,
#    triggers antes de que corran inserts, views al final).
# -----------------------------------------------------------------------------
echo "=== 2/4  Baseline DDL ==="

echo "--- 2a. Tables ---"
# Orden por dependencia de FKs:
#   tenant → person, company → account (FKs a person/company)
#         → analyst
#         → list → screening_list_entry
#         → alert (FKs a todo lo anterior) → alert_comment, alert_status_history
run "/repo/baseline/tables/tenant.sql"
run "/repo/baseline/tables/person.sql"
run "/repo/baseline/tables/company.sql"
run "/repo/baseline/tables/account.sql"
run "/repo/baseline/tables/analyst.sql"
run "/repo/baseline/tables/list.sql"
run "/repo/baseline/tables/screening_list_entry.sql"
run "/repo/baseline/tables/alert.sql"
run "/repo/baseline/tables/alert_comment.sql"
run "/repo/baseline/tables/alert_status_history.sql"

echo "--- 2b. Functions ---"
run "/repo/baseline/functions/p_name.sql"
run "/repo/baseline/functions/p_tax.sql"
run "/repo/baseline/functions/p_calculate_similarity.sql"
run "/repo/baseline/functions/search_by_tax_id.sql"
run "/repo/baseline/functions/log_alert_status_change.sql"

echo "--- 2c. Triggers ---"
run "/repo/baseline/triggers/alert_status_history.sql"

echo "--- 2d. Views ---"
run "/repo/baseline/views/alert_aging.sql"
run "/repo/baseline/views/pending_alerts_by_analyst.sql"
run "/repo/baseline/views/analyst_productivity.sql"
run "/repo/baseline/views/screening_metrics.sql"
run "/repo/baseline/views/screening_coverage.sql"

# -----------------------------------------------------------------------------
# 3. Migraciones V001..V010 en orden. Excluimos V000 (ya corrió en paso 1).
#    El glob V0[0-9]* + sort natural mantiene el orden V001, V002, ... V010.
# -----------------------------------------------------------------------------
echo "=== 3/4  Migraciones V001..V010 ==="
for f in $(ls /repo/migrations/V*.sql | grep -v 'V000__' | sort -V); do
    run "$f"
done

# -----------------------------------------------------------------------------
# 4. Seeds (datos de demo).
# -----------------------------------------------------------------------------
echo "=== 4/4  Seeds ==="
run "/repo/seeds/seed_data.sql"

echo ""
echo "============================================================"
echo " Inicialización completa. DB lista: ${POSTGRES_DB}"
echo "============================================================"

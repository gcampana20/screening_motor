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

run() {
    local f="$1"
    echo "  >> $f"
    $PSQL -f "$f"
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
run "/repo/baseline/tables/tenant SQL.sql"
run "/repo/baseline/tables/account SQL.sql"
run "/repo/baseline/tables/analyst SQL.sql"
run "/repo/baseline/tables/person SQL.sql"
run "/repo/baseline/tables/company SQL.sql"
run "/repo/baseline/tables/list SQL.sql"
run "/repo/baseline/tables/screening_list_entry SQL.sql"
run "/repo/baseline/tables/alert SQL.sql"
run "/repo/baseline/tables/alert comment SQL.sql"
run "/repo/baseline/tables/alert status history SQL.sql"

echo "--- 2b. Functions ---"
run "/repo/baseline/functions/p_name function.sql"
run "/repo/baseline/functions/p_tax function.sql"
run "/repo/baseline/functions/p_calculate_similarity function.sql"
run "/repo/baseline/functions/search_by_tax_id function.sql"
run "/repo/baseline/functions/log_alert_status_change SQL.sql"

echo "--- 2c. Triggers ---"
run "/repo/baseline/trigger_alert_status_history.sql"

echo "--- 2d. Views ---"
run "/repo/baseline/views/view alert_aging.sql"
run "/repo/baseline/views/view pending_alerts_by_analyst.sql"
run "/repo/baseline/views/view analyst_productivity.sql"
run "/repo/baseline/views/view screening_metrics.sql"
run "/repo/baseline/views/view screening_coverage.sql"

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

#!/usr/bin/env bash
# Local end-to-end integration run against a throwaway SQL Server container.
#
#   docker run -d --name uprtest -e ACCEPT_EULA=Y \
#     -e 'MSSQL_SA_PASSWORD=<pw>' -e MSSQL_PID=Developer \
#     -p 14333:1433 mcr.microsoft.com/mssql/server:2022-latest
#   test/run_local_it.sh
#
# Runs: seed -> DDL -> load -> verify -> load again -> verify (idempotency).
set -euo pipefail

python3 "$(dirname "$0")/check_runner_mode.py"

CONTAINER="${CONTAINER:-uprtest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/var/opt/mssql/data

run_sql() {
    docker exec "$CONTAINER" bash -lc \
      "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -C -b -W -s'|' -i $DEST/$1"
}

for f in test/local_it_setup.sql test/local_it_verify.sql test/local_it_counts.sql \
         test/local_it_search.sql test/local_it_search_v2.sql test/run_test_and_results.sql \
         ddl/03_new_upr_schema.sql scripts/load_upr_master.sql scripts/search_upr_master.sql; do
    docker cp "$ROOT/$f" "$CONTAINER:$DEST/"
done

echo "### 1. seed incoming data"
run_sql local_it_setup.sql | tail -3
echo "### 2. create hierarchical schema"
run_sql 03_new_upr_schema.sql | tail -2
echo "### 3. first load"
run_sql load_upr_master.sql | tail -22
echo "### 4. verify"
run_sql local_it_verify.sql | tail -40
echo "### 5. counts after first load"
first_counts="$(run_sql local_it_counts.sql)"
echo "$first_counts"
echo "### 6. second load (idempotency)"
run_sql load_upr_master.sql | tail -22
echo "### 7. counts after second load - must be identical"
second_counts="$(run_sql local_it_counts.sql)"
echo "$second_counts"
if [[ "$first_counts" != "$second_counts" ]]; then
    echo "FAIL: unchanged rerun changed business row counts" >&2
    exit 1
fi
echo "### 8. verify again"
run_sql local_it_verify.sql | tail -6
echo "### 9. client validation report (run_test_and_results.sql)"
client_report="$(run_sql run_test_and_results.sql)"
echo "$client_report" | tail -30
if [[ "$client_report" == *$'\nFAIL|'* ]]; then
    echo "FAIL: client validation report contains failing checks" >&2
    exit 1
fi
echo "### 10. create + exercise search procedure"
run_sql search_upr_master.sql | tail -3
run_sql local_it_search.sql | tail -25
run_sql local_it_search_v2.sql | tail -5

echo "### 11. native client audit layout, row audit, readable values and rollback"
CONTAINER="$CONTAINER" python3 "$ROOT/test/check_client_schema_load.py"

# Earlier trigger/context-specific regression scripts are retained for historical
# migrations. They require the legacy JSON audit architecture and are not R8 tests.

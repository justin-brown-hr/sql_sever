#!/usr/bin/env bash
# Run the full hierarchical UPR pipeline against SQL Server.
#
# Usage:   ./scripts/run_all.sh [server] [user] [password] [--real-data]
# Example: ./scripts/run_all.sh localhost sa 'YourStrong!Passw0rd'
#
# Default runs with the bundled sample data (test/local_it_setup.sql).
# Pass --real-data to skip sample data: load your own rows into
# dbo.MAIncomingTableX1 / dbo.SDATIncomingTableX1 first.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-localhost}"
USER="${2:-sa}"
PASS="${3:-}"
MODE="${4:-}"

if ! command -v sqlcmd &>/dev/null; then
    echo "sqlcmd not found. Install SQL Server tools or run the scripts in SSMS."
    exit 1
fi

AUTH=(-S "$SERVER" -U "$USER" -P "$PASS" -C)
[[ -z "$PASS" ]] && AUTH=(-S "$SERVER" -E)

run() {
    echo ">> $1"
    sqlcmd "${AUTH[@]}" -b -i "$ROOT/$1"
}

if [[ "$MODE" != "--real-data" ]]; then
    run "test/local_it_setup.sql"        # incoming tables + sample data
fi
run "ddl/03_new_upr_schema.sql"          # hierarchical schema (drop + create)
run "scripts/load_upr_master.sql"        # the load
run "test/run_test_and_results.sql"      # validation report
run "scripts/search_upr_master.sql"      # create dbo.usp_UPR_Search
echo "Pipeline complete."

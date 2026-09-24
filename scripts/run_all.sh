#!/usr/bin/env bash
# Run the full hierarchical UPR pipeline against SQL Server.
#
# Usage:   ./scripts/run_all.sh [server] [user] [password] [--real-data|--sample-data]
# Example: ./scripts/run_all.sh localhost sa 'YourStrong!Passw0rd'
#
# Default upgrades the existing schema without resetting tables.
# Use --sample-data only for a disposable database: it recreates the schema.
# Load real incoming data into dbo.MAIncomingTableX1 / dbo.SDATIncomingTableX1 first.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-localhost}"
SQL_USER="${2:-sa}"
PASS="${3:-}"
MODE="${4:-}"
if [[ $# -gt 4 ]]; then
    echo "Too many arguments. Usage: $0 [server] [user] [password] [--real-data|--sample-data]" >&2
    exit 2
fi
case "$MODE" in
    ""|--real-data) MODE=--real-data ;;
    --sample-data) ;;
    *) echo "Unknown mode: $MODE. Use --real-data or --sample-data." >&2; exit 2 ;;
esac

if ! command -v sqlcmd &>/dev/null; then
    echo "sqlcmd not found. Install SQL Server tools or run the scripts in SSMS."
    exit 1
fi

AUTH=(-S "$SERVER" -U "$SQL_USER" -P "$PASS" -C)
[[ -z "$PASS" ]] && AUTH=(-S "$SERVER" -E)

run() {
    echo ">> $1"
    sqlcmd "${AUTH[@]}" -b -i "$ROOT/$1"
}

if [[ "$MODE" == "--sample-data" ]]; then
    run "test/local_it_setup.sql"        # incoming tables + sample data
    run "ddl/03_new_upr_schema.sql"      # disposable schema (drop + create)
fi
run "scripts/install_upr_audit.sql"      # row auditing for UPR model writes
run "scripts/load_upr_master.sql"        # the load
run "scripts/list_upr_audit.sql"         # load history and row/field changes
run "test/run_test_and_results.sql"      # validation report
run "scripts/search_upr_master.sql"      # install search and Property360 procedures
echo "Pipeline complete."

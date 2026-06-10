#!/usr/bin/env bash
# Run full UPR test pipeline against SQL Server
# Usage: ./scripts/run_all.sh [server] [user] [password]
# Example: ./scripts/run_all.sh localhost sa 'YourStrong!Passw0rd'

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-localhost}"
USER="${2:-sa}"
PASS="${3:-}"

if ! command -v sqlcmd &>/dev/null; then
    echo "sqlcmd not found. Install SQL Server tools or run scripts manually in SSMS."
    exit 1
fi

AUTH=(-S "$SERVER" -U "$USER" -P "$PASS" -C)
[[ -z "$PASS" ]] && AUTH=(-S "$SERVER" -E)

run() {
    echo ">> $1"
    sqlcmd "${AUTH[@]}" -b -i "$1"
}

run "$ROOT/ddl/01_create_schema.sql"
run "$ROOT/ddl/02_normalize_functions.sql"
run "$ROOT/test/seed_reference_data.sql"
run "$ROOT/test/seed_test_incoming.sql"
run "$ROOT/scripts/load_upr_master.sql"
run "$ROOT/test/run_test_and_results.sql"

echo ""
echo "All scripts completed successfully."

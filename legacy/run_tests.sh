#!/usr/bin/env bash
# Full test runner - requires SQL Server on port 1433
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-localhost}"
USER="${2:-sa}"
PASS="${3:-YourStrong!Passw0rd}"
PORT="${4:-1433}"
SQLCMD="${SQLCMD:-sqlcmd}"

export PATH="/home/user/.local/bin:$PATH"
if ! command -v "$SQLCMD" &>/dev/null; then
    echo "sqlcmd not found. Install go-sqlcmd or mssql-tools18."
    exit 1
fi

# Wait for SQL Server (up to 60s)
echo "Waiting for SQL Server at $SERVER:$PORT ..."
for i in $(seq 1 30); do
    if "$SQLCMD" -S "$SERVER,$PORT" -U "$USER" -P "$PASS" -C -Q "SELECT 1" &>/dev/null; then
        echo "SQL Server is ready."
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "ERROR: Cannot connect to SQL Server at $SERVER:$PORT"
        echo "Start SQL Server first, e.g.:"
        echo "  sudo systemctl start docker"
        echo "  docker run -d --name upr-sql -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='$PASS' -p 1433:1433 mcr.microsoft.com/mssql/server:2019-latest"
        exit 1
    fi
    sleep 2
done

run() {
    echo ""
    echo ">> $1"
    "$SQLCMD" -S "$SERVER,$PORT" -U "$USER" -P "$PASS" -C -b -i "$2"
}

LOG="$ROOT/test/TEST_RUN_LOG.txt"
exec > >(tee "$LOG") 2>&1

echo "UPR Test Run - $(date)"
echo "Server: $SERVER:$PORT"

run "Create schema"           "$ROOT/ddl/01_create_schema.sql"
run "Seed reference data"     "$ROOT/test/seed_reference_data.sql"
run "Seed test incoming data" "$ROOT/test/seed_test_incoming.sql"
run "Run UPR load"            "$ROOT/scripts/load_upr_master.sql"
run "Run test results"        "$ROOT/test/run_test_and_results.sql"

echo ""
echo "Full test log saved to: $LOG"
echo "ALL TESTS COMPLETED."

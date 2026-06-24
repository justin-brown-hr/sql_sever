#!/usr/bin/env bash
# Client-aligned integration test (UPRDB_Test + DHCA_Internal per docs/ddl.md)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-localhost}"
USER="${2:-sa}"
PASS="${3:-YourStrong!Passw0rd}"
PORT="${4:-1433}"
SQLCMD="${SQLCMD:-sqlcmd}"

export PATH="/home/user/.local/bin:$PATH"

echo "Waiting for SQL Server at $SERVER:$PORT ..."
for i in $(seq 1 30); do
    if "$SQLCMD" -S "$SERVER,$PORT" -U "$USER" -P "$PASS" -C -Q "SELECT 1" &>/dev/null; then
        echo "SQL Server is ready."
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "ERROR: Cannot connect to SQL Server."
        echo "Start Docker: sudo service docker start"
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

LOG="$ROOT/test/CLIENT_TEST_LOG.txt"
exec > >(tee "$LOG") 2>&1

echo "CLIENT INTEGRATION TEST - $(date)"
echo "Server: $SERVER:$PORT"

run "Setup client DB (ddl.md + DHCA)" "$ROOT/test/setup_client_db.sql"
run "Seed DHCA sample data"           "$ROOT/test/seed_dhca_sample.sql"
run "Run UPR load"                    "$ROOT/scripts/load_upr_master.sql"

echo ""
echo ">> Quick result counts"
"$SQLCMD" -S "$SERVER,$PORT" -U "$USER" -P "$PASS" -C -Q "
USE UPRDB_Test;
SELECT N'UPROPERTYRECORDS' AS T, COUNT(*) AS Cnt FROM dbo.UPROPERTYRECORDS
UNION ALL SELECT N'XREF', COUNT(*) FROM dbo.UPROPERTYRECORDS_XREF
UNION ALL SELECT N'Review_Q', COUNT(*) FROM dbo.UPRMATCHREVIEW_Q
UNION ALL SELECT N'StatusHistory', COUNT(*) FROM dbo.UPRSTATUSHISTORY;
"

echo ""
echo "Log: $LOG"
echo "CLIENT TEST COMPLETED."

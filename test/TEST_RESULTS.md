# UPR Test Results

**Date:** June 9, 2026  
**Environment:** Ubuntu 22.04 (SQL Server not available locally)

---

## Offline Validation — PASSED

All checks passed without SQL Server (file integrity, data counts, normalization logic).

| Check | Result |
|-------|--------|
| Deliverable files present | PASS |
| AddressMaster rows | PASS (100) |
| SDAT rows | PASS (101) |
| Normalization: STREET→ST | PASS |
| Normalization: LANE→LN | PASS |
| Account 20002002 CASE match (LANE/LN) | PASS |
| Account 10001001 eProperty match | PASS |

---

## SQL Server Integration Test — SKIPPED

SQL Server is **not running** on `localhost:1433` in this environment.

To run the full integration test on your machine:

```bash
# 1. Start SQL Server (Docker)
sudo systemctl start docker
docker run -d --name upr-sql \
  -e 'ACCEPT_EULA=Y' \
  -e 'MSSQL_SA_PASSWORD=YourStrong!Passw0rd' \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2019-latest

# 2. Wait ~20 seconds for startup, then run tests
sleep 20
./scripts/run_tests.sh localhost sa 'YourStrong!Passw0rd'
```

Or in **SSMS**, run scripts 1–5 from `DELIVERY.md`.

---

## Expected Integration Results (after load)

When SQL Server tests run successfully, `run_test_and_results.sql` should show:

| Scenario | Account | Expected |
|----------|---------|----------|
| MA+SDAT+eProperty match | 10001001 | UPR created, eProperty XREF = MATCH |
| MA-only, CASE match | 20002002 | CASE XREF = MATCH (500 OAK LANE ↔ LN) |
| MA+SDAT, MPDU match | 30003003 | MPDU XREF = MATCH |
| No external match | 40004004 | Review Queue entry |
| CONDO buildings | various | Building + Unit created |
| No duplicate accounts | all | 0 duplicates |
| Audit log | all | >= 1 entries |

---

## How to Re-run Offline Validation

```bash
python3 test/validate_offline.py
```

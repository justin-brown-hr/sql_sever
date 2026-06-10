# Message to Send Client

Copy and paste below:

---

Hi [Client Name],

The UPR Master Load package is ready for review.

**Deliverables included:**

1. **`scripts/load_upr_master.sql`** — Single load script that normalizes addresses, loads AddressMaster + SDAT, writes to UPROPERTYRECORD and all related tables (XREF, Review Queue, Status History, Contact, Building/Unit), seeds SourceSystem/MatchMethod/MatchConfidence reference data, writes AuditLog, and prints processing statistics. Wrapped in a transaction for safe re-runs.

2. **`scripts/search_upr_master.sql`** — Search UPR Master by account, parcel, address, owner, city/ZIP, property type, source system, and status.

3. **Test data & results** — `test/seed_test_incoming.sql` contains ~100 AddressMaster rows and 102 SDAT rows (expanded from your samples), plus external match data. `test/run_test_and_results.sql` runs PASS/FAIL checks on your four sample scenarios (10001001, 20002002, 30003003, 40004004).

4. **`README.md`** and **`DELIVERY.md`** — Assumptions, normalization logic, run steps, and rollback instructions.

**To run (SSMS):**
1. `ddl/01_create_schema.sql`
2. `test/seed_reference_data.sql`
3. `test/seed_test_incoming.sql`
4. `scripts/load_upr_master.sql`
5. `test/run_test_and_results.sql`

Please see `DELIVERY.md` for full details. Happy to walk through results or adjust matching rules if needed.

Best regards,  
[Your Name]

---

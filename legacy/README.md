# Legacy (flat UPR model) - archived

These files belong to the old flat `UPROPERTYRECORDS` model and are kept for
reference only. **Do not run them** - the hierarchical model
(`ddl/03_new_upr_schema.sql` + `scripts/load_upr_master.sql`) replaces them
completely, per the client's NewUPRTABLEUSED / Response specifications.

| File | Was |
|------|-----|
| `01_create_schema.sql` | Old flat schema + incoming table definitions |
| `02_normalize_functions.sql` | Standalone normalization functions |
| `load_upr_master_legacy_flat.sql` | Old flat load script |
| `01_review_q_schema_fix.sql`, `02_review_q_client_alter.sql`, `diagnose_duplicate_reviewq.sql` | Old Review_Q hotfixes |
| `seed_*.sql`, `setup_client_db.sql` | Old-schema test data |
| `run_client_test.sh`, `run_tests.sh`, `static_check_load.py`, `validate_offline.py`, `TEST_RESULTS.md` | Old test harness |

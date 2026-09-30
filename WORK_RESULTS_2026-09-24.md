# Combined work results — September 24, 2026

> Latest September 29 contract: [retain the original AncestorUPRID API column](CLIENT_CLOSURE_API_2026-09-29.md).
> The level-0 display test is read-only and does not change UPR_CLOSURE.

> September 28 follow-up: [ancestor query including root level 0](CLIENT_CLOSURE_LEVEL_2026-09-28.md).
> The current ZIP also includes that read-only report and its separate validation notes.

**Scripts updated; SQL Server execution and deployment are pending.** This report
covers the three items the user requested in one unsent delivery. It does not
contain invented database output or imply that the client has accepted the work.

| Work | Implemented result | Main files |
|---|---|---|
| 1. Search specification | Extended existing search, added Property360, contextual identity lookups, address/owner matching, pagination and explicit Portal authorization inputs; preserved long accounts and added parcel XREF support | search_upr_master.sql, load_upr_master.sql, list_upr_hierarchy.sql |
| 2. EntityKey feedback | Documented what the key means and why JSON was used; readable RecordKey by default with optional raw mode; explains negative registry IDs | list_upr_audit.sql, CLIENT_AUDIT_KEY_UPDATE_2026-09-24.md |
| 3. Actual AuditLog layout | Physical nine-column AuditLog; separate technical context; updated triggers, loader, migration, diagnostics, reporting and regressions | install_upr_audit.sql, ddl/03_new_upr_schema.sql, check_upr_client_schema.sql, test/check_audit_layout.py |

## Validation performed locally

- Hierarchical static checks: passed.
- DDL/loader schema contract: passed (28 tables; 46 INSERTs, 5 MERGEs,
  5 OUTPUT INTO clauses and 34 INSERT/SELECT arity checks).
- Runner mode checks: passed, including default/real-data/sample-data handling.
- Modified Python files: AST syntax checks passed; integration runner shell
  syntax passed; git whitespace/error check passed.
- T-SQL syntax parsing: passed for changed DDL, installer, loader, audit report,
  schema/account diagnostics and client validation report, including embedded
  literal SQL batches and reconstructed native/composite/text-key triggers.
  Search SQL and its assertions also passed syntax/static review in work 1.
  The regression fixture's standalone EXECUTE AS/REVERT statements are unsupported
  by this parser; they were reviewed against [Microsoft's execution-context
  reference](https://learn.microsoft.com/en-us/sql/t-sql/statements/revert-transact-sql?view=sql-server-ver17),
  with database execution still pending.
- Delivery ZIP: payloads checked against current files and a regenerated SHA-256
  manifest. Existing package filename retained; contents are this revision.

Parsing/static review does not execute SQL, validate permissions on the client
server, prove history preservation, or measure search performance.

## Prepared database checks — not executed here

The repository integration runner now includes phase 22 for the new layout:
existing client history without raw keys, repeat installs, unmapped entity IDs,
prior normalized-history migration, INT overflow rollback, reader permissions,
multirow event/context pairing and transaction rollback. Existing suites cover
legacy migration, readable/raw keys, deleted UPR associations, failed loads,
hierarchy rules and search behavior. A Docker SQL Server runtime and repository
history (revision fce184f for the previous implementation) are required for these
repository regressions; the delivery ZIP alone is not the full test harness.

The client validation report now includes the physical AuditLog layout, context
and view existence, and missing entity mappings. These will produce actual
PASS/FAIL rows when run on the restored client database; no such result rows have
been generated in this workspace.

## Acceptance still needed

- Run the latest installer before the latest loader/reports on a restored database,
  then execute the integration and real-data checks. No SQL Server connection,
  sqlcmd or Docker runtime is available in this workspace.
- Compare small screenshot text with the original CREATE TABLE statement.
  New tables use DATETIME2(3), matching the previous project DDL; existing matching
  client tables retain their precision. Confirm the client's entity-name mapping.
- Housing Portal API code must supply authorization scope and disclosure flags;
  the repository supplies SQL, not the Portal API implementation. Validate fuzzy
  ranking and performance with representative production-volume data.

Read [the latest installation order](CLIENT_AUDIT_LAYOUT_2026-09-24.md),
[search contract](CLIENT_SEARCH_UPDATE_2026-09-24.md), and
[key explanation](CLIENT_AUDIT_KEY_UPDATE_2026-09-24.md).
`CLIENT_MESSAGE_2026-09-24.txt` contains the combined draft; it has not been sent.

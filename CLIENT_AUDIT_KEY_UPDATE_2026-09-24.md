# EntityKey explanation and audit report update — September 24, 2026

This addresses the client's question about EntityKey in the **previous delivery**.
The separate search implementation is new work that the client has not yet
reviewed. The quoted message does not include the actual displayed value; the
explanation below is based on the prior scripts and covers both structured keys
and the related numeric audit record identifier.

## What EntityKey means and why it was written this way

`AUDIT_LOG.EntityKey` records the primary-key column names and values identifying
which table row changed. It was introduced as audit support so one event table
could describe changes across tables with different keys.

For an ordinary Unit row, `{"UnitID":123}` means Unit table row 123. UnitID is the
Unit table's row identifier; the Unit's UPRID is a separate master identity.

A closure record is identified by a pair, for example
`{"UPRAncestry":10025,"DescendantUPRID":10026}`. It records a relationship from
UPR 10025 to UPR 10026. Either ID alone can occur in many closure rows and cannot
identify this particular relationship. JSON retains both column names and values
in one audit field without dropping part of the key. The relationship may be
an ancestor path or a self-link; it is not necessarily an immediate parent edge.

These fields have different purposes:

| Field | Meaning |
|---|---|
| AuditLogID / report AuditID | One audit event; the same row can have many events. |
| EntityID | Identifies the table/entity in REF_ENTITY_IDENTIFICATION. |
| EntityRecordID | Native integer row key where available; otherwise a stable internal registry reference for the full composite/text key. Read it together with EntityID. |
| EntityKey / report RecordKey | The complete identifying key, including its column names. |
| UPRID | Associated live master UPR, when a single association can be established. |
| OriginalUPRID | Retains the event's original UPR association, including after deletion. |

For composite or text keys, the previous implementation uses the negative of an
`AUDIT_ENTITY_RECORD.RecordID` as EntityRecordID. A value such as -57 is an internal
audit reference, not a negative UPRID or an error code. Keeping EntityKey alongside
it makes the actual row identity available without interpreting that registry ID.

This design and the new audit fields should have been explained with the previous
delivery. It is not a field added by the new search work.

## What this update changes

Only the report procedure in `scripts/list_upr_audit.sql` changes audit behavior.
Its existing RecordKey output is readable by default in both changed-row and
field-detail results:

| Stored EntityKey / previous display | New default RecordKey display |
|---|---|
| `{"UnitID":123}` | `[UnitID] = 123` |
| `{"UPRAncestry":10025,"DescendantUPRID":10026}` | `[UPRAncestry] = 10025; [DescendantUPRID] = 10026` |
| `{"Code":"OWNER"}` | `[Code] = "OWNER"` |

No persistent table or column is added for this change. Stored EntityKey JSON,
EntityRecordID values, UPR IDs, before/after values and retained audit history
remain unchanged. A direct query of AUDIT_LOG.EntityKey or the AuditLog
compatibility view will therefore still show the stored JSON. Use the audit
report for the readable presentation.

The one new report parameter is `@RawRecordKey BIT = 0`, appended after the
existing parameters. Set it to 1 for the previous raw key presentation. Report
column names/order remain the same. Consumers that parse RecordKey as JSON
should opt into this raw mode.

Historical keys keep their original column names, including AncestorUPRID in
older events. Unknown legacy text, arrays, empty JSON objects and nested key
structures are shown unchanged rather than guessed. Text values are quoted and
escaped. Readable formatting needs compatibility level 130+; older compatibility
levels retain raw keys and print an explanation. The normal installer already
requires compatibility 130+ for the current audit migration.

## Apply and inspect

For an already installed September 23 audit schema, set the database name and
run the updated `scripts/list_upr_audit.sql`. This replaces the report procedure
and opens the latest-run report. It does not rerun the loader or audit migration.
If auditing is not yet installed, follow the existing installation guide first.

```sql
-- Readable record keys; default latest-run summary has no field expansion.
EXEC dbo.usp_UPR_AuditReport @LatestRun = 1, @IncludeFieldDetails = 0;

-- Include per-field changes for a selected table.
EXEC dbo.usp_UPR_AuditReport @TableName = N'UPR_CLOSURE', @IncludeFieldDetails = 1;

-- Preserve the previous JSON presentation for technical/export consumers.
EXEC dbo.usp_UPR_AuditReport @TableName = N'UPR_CLOSURE', @RawRecordKey = 1;
```

`test/check_audit_runs.py` now checks readable/raw modes in both result sets,
single/composite/text keys, escaping, historical names, legacy fallbacks, and
unchanged stored keys/IDs/row snapshots. These database assertions are prepared
but **have not run against SQL Server here**. T-SQL parsing includes the report
and both embedded dynamic SQL batches; parsing does not replace server execution.

## Explicit inventory of the separate search additions

See [the search guide](CLIENT_SEARCH_UPDATE_2026-09-24.md) for behavior, examples,
installation order and unresolved client acceptance decisions.

| Script/object | Change and purpose |
|---|---|
| search_upr_master.sql / usp_UPR_Search | Existing procedure extended; REPORT stays the default, with new GRID/JSON modes for bounded Portal results. |
| search_upr_master.sql / usp_UPR_Property360 | New procedure to retrieve the selected UPR and requested authorized context. |
| search_upr_master.sql / fn_UPR_SearchText | New comparison helper for consistent name/address text normalization. |
| search_upr_master.sql / fn_UPR_SearchSimilarity | New bounded fuzzy-address similarity helper; scores are not identity confidence. |
| load_upr_master.sql / fn_UPR_NormalizeSDATAccount | Existing helper corrected to retain long numeric accounts and normalize numeric formatting. Existing affected mappings require reconciliation. |
| load_upr_master.sql / EXTERNAL_IDENTIFIER_XREF | Adds PARCEL_ID records with source provenance on the source target and parent; no new identifier table. |
| list_upr_hierarchy.sql | Account filtering follows the corrected normalization rule. |

New usp_UPR_Search parameters are grouped here so additions are visible:

| Purpose | Appended parameters |
|---|---|
| Explicit identity and Unit inputs | UPRID, IdentifierType, IdentifierValue, UnitNumber, BuildingUPRID |
| Address/owner scope | Address, State, AddressRole, OwnerRole |
| Matching rules | MatchMode, EnableFuzzy, MinScore, FuzzyCandidateLimit, NormalizeParcel |
| Result format and paging | ResultMode, PageNumber, PageSize |
| Trusted API permissions | AuthorizedUPRIDs, IncludeContacts, IncludeIdentifiers |
| Service/test result capture | ResponseJson OUTPUT, EmitResult |

The new Property360 procedure takes UPRID, Expand, AuthorizedUPRIDs,
IncludeContacts, IncludeIdentifiers, MaxNodes, ResponseJson OUTPUT and EmitResult.
These authorization parameters must be derived by trusted API code, not accepted
as user-granted access. SQL helpers do not implement the Housing Portal itself.

The existing delivery ZIP contains both updates and their guides. Its filename
remains `UPR_Corrections_2026-09-23_Review_Update.zip`; the refreshed manifest
identifies this September 24 revision. Both updates remain candidates for a
restored test database, pending actual SQL Server integration execution.

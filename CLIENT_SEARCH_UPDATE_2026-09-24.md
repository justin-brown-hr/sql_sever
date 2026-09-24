# UPR search update — September 24, 2026

The same package also includes the [EntityKey explanation and audit report update](CLIENT_AUDIT_KEY_UPDATE_2026-09-24.md), which addresses feedback on the previous delivery.

The existing `scripts/search_upr_master.sql` now installs the updated
`dbo.usp_UPR_Search` and a new `dbo.usp_UPR_Property360` detail procedure. The
September 23 hierarchy, closure column names, Condo migration and audit contract
remain in place. This is a **SQL test candidate**, not a deployed Housing Portal
API or a database-validated release.

## What changed

- Added exact UPRID and source/type/value external identifier lookup. External
  identifiers never fall back to interpreting their value as a UPRID.
- Added contextual UnitNumber lookup by Building UPRID, address, or account.
  Account + Unit can resolve through an authorized ancestor. The Unit's linked
  Building and its authoritative immediate parent are returned separately.
- Address matching now searches all current direct address links, including
  secondary addresses, before selecting a display address. The loader already
  shares Building addresses with parents and Units.
- Added normalized exact, partial and bounded fuzzy address matching with
  `matchType` and `matchScore`. Fuzzy matches are candidates for user selection.
- Owner matching uses current contact relationships with role `OWNER` by default,
  searches personal/organization names, and returns contact/role evidence when
  the API enables contact disclosure. Equal names do not establish identity.
- Added paginated GRID and JSON search modes with total counts. Administrative
  XREF/hierarchy outputs now derive from the same matched UPR set. Ordinary report
  review rows are limited to matched UPRs; use `@IncludeReviewQOnly=1` to inspect
  unlinked/rejected records.
- Added selected-UPRID Property 360 with expansion modes and separate permission
  controls for contacts and external identifiers.
- Corrected numeric account normalization: spaces/hyphens are removed, short
  numeric MA/SDAT accounts are padded to eight digits, and longer values retain
  every digit. Alphanumeric identifiers retain their internal punctuation.
- Added source-qualified `PARCEL_ID` links on the source's target UPR and parent
  group. Missing parcels still do not cause rejection. An unchanged load does
  not reinsert the same links.

The original search parameters remain in their original order. New parameters
are appended. REPORT remains the default and retains its result column order;
matching/filter correctness changes mean row contents can differ from the old
report. Portal callers should explicitly choose JSON or GRID.

## Installation and existing-data handling

Use a restored test database first and select its name in each script's `USE`
statement. The files in this update do not reset tables.

1. Run the current `scripts/install_upr_audit.sql` if the September 23 schema/audit
   update has not already been installed successfully.
2. Run the updated `scripts/load_upr_master.sql`. This installs the corrected
   normalization function and populates parcel links for the incoming rows.
3. Run `scripts/search_upr_master.sql` to install both query procedures and their
   comparison helpers. Reinstalling this script does not load or modify UPR data.
4. Use the updated `scripts/list_upr_hierarchy.sql` for consistent account filters.
5. Run the normal validation/audit reports and the new search tests in a
   disposable database. Save first-load and unchanged-rerun results.

If existing source-linked ancestors contain a formerly truncated or newly
normalized formatted account, the loader stops with a reconciliation error.
Do not delete source links or change IDs to bypass this check. Compare raw source
accounts, root accounts and account XREFs; resolve collisions before updating the
stored mapping. This release does not guess a data migration for those cases.
The guard covers current incoming source links; it is not a complete inventory
of historical data absent from the current input.

Raw account formatting remains in the incoming source tables, linked through
SOURCE_RECORD_ID. Search JSON displays the stored account and matching XREF
values; it does not promise an archival copy of every original source field.

The existing delivery ZIP is refreshed in place:
`UPR_Corrections_2026-09-23_Review_Update.zip`. Its filename is retained for
continuity; the September 24 guide and SHA-256 manifest identify the new contents.
Replace the extracted set together. Earlier packages/test results do not validate
this revision.

## Search contract

All supplied search criteria are combined with AND. Multiple candidates are
retained; one account/parcel/owner may resolve to multiple UPRs. Results are
ordered by match class, descending similarity, then UPRID.

| Input | Parameters |
|---|---|
| UPRID | `@UPRID` — exact only |
| External ID | `@IdentifierValue`, optional `@SourceSystem`, `@IdentifierType` |
| Account | `@AccountNumber`, optional source |
| Parcel | `@ParcelID`, optional source; `@NormalizeParcel=1` explicitly enables space/hyphen removal and requires a source |
| Address | `@Address` or legacy `@NormalizedAddress`; optional structured street/city/state/ZIP/role filters |
| Owner | `@OwnerName`, optional `@OwnerRole` (default OWNER) |
| Unit | `@UnitNumber` plus `@BuildingUPRID`, account, address, or exact UPRID context |

`SDAT` maps to stored source `KDAT`; identifier aliases `ACCOUNT` and `PARCEL`
map to `ACCOUNT_NUMBER` and `PARCEL_ID`. These aliases do not rename persisted
values. Explicit external identifier value matching is exact; use AccountNumber
or ParcelID inputs for their respective normalization rules.

`@ResultMode='JSON'` returns one ResponseJson column with searchId, totalResults,
pageNumber, pageSize and results. Each result contains UPR identity, entity type,
match metadata, display address and applicable parent/unit context. Matched
contact and identifier arrays are included only when disclosure is enabled.
`GRID` returns metadata followed by the page of lightweight rows. Empty pages
still retain totalResults. Defaults are page 1 / 50 rows, maximum 200 per page.
`@ResponseJson OUTPUT, @EmitResult=0` supports service/test callers without a
printed result set. REPORT's existing `@MaxRows` parameter does not control Portal
pagination.

Matching defaults: AUTO includes exact/normalized and partial results, and tries
fuzzy address matching only when those stages produce no address matches within
the eligible candidate set. EXACT disables partial/fuzzy, PARTIAL allows exact
and partial, and FUZZY permits the same staged fallback as AUTO. Set
`@EnableFuzzy=0` to disable the final stage. Default fuzzy minimum score is 0.80;
the default pool cap is 500 distinct addresses (maximum configurable cap 1,000).
Scores are normalized Levenshtein similarity, not probability of identity.

Fuzzy matching preserves an entered house number and structured city/state/ZIP
filters. With no house number it requires city, ZIP, account or building context.
An excessive pool produces an error asking for more context rather than silently
truncating candidates. Address/StreetName/OwnerName inputs in Portal mode require
at least three characters. Empty Portal searches and unit-number-only requests
are rejected. The three-character owner rule and matching defaults are initial
implementation choices for client acceptance; fuzzy owners and partial accounts
are not implemented.

## Authorization and API integration

JSON/GRID and Property360 require `@AuthorizedUPRIDs`, a JSON integer array such
as `[10025,10026]`, produced by the **trusted API's authorization logic**. An empty
array permits no UPRs. Invalid or absent arrays produce errors rather than an
unrestricted Portal query. Counts and expansions use this scope. Parent/Building
IDs outside the scope are suppressed.

Contact and identifier sections default off. The trusted API sets
`@IncludeContacts=1` and/or `@IncludeIdentifiers=1` only if permitted for the caller.
Owner search requires contact disclosure; parcel/external-ID search requires
identifier disclosure. These flags apply uniformly to the provided scope. If
permissions differ by node or individual field, the API must partition/filter
requests accordingly; the procedures do not model such finer permissions.

The API must not accept the allowlist, disclosure flags, REPORT mode or arbitrary
SQL parameters directly from HTTP callers. Restrict direct database access to
trusted service/admin principals. These procedures do not authenticate users,
create database grants, implement row-level security, or replace the Portal's
permission model. Keep REPORT accessible only to authorized administrative code.

The Housing Portal endpoint implementation is outside this SQL repository.
Validate lengths before binding SQL parameters. Translate SQL 50001 to a request
validation error and 50004 to the same not-found response for nonexistent and
inaccessible UPRs. Do not automatically associate a user with a fuzzy candidate.

## Property 360

| `@Expand` | Scope |
|---|---|
| none | Selected UPR only |
| parent | Selected UPR and immediate parent |
| parents | Selected UPR and all ancestors |
| children | Selected UPR and immediate children |
| descendants | Selected UPR and entire subtree |
| 360 | Selected UPR, ancestors and its own descendants, plus authorized context |

Combine parent/parents/children/descendants with commas. `none` and `360` stand
alone. The selected UPR is never replaced by its root. `360` on a Unit does not
include siblings or its ancestors' other subtrees. The selected Unit's authorized
linked Building is included as related entity context even when it is not an
ancestor; this does not add a hierarchy edge. The hierarchy children array
contains immediate children or all descendants according to the mode. Closure
self-links are excluded; rootLevel retains the established Level meaning and is
not an ancestor-pair distance.

360 returns addresses, properties, complexes, buildings, units, condos and ADUs
for the authorized scope, with contacts/identifiers when enabled. Contacts and
address relationships are current as of UTC date (inclusive start/end dates).
A Condo Unit can have a Condo immediate parent and a separate linked Building;
the queries preserve that distinction. Root/ancestor arrays follow ParentUPRID's
closure model, not the separate Building link.

Default maximum expanded nodes is 2,000, configurable to 10,000. Exceeding the
limit produces an error; results are not silently cut off. This is a node cap,
not a byte or association-count cap; API response-size/time limits and production
performance tuning are still required.

Closure is refreshed by the loader. External/manual parent changes must refresh
closure before these queries are used; this update adds no hierarchy-write path.

## Validation and remaining acceptance work

Completed locally: existing static hierarchy/schema checks, runner-mode tests,
Python/shell syntax, whitespace checks, and SQLFluff T-SQL parsing of changed SQL.
These checks do not compile/bind SQL against a server or execute the procedures.

Prepared database tests:

- `test/local_it_search_v2.sql`: exact/unknown UPRID, account preservation,
  cross-source ambiguity, negative parcel lookup, secondary-address matching,
  fuzzy typos/house-number protection, owner roles, contextual Units, pagination,
  empty authorization scopes and all expansion modes.
- `test/check_search_load.py`: source parcel links, separate long/short accounts,
  unchanged reruns and the existing-account reconciliation guard.
- Existing listing tests now assert preservation rather than truncation of long
  accounts. September 23 parcel regressions inspect actual candidate JSON and
  include negative cases rather than searching all report text for an account.

The integration runner includes these checks. Execute
`CONTAINER=<disposable-server-container> bash test/run_local_it.sh` when SQL Server
is available. **No SQL Server execution of this update has occurred here.**

Confirm with the client/API team: account/source conventions; permitted address
and contact roles; the scope of 360 for Units; permission mappings; ranking and
performance targets. Retained legacy Property/Condo parcel fallback has no
reliable source qualifier and is therefore used only for unscoped exact parcel
search. New source-qualified parcel links are populated from current incoming
rows. Existing XREFs are retained; retiring changed/historical parcel identifiers
requires an agreed lifecycle policy. No new broad indexes were added without
query-plan evidence; existing indexes cover the initial exact lookup paths.

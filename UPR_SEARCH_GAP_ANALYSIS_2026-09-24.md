# UPR search specification: project gap analysis

> Baseline review before implementation. Subsequent changes and validation limits
> are recorded in [the September 24 update](CLIENT_SEARCH_UPDATE_2026-09-24.md).

Reviewed September 24, 2026 against `UPR_SearchSpecificationv2.docx`
(UPR-SEARCH-002) and repository baseline `c304dce`.

## Conclusion

The existing database is a useful foundation for this specification. It already
has authoritative UPR IDs, entity tables, addresses, contacts, external source
links, parent relationships and closure paths. The current search procedure is
an administrative SQL report, however; it does not implement the proposed Portal
search service or Property 360 contract. No Housing Portal/API application code
is present in this repository. An API elsewhere has not been inspected.

The next scope is search/query development, some identifier and normalization
work, and integration with the Housing Portal API. It does not require replacing
the existing model. The document's sample SQL and suggested indexes need adapting
to the current schema; they are not ready-to-run migration instructions.

This is a source review, not a database execution or implementation. Only this
analysis document was added. No SQL scripts or delivery package were changed.

## Previous-session context used

Read `SESSION_HANDOVER.md`, `CLIENT_UPDATE_2026-09-23.md`,
`CLIENT_REVIEW_FEEDBACK_2026-09-23.md`, the historical September 16 correction and
review notes, and the current SQL and tests. These are saved project context,
not a complete transcript of the previous conversation.

The September 23 continuation takes precedence over older handover sections:

- Closure's ancestor column is now `UPRAncestry`; `[Level]` remains the
  descendant's depth from the root.
- `CONDO.CondoName` and `CONDO.Parcel` were removed. Retained Condo parcels are
  available through `UPR_CONDO_LEGACY` or loader status history.
- Preserve MA-first classification, both MA/SDAT source links, guarded duplicate
  repairs, existing IDs and audit history. Missing parcels alone are allowed.
- Unit numbers are meaningful within their Building. Blank-unit conventions
  (`N/A` or NULL) are not reliable identifiers for a unique Unit.
- The latest migration/loader candidate has recorded static checks, but its SQL
  integration execution is still pending according to the current handover.
  Earlier integration passes do not validate that candidate or this new spec.

## Requirements compared with current code

| Capability | Current evidence | Changes needed |
|---|---|---|
| UPRID exact lookup | `UPR.UPRID` is the primary key, but `usp_UPR_Search` has no `@UPRID` input. | Add an explicit exact-only lookup. Never interpret an account, parcel or external ID as a UPRID automatically. |
| External ID lookup | `EXTERNAL_IDENTIFIER_XREF` stores source/type/value/UPRID. Search only accepts a source filter; it cannot accept an identifier type and value. | Add exact value lookup with optional source/type scope; return the actual matched source, type and value for every candidate. |
| Account search | Search normalizes input and compares `UPR.AccountNumber`. Loader also writes `ACCOUNT_NUMBER` XREF rows. | Correct length handling; define source-specific formatting normalization, source provenance and original-value retention. Support XREF account resolution where needed. Preserve multiple UPR matches. Partial account search is optional in the document. |
| Parcel search | Exact comparison against `PROPERTY.Parcel` and retained Condo parcel. No source-aware parcel XREF population in the loader. | Establish parcel-to-UPR mappings and source-specific normalization; retain provenance and support multiple matches. Address parcels associated with Complex routes, not just Property/Condo rows. |
| Address search | Structured address columns, stored normalization and `UPR_ADDRESS` exist. Search uses equality for some components and substring `LIKE` for others. | Normalize query input consistently; search all eligible address links; add exact, partial and fuzzy stages, ranking, input limits and match metadata. Confirm which address roles and effective dates qualify. |
| Owner search | Substring checks on Property/Condo owner text and `CONTACT.OrganizationName`. Personal-name columns and role links exist. | Search personal and organization names; support exact/normalized/partial matching; select appropriate owner roles and effective dates. Return contact identity, role and associated UPRs. Fuzzy owner matching is optional. |
| Unit search | `UNIT.UnitNumber`, `BuildingID` and unique `UPRID` exist; search displays UnitNumber but has no unit-number input. | Add unit + building/address/account context; return Unit UPRID, linked Building UPRID and applicable Property/Complex ancestor. Distinguish BuildingID from Building UPRID. |
| Lightweight result contract | Procedure returns up to four result sets: UPRs, XREFs, hierarchy and review queue. | Add a dedicated Portal search contract with match type/score, stable entity code/description, display address, matched identifiers, pagination and count semantics. Default hierarchy expansion to none. |
| Property 360 | Supporting tables and a hierarchy listing script exist. There is no selected-UPRID detail procedure or API endpoint in this repository. | Add detail queries and an API response rooted at the selected UPRID, including authorized entity data, addresses, contacts, identifiers and requested hierarchy. |
| Expansion modes | Closure paths and `ParentUPRID` support navigation. Listing script starts from account-filtered roots. | Implement `none`, `parent`, `parents`, `children`, `descendants` and `360`; exclude closure self-links from ancestor/descendant arrays. Specify limits and combined-mode behavior. |
| Authorization | No Portal user/permission model or section-level authorization implementation found here. Audit permission migration is a separate concern. | Integrate the Portal's existing authorization model into search, counts, details and each expansion; agree which contact/identifier fields each caller may see. |
| HTTP integration | Repository contains SQL, shell runners and Python checks, not a web application. | Obtain the Housing Portal API repository/contract and implement request validation, endpoint mapping, errors, serialization and authorized query execution there. |

## Concrete findings to resolve before Portal use

### 1. Numeric account normalization can discard identifying digits

`scripts/load_upr_master.sql:162` defines `fn_UPR_NormalizeSDATAccount`.
For numeric values of 1–12 digits it returns the rightmost eight digits after
padding. `scripts/search_upr_master.sql:47` applies that function to searches.

Consequently the specification's `123456789` example becomes `23456789`.
The formatted value `123-456-789` does not follow that numeric branch, so those
two forms currently do not normalize to the same value. Distinct long accounts
can also collapse to the same eight-digit value. The hierarchy report repeats
this rule locally (`scripts/list_upr_hierarchy.sql:32`).

Confirm valid account lengths per source and fix all affected normalization
paths together. Preserve established eight-digit matching where appropriate.
Assess existing source/account mappings for collisions before changing persisted
values; a search-only correction cannot reconstruct digits already discarded
from destination values. Source rows may be needed for reconciliation. The
current code demonstrates the risk; this review does not establish that actual
client records have been affected.

### 2. Address matching is applied after selecting one display address

`scripts/search_upr_master.sql:110` chooses `TOP 1` address from own,
descendant or ancestor links. Address predicates at line 150 then test only that
chosen address. A root with multiple addresses can therefore fail to appear
when the searched address is not the chosen representative. Searching secondary
or mailing addresses has the same structural problem.

Build candidates from all permitted, relevant address links first, deduplicate
by UPRID, then choose the matched address for display. Separately decide whether
an address match should return its linked node, root, descendants, or several
entity types. Propagating address matches through a tree should be an explicit
rule, not an incidental display fallback.

### 3. Secondary result sets are not restricted to the actual search matches

The XREF query at `scripts/search_upr_master.sql:167` filters by account,
source and entity type but ignores address, owner and parcel predicates.
The hierarchy query at line 187 filters mainly by account/entity type.
The review-queue query at line 207 has another distinct filter set.

For example, an address-only request can return XREF/hierarchy/review rows
unrelated to the matching address. Do not expose these report outputs directly
as Portal search results. A dedicated result set should derive from one candidate
set; detail/expansion queries should derive from the selected, authorized UPRID.

The default cap is 5,000 rows per result set; NULL or nonpositive `@MaxRows`
becomes 2,147,483,647. Empty-input searches are allowed. Define bounded page sizes,
minimum input and stable ordering before using this as an interactive endpoint.

### 4. Owner matching currently ignores person names and relationship roles

`scripts/search_upr_master.sql:141` does not search `CONTACT.FirstName` or
`LastName`, or constrain `UPR_CONTACT.RoleTypeID`. Any matching organization
contact can qualify, irrespective of its role. Contact identity and matched role
are not returned in the UPR result.

The loader currently creates organization contacts from available owner text
(`scripts/load_upr_master.sql:1872`). Adding personal-name search parameters does
not itself populate reliable first/last names or establish that equal names
identify the same person. Clarify source data and avoid inventing parsed identities.

### 5. Existing tests do not establish the new search contract

`test/local_it_search.sql` invokes the report for smoke coverage; it does not
assert candidate correctness, ranking, counts, pagination or authorization.
The September 23 Condo parcel checks search the combined textual procedure
output for an account number (`test/check_sept17_review.py:188` and `:267`).
Because secondary result sets can contain that account independently of the
parcel predicate, these assertions alone do not prove the primary search matched
the requested parcel. Future tests need assertions on the intended result set
and negative cases.

## Schema differences to reconcile, preserving prior decisions

| New document example | Current project | Recommended interpretation |
|---|---|---|
| `EXTERNAL_IDENTIFIER` | `EXTERNAL_IDENTIFIER_XREF` | Reuse the existing table or expose a compatible query/view; no rename is needed merely to match example SQL. |
| `SourceSystem = SDAT`, type `ACCOUNT` | Loader uses `KDAT` for SDAT and type `ACCOUNT_NUMBER`; MA uses `ADDRESS_MASTER`. | Agree public vocabulary and map it explicitly to stored values. Do not silently change existing source keys. |
| `UPR_CLOSURE.AncestorUPRID` | `UPR_CLOSURE.UPRAncestry` | Preserve the September 23 rename; adapt queries or alias in a query/view. |
| Closure `Depth` | `[Level]` is descendant depth from root for every ancestor pair. | Do not relabel Level as pair distance. If Depth means ancestor-to-descendant distance, compute it from valid node levels or add a separately maintained field. Confirm the definition. |
| `AddressLine1Normalized`, `CityNormalized`, etc. | Structured components plus `ADDRESS.NormalizedAddress`; the loader stores its normalized full-address value there. | Define canonical search fields and shared input normalization; names need not match the illustrative schema. |
| `FirstNameNormalized`, `LastNameNormalized` | Raw personal-name columns and OrganizationName. | Add or derive agreed normalized search values after reviewing source completeness and matching rules. |
| `UNIT.CondoUnitNumber` | Incoming CondoUnit is mapped into `UNIT.UnitNumber`. | Reuse UnitNumber unless a distinct business field is explicitly required. |
| Unit → Building → Property illustration | Existing Condo route permits Unit parent = Condo, while `UNIT.BuildingID` links its Building. | Return the linked Building UPRID without misrepresenting it as the immediate parent. Confirm whether the new document actually requests hierarchy restructuring. |

Closure is refreshed during the loader, not immediately after arbitrary manual
parent edits (`scripts/load_upr_master.sql:2038`). If the Portal or other writers
will modify hierarchy, define a transactional maintenance path so expanded
results do not use stale closure data. Preserve `ParentUPRID` as authoritative.

## Index assessment

The DDL already has parent, entity-type, account and parent/entity indexes on
UPR; address normalization/component indexes; reverse address/contact links;
BuildingID/UnitNumber lookup; unique Unit UPRID; and closure indexes in both
directions. See `ddl/03_new_upr_schema.sql:210`, `:245`, `:363`, `:407`, `:500`
and `:522`.

The existing XREF index on `(SourceSystem, IdentifierType, IdentifierValue,
UPRID)` already has the proposed three-column search prefix (line 433), while
allowing that identifier combination to resolve to several UPRs. A separate
filtered index enforces unique source-record mapping only. Do not add an
unconditional global identifier uniqueness constraint.

Review query plans after the candidate queries are defined. In particular,
identifier searches without source/type, normalized owner searches, and fuzzy
address matching require assessment. Some proposed indexes duplicate existing
coverage; suggested closure indexes refer to nonexistent Depth/AncestorUPRID
columns. The spec's full-text/trigram wording is an architectural option, not
proof that the target SQL Server version provides the desired fuzzy behavior.
Choose a matching strategy against the confirmed runtime and representative data.

DDL describes the repository model, not necessarily installed client indexes.
Inventory the actual target database before preparing a migration.

## Suggested implementation sequence

1. **Agree the contract and mappings.** Confirm API ownership, source/type names,
   account formats, returned entity scope, authorization, expansion semantics,
   performance targets and required first-release matching stages.
2. **Prepare identifier/normalization changes.** Correct account handling with
   an existing-data assessment; define parcel ingestion/backfill and provenance;
   share normalization between loading and querying. Use additive, targeted
   upgrades for an existing database, not the destructive DDL setup script.
3. **Add a dedicated search query contract.** Recommended: a new Portal procedure
   alongside the administrative report. Implement all seven inputs, explicit
   match metadata, all-address candidate lookup, owner-role filtering, contextual
   units, stable paging and bounded inputs. Keep admin review data in admin reports.
4. **Add selected-UPRID detail and expansion queries.** Assemble Property 360
   from the existing tables and define limits for large trees. Include Complex
   data in the contract even though the example JSON omits a complexes array.
5. **Integrate the Housing Portal API.** Apply caller permissions before exposing
   rows/counts/sections, and publish request/response and error contracts.
6. **Implement and tune fuzzy address ranking.** The document requests fuzzy
   addresses; this work remains in scope unless the client approves phasing it.
   Treat scores as documented similarity values, not identity certainty. Fuzzy
   owner and partial account matching are optional proposals.
7. **Validate on a disposable SQL Server and restored client data.** Run the
   pending September 23 integration suite as a baseline, then the new behavioral
   search/detail tests and realistic performance measurements.

Essential new cases: unknown exact UPRID; long/formatted accounts and collisions;
identical external values across sources/types; multiple UPRs for one account or
parcel; a root's second address; punctuation and misspellings; same-name contacts
and non-owner roles; duplicate unit numbers across buildings; blank unit values;
Condo units whose Building is linked rather than parent; every expansion mode,
self-link exclusion and changed hierarchy; stable deduplicated pages; empty and
overbroad requests; and restricted rows/fields excluded from counts and responses.

## Decisions to take back to the client/API team

1. Is this delivery SQL support only, or does it include Housing Portal endpoint
   and screen development? Where is that application's code and permission model?
2. Which account lengths and formatting rules apply to each source? Are SDAT and
   KDAT public/internal names for the same source, and ACCOUNT/ACCOUNT_NUMBER
   aliases for the same identifier type?
3. Should address/account/owner results show all matching entity types or favor
   Property/Complex roots? What should multiple supplied search inputs mean?
4. For a selected Unit, does `360` include only its ancestors and own descendants,
   or the entire ancestor-rooted property tree including siblings? What does
   Depth mean, and does the existing Condo parent structure remain valid?
5. Which address/contact roles, historical relationships and inactive entities
   qualify, and what can each Portal user see?
6. Which fuzzy features are needed at launch, and what are the result limits,
   minimum input, latency targets, ranking rules and acceptance examples?

The specification's nine-digit account example is illustrative; it does not
establish the client's actual account inventory. Likewise, its approximate JSON
and recommended index statements should inform the contract without silently
overriding prior schema decisions.

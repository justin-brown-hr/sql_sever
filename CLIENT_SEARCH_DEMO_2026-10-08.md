# Search and Property 360 demo — October 8, 2026

Send **demo_upr_property360_2026-10-08.sql** from
**UPR_Search_Property360_Demo_2026-10-08.zip**. The ZIP contains only this SQL file.
Its source is `scripts/demo_upr_property360.sql`.

This implements the flow in the supplied **Search Example.docx**, including its
three diagrams: search by a known identifier, display each matching UPRID/entity
type, select the desired UPRID, then show the whole property's context. The sample
address and IDs in the document are examples, not records inserted by this script.

## Run the demo

1. Open the SQL file in SSMS and select the intended test database in the database
   dropdown. The file intentionally has no hard-coded database name.
2. Set the controls near the top and execute the **entire file**. Start with
   `@Mode='SEARCH'`, `@SearchBy='ADDRESS'`, and a real `@SearchValue`.
3. Search results explicitly show UPRID, entity type, entity name/label, address,
   address role, account, parent UPRID and status. Several records may legitimately
   share an address. Select the correct UPRID; the script never selects the first
   result automatically.
4. Set `@Mode='360'` and `@SelectedUPRID` to that UPRID. Execute the whole file again.
   `@SearchBy` and `@SearchValue` are ignored in this mode.
5. For external identifiers, first use `@Mode='SOURCES'`. Copy the recorded
   SourceSystem and IdentifierType pair confirmed for that business category into
   the controls, then run the appropriate search. Source names are not guessed.

No installation, load, schema recreation, audit installer, new procedure or
permanent table is needed. Use an authorized staff database account with SELECT
access to the UPR model. This SSMS demo is not an API endpoint; it does not replace
or weaken the existing API's per-record authorization. Contact information is
included for authorized staff. Run against stable demo data, without a concurrent
loader changing the hierarchy.

## Search controls

| SearchBy | SearchValue | Behavior |
|---|---|---|
| ADDRESS | Address text | Normalizes case, spaces, punctuation and common street tokens; literal substring match. No fuzzy identity inference. |
| ACCOUNT | Account number | Exact original value or numeric short account padded to eight digits; also checks ACCOUNT_NUMBER links. Long identifiers are preserved. |
| PARCEL | Parcel identifier | Exact PROPERTY.Parcel or recorded PARCEL/PARCEL_ID identifier. Punctuation is preserved. |
| OWNER | Owner name | Literal substring in PROPERTY/CONDO owner names or active contacts with the OWNER role and a current association. |
| UNIT | Unit number | Exact UNIT.UnitNumber; optional BuildingUPRID disambiguates identical numbers in different buildings. |
| UPRID | Numeric UPRID | Exact master identifier. |
| MPDU | External identifier, or NULL | Exact source/type/value link; NULL lists UPRs with any link for the chosen confirmed source/type. |
| MULTIFAMILY_LOANS | External identifier, or NULL | Same link behavior; loan amount, enrollment and current program status are unavailable. |
| CASE | Case identifier | Exact source/type/value link only. |
| LICENSE | License identifier | Exact source/type/value link only. |
| EXTERNAL | Other external identifier | Exact source/type/value link only. |

MPDU, MULTIFAMILY_LOANS, CASE, LICENSE and EXTERNAL require **both** SourceSystem
and IdentifierType. If their mapping is absent, the result explicitly says that
links are not loaded; it does not claim the source system has no records.
Choose the meaning of the pair from the source-system owner, not its spelling.

Optional EntityType and AddressRole filters use recorded reference values shown
by SOURCES. PHYSICAL addresses are preferred for display when available. Address
searches match only current associations (dates compared with AsOfDate, defaulting
to the database server date). The 360 location/contact grids also show ended and
future associations, explicitly labeled. UPR statuses are not filtered away.
Search results remain one row per UPR even when several links match.

Search displays at most MaxMatches (default 200) and reports the full match count;
refine the search if it exceeds the limit. The 360 tree stops with a clear error
if it exceeds MaxContextNodes (default 5,000), rather than returning a partial tree.
Status history shows the most recent MaxHistoryRows (default 500), with the total
available count and an explicit limit notice. These limits do not establish
performance at 200,000 records; no SQL Server benchmark has run here.

## Property 360 output

The numbered, readable result grids show:

1. Selected identity and its property-context root UPRID.
2. Full hierarchy with entity type, name/label, account, property type, parcel,
   unit number, building year, UPR/entity statuses and created/updated dates.
3. Addresses, roles, coordinates as stored, and association dates/status.
4. Recorded owners and contacts with roles and association dates/status.
5. External identifier links with their exact source and type.
6. Regulatory detail availability.
7. DHCA program detail availability.
8. Loaded status changes, including source, reason, user and timestamp.

Starting at a unit walks ParentUPRID upward to the root, then includes every
branch below that root, including sibling buildings and units. The selected unit
remains labeled. For the supplied example, unit 207075 stays the selection while
24 is the context root. RootLevel is 0 for the root, 1 for its children and 2 for
grandchildren. AncestorDistanceFromSelected is separately 0 for the selection,
1 for its parent and 2 for its grandparent. No column or value in UPR_CLOSURE is
changed. Missing parents, cycles and depth limits stop the output.

As explicitly agreed, licenses, inspections, cases, MPDU and Multifamily Loan
**details are unavailable** until their actual source schemas/queries are supplied.
Their loaded external identifiers can resolve to UPRs, but links alone do not prove
program participation, licensing validity, inspection outcomes or open/closed/
pending statuses. Those values are never fabricated. The regulatory/program grids
state this limitation. No historical audit payloads are displayed or rewritten.

## Verification and scope

- Microsoft ScriptDom parsed the outer script and the actual fixed dynamic query
  batch with zero syntax errors.
- All 16 referenced UPR/reference tables and required columns match the supplied
  project DDL. Runtime metadata checks occur before the query batch is compiled;
  missing columns produce a diagnostic instead of querying invented objects.
- Actual search predicates were exercised locally against duplicate-address,
  owner-role/date, account, parcel, repeated unit number and external-source
  collision fixtures. Address normalization and association filters were checked.
- Actual tree expansion returned the same complete tree from root/building/unit;
  cycle, missing-parent and node-limit fixtures were rejected.
- These relational tests use SQLite and do not reproduce SQL Server permissions,
  collation, execution plans, concurrency or client-specific constraints.

**SQL Server execution remains pending:** no SQL Server runtime/client database
connection is available in this environment. Test this read-only script in the
client's database before the live demo. If the schema diagnostic reports missing
columns, return that result for mapping to the actual layout.

The existing loader, search procedure and API Property360 procedure are unchanged.
This file supplies the requested SSMS demo with readable grids; it does not deploy
an application screen or change API behavior.

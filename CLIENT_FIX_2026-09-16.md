# Optional parcels and supplied hierarchy examples

Package: `UPR_Corrections_2026-09-16_Reviewed.zip`. Replaces the earlier September
16 ZIP after a client-perspective review found a coordinate-pair defect.
Includes the MA-first classification,
existing Condo correction, source-only Unit values, closure Level and row-audit
updates from the earlier deliveries.

## Apply to the existing database

Set each script's `USE` database name, then run:

1. `scripts/install_upr_audit.sql`
2. `scripts/load_upr_master.sql`
3. `test/run_test_and_results.sql`
4. `scripts/list_upr_hierarchy.sql`
5. `scripts/list_upr_audit.sql`

For account `00255115`, also save the results of
`scripts/diagnose_upr_accounts.sql` before and after the load. Compare the actual
source rows and existing roots; do not use the screenshot-subset counts below
as the expected totals for the full database.

The loader prints `Parcel rules: OPTIONAL-PARCEL-2026-09-16` and retains the
`MA-FIRST-2026-09-15` classification marker. The reviewed loader also prints
`Coordinate rules: SOURCE-PAIR-2026-09-16`. All three appear in its audit summary.
No schema rebuild or deletion of incoming data is needed. The package excludes
the destructive schema reset and synthetic test data.

## Missing Parcel numbers

An otherwise valid MA or SDAT record loads normally when its Parcel number is
missing. Blank values, all-zero values and the recognized text placeholders
`NULL`, `N/A`, `NA` and `NONE` normalize to SQL NULL.

Missing Parcel alone creates no `UPRMATCHREVIEW_Q` record during staging or
after loading. No replacement Parcel number is invented. Missing accounts,
invalid required addresses, ambiguous matches and incompatible existing roots
still require review under their actual rejection reasons.

Older `MISSING PARCELID` review entries are retained as history. This update
neither deletes them nor creates additional parcel-only entries on reruns.
The schema retains that historical reason code for compatibility.

To check what this particular load wrote, run the row report with
`EXEC dbo.usp_UPR_AuditReport @LatestRun = 1;` after installing the report in
step 5. The latest load must contain no new Review_Q row whose reason is
`MISSING PARCELID`. An older entry may still have status `PENDING_REVIEW`;
retaining it does not mean the new loader rejected that record again.

## Coordinate correction found during review

The earlier script selected `MAX(XCoordinate)` and `MAX(YCoordinate)` separately.
For the visible 11215 OAK LEAF DR rows, that produced `(1313917, 500144)`, a pair
that appears in no supplied row. The updated script selects both components
from one source record, preferring a complete pair and then the lowest source
ID. A partial pair keeps its missing component NULL. These are representative
address coordinates; individual source-row coordinates remain in MA.

The reviewed loader also repairs an existing pair when it matches the old
calculation, appears in no incoming row for that address and has matching
source-linked ancestry. Ambiguous replacements are skipped. Other existing
coordinate values are retained. Repairs keep the Address and UPR IDs and are
recorded with before/after values in the row report.

## Another_UPR_Illustration.docx

The supplied illustration describes a separate UPR ID for each node, an
immediate parent relationship and ancestor links across the tree. The existing
`UPR.ParentUPRID` and `UPR_CLOSURE` model supports those relationships. The
illustrated Property -> Building -> Condo relationship can retain the child
Condo's own account number (`08123748`) beneath Property account `01231829`.
The hierarchy report shows both the node account and root account.

The regression fixture supplies that nine-node tree explicitly and checks its
five Units, two Buildings, Property and child Condo through closure rebuilding
and unchanged reruns. These are illustration records, not imported MA/SDAT data.
MA and SDAT do not provide the illustrated cross-account parent relationship;
the loader cannot infer it from account numbers alone.

Closure retains all ancestor/descendant pairs and self-links. `Level` remains
the descendant's depth from its root (0, 1, 2, ...), as previously requested.
The loader rebuilds closure after hierarchy changes and checks for cycles;
this delivery does not add immediate closure-maintenance triggers. Explicit
parent edits require a loader run to refresh closure.

## Account 00255115: visible spreadsheet evidence

`Record_Account_00255115_SDAT_MA.docx` contains screenshots rather than an
embedded spreadsheet. The visible MA subset contains:

| Address | Visible source IDs | Visible Units |
|---|---|---|
| 11215 OAK LEAF DR, SILVER SPRING 20901 | 390853-390862 | 101-110 |
| 11235 OAK LEAF DR, SILVER SPRING 20901 | 390353-390355 | 101-103 |

These 13 rows load as one Complex, two Buildings and 13 Units. `255115` and
`00255115` normalize to the same account; repeated Unit numbers remain distinct
across Buildings. Source rows and UPR IDs remain unchanged on rerun. Screenshot
annotations such as "Building B" are not substituted for source Building names.

These are visible-subset totals, not totals for the complete account. SDAT row
22265 shows account `00255115`, Parcel `N390`, YearBuilt `0` and DwellingUnits
`746`, but its full address and CondoUnit are cropped. The test does not invent
those missing fields or use 746 as a Unit number. Exact routing of the complete
SDAT row still requires its uncropped fields.

Both the preceding repository loader and the updated loader classified this
visible MA subset correctly. This evidence alone does not reproduce the
client's original Condo result. `scripts/diagnose_upr_accounts.sql` includes
00255115 and can show the full source rows, existing roots and installed markers.

## Verification

Verified on isolated SQL Server 2022: all 19 integration phases passed,
including 43 hierarchy checks on both loads and 16 client validation checks.
Static hierarchy checks and the schema contract check also passed.

Developer verification from the full repository (these test fixtures are not
included in the client ZIP): run
`CONTAINER=<disposable SQL Server container> bash test/run_local_it.sh` for
the full integration suite, including optional parcels, the illustrated tree,
the visible MA subset, shared-account classification, existing Condo repair,
audit history, closure updates, search and idempotency.

The focused optional-parcel test checks both sources with NULL, blank, zero and
text placeholders, valid Complex overlaps, independent rejection reasons and
historical review retention. An unchanged rerun must add no review entries or
business audit events. Coordinate checks reproduce the failure on the earlier
loader, verify the existing-data correction, check complete/partial/absent
pairs, retain other manually maintained values and verify an unchanged rerun.

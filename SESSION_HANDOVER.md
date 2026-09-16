# UPR session handover - September 16, 2026

This file carries the project context into a new workspace. Read it together
with `CLIENT_FIX_2026-09-16.md` and `CLIENT_REVIEW_2026-09-16.md` before continuing.
It summarizes the work; it is not a transcript or confirmation of production
acceptance. Later instructions from the user take precedence.

## Moving the project

1. Copy the entire SQL project folder to the new workspace, including hidden
   files such as `.git` and `.cursor`, the `docs` directory, and the current ZIP.
2. Keep this file at the project root. Open that copied folder as the workspace.
3. Start the next conversation with the prompt at the end of this file.

Do not rely only on a Git clone: `.gitignore` excludes `docs` and `*.zip`, so
those files need copying separately if you use Git to transfer the source.
This handover file was created after commit `668c736` (`update`); include it
explicitly if it has not been committed when you transfer the repository.

The original workspace was `/home/user/work/SQL`. Paths below are relative so
the new workspace can be anywhere. The two latest client attachments have been
copied into `docs/client_examples/`; the new workspace does not need access to
the old Downloads folder. Their copied bytes were verified against the originals.

## Task and current status

This is a SQL Server project loading MasterAddress (MA) and SDAT into the
hierarchical UPR model. The user asked to continue work from a stopped Claude
session, apply successive client corrections, verify the results, prepare
client messages and delivery files, and review the work from the client's view.

The reviewed scripts are implemented and tested locally. The latest delivery
is `UPR_Corrections_2026-09-16_Reviewed.zip`, containing eight files:

- `scripts/install_upr_audit.sql`
- `scripts/load_upr_master.sql`
- `scripts/list_upr_audit.sql`
- `scripts/diagnose_upr_accounts.sql`
- `scripts/list_upr_hierarchy.sql`
- `test/run_test_and_results.sql`
- `CLIENT_FIX_2026-09-16.md`
- `CLIENT_REVIEW_2026-09-16.md`

The user asked to remove old files. Seven superseded delivery ZIPs and four
dated correction guides were removed; old guides were also removed from the
current ZIP. Documentation links now point to the current guide. Keep that
cleanup: do not recreate the superseded deliveries. Source, tests and reference
documents remain. This handover is for the developer workspace and is not added
to the client ZIP.

The package is ready for the client's database checks, not unconditional final
acceptance. No deployment or successful production/client run was established.
Do not claim the original account-classification failure was reproduced from
the screenshots alone.

## Client requirements and implemented behavior

### Shared MA/SDAT accounts

The client reported account `00255115` became a Condo despite MA containing
multiple Multifamily addresses. They asked for MA-aware staging and suggested
MA-first processing with duplicate SDAT exclusion as a fallback.

Implemented strategy: MA determines classification first. A valid MA
MultiFamily/Apartment row plus two or more distinct normalized MA street
addresses establishes one Complex for the account. Valid rows on that account
join the Complex, including mixed MA types and SDAT rows. City/ZIP differences
alone do not establish a multi-address Complex.

For other shared accounts, SDAT inherits a unique matching MA group, preferring
full-address matches, then street-address matches, then an MA Condo group.
Unmatched/ambiguous shared records require review rather than defaulting to
Condo. SDAT-only accounts retain their Condo route.

Overlapping SDAT records are retained, including source links and details; the
blanket-drop fallback was not adopted. An eligible SDAT record without a real
CondoUnit may still create an unnamed Unit under the existing Unit rules.

A single source-linked, unnamed existing Condo root can be corrected to Complex
in place when its structure is compatible. Root, Building and Unit IDs are
preserved; direct Units are reparented to their Buildings. Named Condos,
competing roots and incompatible structures require review; the loader avoids
creating another competing hierarchy for those Complex accounts.

### Missing Parcel numbers

The client's explicit instruction: do not write Review_Q when the only issue
is missing Parcel, including after the record is processed.

Valid MA and SDAT records now load without parcel-only reviews. NULL, blank,
all-zero and recognized text placeholders normalize to NULL. Missing accounts,
invalid required addresses and other actual rejection reasons still require
review. Historical `MISSING PARCELID` entries remain with their existing status;
they are neither deleted nor automatically closed. The reason remains in the
schema for historical compatibility.

### Source values and hierarchy

- Every incoming row needs an account; missing account means Review_Q and no UPR.
- Numeric account formatting merges `255115` and `00255115` as `00255115`.
- Do not invent names, owner values, State, ZIP or Unit numbers from source IDs.
- Real incoming Unit/CondoUnit values are preserved. Eligible blank MA Units
  use `N/A`; eligible blank SDAT Units retain NULL. Do not introduce MA-/SD-ID
  labels. Duplicate real Unit numbers merge only within the same Building.
- Missing source Building and Complex names stay NULL. Screenshot labels such
  as "Building B" and "Building C" are annotations, not source names.
- Addresses live in ADDRESS and UPR_ADDRESS. Required Contact links are present;
  source-less organization names may remain NULL.
- Closure contains every ancestor/descendant path and self-link. `Level` is the
  descendant's depth from its root, matching report LevelNo: 0, 1, 2, etc.
- Closure is refreshed by the loader, including after reparenting. Immediate
  closure-maintenance triggers have not been implemented. Cycles reject the run.

### Row-change reporting

The client wanted database changes visible as rows for each run/update, without
having to understand audit internals. The installer enables triggers on 22 UPR
model/reference tables. Before/after row values, RunID and session are recorded.
UPR_LOAD_RUN retains completed, failed and empty runs. Manual changes outside a
load are also reported. `list_upr_audit.sql` creates `dbo.usp_UPR_AuditReport`,
showing runs, row events and changed fields.

An unchanged rerun records a run and summary but no business changes. Failed
transactions roll back their row events; the failed run metadata remains.
History before audit installation cannot be recovered. Existing audit history
is preserved. Run the loader outside an existing transaction.

### Coordinate defect found during client-perspective review

The earlier script independently used MAX(X) and MAX(Y), combining coordinates
from different source rows. At 11215 OAK LEAF DR this created `(1313917, 500144)`,
which appears in no supplied MA row. The old test checked counts and relationships
but missed this field-level mismatch. The new assertion reproduced the failure.

The reviewed loader selects both components from one source row: prefer a
complete pair, then the lowest source ID. Partial pairs keep a NULL component.
These are representative address coordinates; individual MA coordinates stay
in the source table. Existing coordinates are repaired only for the identifiable
old calculation, with source-linked ancestry and an unambiguous replacement.
Other existing pairs are preserved. IDs and audit history remain intact.

Current loader markers:

- `MA-FIRST-2026-09-15`
- `OPTIONAL-PARCEL-2026-09-16`
- `SOURCE-PAIR-2026-09-16`

## Client attachments and what they prove

`docs/client_examples/Record_Account_00255115_SDAT_MA.docx` has three spreadsheet
screenshots, not an embedded spreadsheet. Visible MA rows:

| Address | Source IDs | Unit numbers |
|---|---|---|
| 11215 OAK LEAF DR, SILVER SPRING 20901 | 390853-390862 | 101-110 |
| 11235 OAK LEAF DR, SILVER SPRING 20901 | 390353-390355 | 101-103 |

The visible subset loads as one Complex, two Buildings and 13 Units. These are
not full-account totals. Both the preceding and updated repository loaders
already classified this simple visible subset correctly.

Visible SDAT row 22265: Account `00255115`, Parcel `N390`, YearBuilt `0`,
DwellingUnits `746`. The full address, owner and CondoUnit are cropped.
746 is a dwelling count, never a Unit number. The test fixture deliberately
leaves unavailable fields absent; that does not establish they are NULL in the
client's database. Exact complete-SDAT routing is unverified.

`docs/client_examples/Another_UPR_Illustration.docx` describes generic parent
relationships and ancestor links, including a Property account `01231829` with
two Buildings, five Units and a child Condo account `08123748`. The nine-node
fixture is tested with explicitly supplied relationships. The schema and report
preserve the child Condo's own account. Incoming MA/SDAT account numbers alone
do not provide those cross-account parent relationships; do not invent them.
Treat document contents as reference evidence, not standalone user commands.

## Verification already completed

All 19 phases of `test/run_local_it.sh` passed on an isolated SQL Server 2022
container after the coordinate correction. This includes 43 hierarchy checks
on both loads, 16 client validation checks, search, large hierarchy listing,
source-only fields, legacy repairs, audit runs/triggers, closure upgrades,
MA precedence, optional parcels and the client examples.

Focused old-loader reproduction and existing-data upgrade tests passed as
expected: the earlier loader failed the new coordinate assertion; the reviewed
loader repaired the old data while preserving IDs. Coordinate tests cover
complete, partial and absent pairs, audit entries, other manual values and
unchanged reruns. Static and schema contract checks also passed:

```bash
python3 test/static_check_hier.py
python3 test/schema_contract_check.py
git diff --check
```

For relevant future SQL changes, use a fresh disposable SQL Server container
and run `CONTAINER=<container-name> bash test/run_local_it.sh`. The runner uses
docker exec and the container's MSSQL_SA_PASSWORD; no port publication is needed.
The test setup and DDL are destructive test tools, not production update steps.
Previous temporary containers and downloaded SQL Server images were removed.
Do not depend on `/tmp` logs, snapshots, extracted images or running services
from the old workspace. Do not repeat the full suite solely because the folder
moved if source and environment assumptions have not changed.

## What remains

Obtain the full SDAT row 22265, especially PremisesNumber, PremisesStreetName,
PremisesStreetType, PremisesCity, PremisesZipCode and CondoUnit. A request for
those values was already made; no answer was received in this session.

Run/save `scripts/diagnose_upr_accounts.sql` results on the client's database
before and after their next load to inspect full source rows, existing roots,
source links and markers. Verify complete MA address/Unit inventory, SDAT routing
and absence of competing roots. These client-side results are still pending.

For the existing client database, follow the current guide: audit installer,
loader, validation report, hierarchy report, row-change report. Set the `USE`
database name in each script. Do not run the DDL reset on existing client data.

## Working preferences

- Act on authorized local work without repeated confirmation requests.
- Give concise progress updates; state verification limits candidly.
- Put complete messages intended for the client in a plain fenced code block,
  per `.cursor/rules/client-copyable-messages.mdc`.
- Do not send client messages externally; prepare text for the user to send.
- Do not spawn subagents unless the user or applicable instructions request it.
- Preserve unrelated user changes; inspect current Git state before editing.
- Keep the single reviewed delivery ZIP current if deliverable scripts change.

## Starter prompt for the new workspace

```text
Continue the UPR SQL project from the previous workspace. First read
SESSION_HANDOVER.md, CLIENT_FIX_2026-09-16.md, CLIENT_REVIEW_2026-09-16.md,
and the applicable repository instructions. Inspect the current Git state.

Treat the handover as saved project context. The reviewed package is
UPR_Corrections_2026-09-16_Reviewed.zip. The local regression suite passed,
but complete client-side verification of account 00255115 is still pending.
Do not recreate deleted old deliveries or reset existing client data.

Briefly confirm the implemented behavior and remaining client-data check,
then continue with my next instruction.
```

# September 10 UPR corrections

Apply these files to the existing hierarchical database. Edit the `USE` line
in each SQL file to select the client's database.

## Files to send and run

1. `scripts/install_upr_audit.sql` - run first. Adds full before/after columns
   to the existing AuditLog and installs auditing on all 22 UPR model/reference
   tables. Existing records and audit history are preserved.
2. `scripts/load_upr_master.sql` - run the whole script against the client's
   existing incoming tables. Includes the targeted legacy repairs below.
3. `test/run_test_and_results.sql` - run after loading; send back the validation
   grid and record counts.
4. `scripts/diagnose_upr_accounts.sql` - read-only source and destination
   evidence for accounts `00089876` and `01297731`. Send back these results to
   confirm the exact client cases.
5. `scripts/list_upr_hierarchy.sql` - optional full Parent/child listing after
   loading, with all root trees included by default.
6. This guide, `CLIENT_FIX_2026-09-10.md`.

The existing `scripts/list_upr_hierarchy.sql` can still be used to view the tree.
For this correction, do not run `ddl/03_new_upr_schema.sql`, `scripts/run_all.sh`,
or any sample-data setup script: those are for a clean rebuild/test environment.
The September 5 ZIP predates these corrections; use the files listed above.
`UPR_Corrections_2026-09-10.zip` contains exactly these six client files, with
their folder paths preserved. It contains no sample-data setup or schema reset.

## What changed

- New UnitNumbers come only from the incoming `CondoUnit` or MA `Unit` field.
  A blank field does not generate an `SD-...` or `MA-...` UnitNumber or a new
  numbered Unit. Parent, Building, Address and Contact records still load.
- Existing generated UnitNumbers such as `SD-7352` are cleared to NULL only
  when the source-record XREF matches and all linked incoming rows confirm
  the absence of a real unit number. UPR/Unit IDs and relationships are kept.
  A real incoming value that looks like `SD-7352` is preserved.
- Missing Building and Complex names remain NULL. The old generated labels
  are cleared for matching load groups. Account numbers are no longer used
  as substitute contact names; unavailable owner details remain NULL.
- All record types with a usable source street number and street name receive
  a Building and Address. Blank street type no longer turns the address into
  NULL. Missing city or ZIP no longer prevents the load. No default `MD` state
  or invented ZIP digits are supplied.
- Parents and Units link directly to the same source Address records used by
  their Buildings. Source Contact records are linked across the hierarchy,
  including when their optional name fields are NULL.
- An existing Building with no Address link is reused when there is exactly
  one candidate Building and one source address under that parent. An existing
  source-identical Address is reused. Ambiguous cases require review of the
  diagnostic results; the loader does not choose between candidate Buildings.
- Existing source Address links without a primary flag are repaired without
  duplicating Buildings. Address reuse also requires matching source coordinates.
- Additional source records for the same numbered Unit reuse its existing UPR
  and receive their own source XREF, rather than creating duplicate Units.
- A MultiFamily account with 2+ distinct addresses (rule 2 Complex) now keeps
  **every** incoming row for that account inside the one Complex, including its
  SDAT / condo-unit rows. Such an account is no longer split into both a Complex
  and a Condo. The SDAT rows become Buildings and Units under the Complex
  (Complex -> Building -> Unit); Units stay parented to their Building.
  Example: account `00272531` -> 1 Complex, one Building per distinct address,
  one Unit per source unit number, no Condo.

## Audit coverage

After installation, each INSERT, UPDATE and DELETE on the 22 UPR model/reference
tables writes its table name, primary key, login, timestamp and complete JSON
before/after values to `dbo.AuditLog`. This includes changes made outside the
loader and the changes performed by the legacy repair. MERGE actions are logged
as their individual operations. Batch summaries remain available separately.

Audit events share the business transaction: a rollback removes its audit events
as well. This records committed data changes, not failed attempts. Incoming
staging tables, AuditLog itself, reads, DDL and TRUNCATE are outside this row-audit
scope. If those events also need recording, configure SQL Server Audit for them.
No historical events are fabricated for changes made before installation.

## Verification

Tested on an isolated SQL Server 2022 instance:

- 33 hierarchy checks passed on both loads; the second load added no business rows.
- All 16 client validation checks passed.
- The hierarchy listing included 50,001 roots and their children.
- Source-only fields, blank street type, partial addresses, direct relationships,
  legacy UnitNumber repairs and missing Address link repairs passed.
- Multirow INSERT/UPDATE/DELETE, mixed-action MERGE, rollback behavior and audit
  installation on all 22 model/reference tables passed.
- An unchanged rerun after repairs produced only a batch summary, with no new
  business-row change events.
- Final review also covered existing non-primary Address links, coordinate
  mismatches, additional source aliases for a Unit, composite audit keys,
  and safe reinstallation of the audit triggers on a populated database.
- Regression added for the `00272531` report: a MultiFamily account with an
  SDAT condo-unit row on a 4th address loads as ONE Complex with 4 Buildings
  and 4 Units, and zero Condo rows. 37 hierarchy checks and 16 validation
  checks pass on both the first and the idempotent second load.

**Existing databases:** the loader never deletes UPR rows. If a prior run
already created a **Condo** parent for an account that rule 2 now treats as a
Complex, that stale Condo (and any Units under it) is not removed automatically.
Use `scripts/diagnose_upr_accounts.sql` to list those rows and retire them under
your review process after the corrected load has built the Complex tree.

The broader regression fixtures are synthetic. The client subsequently supplied
the actual MA row `20977`, account `01297731`: `13414 DOWLAIS DR`, ROCKVILLE,
`20853`, Single Family Detached, with NULL ParcelNumber and Unit. That exact row
is retained in `test/client_20977.sql` and tested separately.

For this row, the prior repository loader creates one Property, Building,
Address and Contact, and no Unit. However, it links the Address only to the
Building, and the Contact only to the Property. A query requiring a direct
Property-to-Address link therefore returns no address. The corrected loader
adds the missing direct links while retaining the existing UPR IDs and single
Address record. A NULL parcel creates a review flag without blocking the load;
the supplied coordinates are preserved and missing names/State remain NULL.

This reproduces a relationship gap in the prior repository version. It does
not prove the client's database used that exact version or has the same state.
If the client's Address row is actually absent, use the diagnostic results to
trace that database's source, destination and review-queue records.

# November 2 R11 — C Number Complex / Building / Unit rule

Send **UPR_Main_Loader_2026-11-02_R11.zip**. It contains one SQL file:
`load_upr_master_2026-11-02_R11.sql` — the complete main loader (R10 included).

## 1. Units missing under Complex Buildings

Cause: SDAT condo records have their own SDAT account numbers. A C Number
(for example `C000062`) exists only in Master Address, so before R11 no SDAT
record could ever join the C Number Complex. Each SDAT condo record became a
separate Condo instead of a Unit under the Complex Building.

R11 applies your proposed rule:

| Level     | Rule in R11 |
|-----------|-------------|
| Complex   | MA records with a C Number in `Account` and a Multi-Family/Apartment LUCategory, grouped by C Number. One street address stays Property → Building, as before. |
| Building  | Each distinct normalized MA street address in that C Number (number + street + type). City/ZIP spelling variants of the same street address are one Building. |
| Condo Unit| SDAT records with a `CondoUnit`, whose account is not in MA, matched to the Building by normalized street address and compatible ZIP. |

A candidate Building is **validated** before any SDAT record is assigned to it.
Validation fails when:

- the MA records at that street address have more than one ZIP code (`ZIP_CONFLICT`);
- another MA account uses the same street address (`SHARED_WITH_OTHER_ACCOUNT`);
- an existing Condo/Property root already holds that C Number (`EXISTING_ROOT_REVIEW`).

When validation fails, or an SDAT record matches more than one Building, the
record is not assigned. It loads exactly as in R10 and is listed in the review
grids. Nothing is merged or deleted on a guess.

An assigned Unit keeps its **own SDAT account number, owner and parcel**. The
Complex never takes a unit owner's name or account. When an MA unit and an SDAT
condo have the same unit number at the same Building, they are one Unit (existing
rule 9). Both source IDs stay linked to it.

## 2. Leading zeros in street numbers

The loader already removed leading zeros on both incoming tables
(`02310` → `2310`), and still does. R11 also removes tab, line-break and
non-breaking-space characters before the leading zeros. Those characters can make
a number look identical on screen but not match. The incoming tables themselves
are not changed. Matching uses the normalized values.

## 3. Ideas for identifying Buildings

The review grids give evidence to set a firm rule:

- **Shared coordinates:** the last grid lists different MA street addresses in one
  C Number with the same X/Y coordinate pair. They may be one physical building
  with several entrance numbers. If you confirm such cases, coordinates can become
  an approved rule for merging those addresses into one Building.
- **SDAT YearBuilt and DwellingUnits:** units of one physical building normally
  share a year built. A DwellingUnits total that differs from the matched unit
  count points to a wrong grouping.
- **A building or structure identifier,** if the county GIS footprint or SDAT
  extract has one, would be the most reliable rule.
- **Unit number formats:** an MA unit `101` and an SDAT condo `0101` are currently
  two Units. Tell us if unit numbers should also drop leading zeros.

## Run steps

1. Open the R11 file. **Edit `USE UPRXDB_TEST;` to your test database.**
2. Run the entire file from the top. The banner must say
   `UPR MAIN LOADER 2026-11-02 R11`.
3. Results tab, after the usual summary:
   - Summary rows 34–40 (`C Number` section) give the counts.
   - **Outcome counts** — Buildings by validation status, SDAT records by outcome.
   - **Candidate Buildings** — every C Number street address with its evidence
     (ZIP count, address variants, coordinate pairs, SDAT units assigned).
   - **SDAT records not assigned** — with the reason.
   - **Shared coordinates** — see section 3.
   Set `@ShowCNumberReview = 0` near the top to hide these grids.
4. Please send screenshots of the outcome grid and a few examples from the
   not-assigned grid. They show which rules hold on real data.

**Important — data loaded by earlier versions.** SDAT condo records that R10 or
earlier already loaded as separate Condos are **not moved** automatically
(outcome `LOADED_ELSEWHERE`). To see the full R11 result, run R11 on a test
database that does not yet hold these records. Moving existing records would be a
separate, audited repair once the rule is confirmed.

## Verification

R11 was run on SQL Server 2022 (Developer, CU27) in a local test container,
using synthetic data in the client table layout. It has not been run on your
database or data:

- C Number fixture: Complex, Buildings and Units as described above. Unit
  account, owner and parcel are on the Unit, and Unit closure level is 2.
  Unvalidated, ambiguous and non-unit records keep the R10 path. The loader's
  audit result check passes, and an unchanged rerun writes no business changes.
- Upgrade from R10: earlier-loaded records are reported `LOADED_ELSEWHERE`. They
  are not moved or duplicated.
- The standard hostile seed (no C Numbers) gives identical hierarchies, links,
  owners, addresses, levels and review rows under R10 and R11.
- 150,000 synthetic rows: R11 load time was in line with R10 (it creates fewer
  separate Condo trees). This is not a 300,000/400,000-row guarantee for your
  server.

R11 also fixes a compile error (Msg 8102) that stopped the loader from starting
when `REF_ENTITY_IDENTIFICATION.EntityID` is an IDENTITY column. Your current
database is not affected, because R10 runs there.

## Questions

1. Is the C Number always the MA `Account` value in `C` + digits form, or is it a
   separate column in your Master Address table?
2. Should Apartment LUCategory count as Multi-Family for this rule? (R11: yes,
   matching the existing Complex rule.)
3. Should a C Number with only one street address be a Complex with one Building,
   or remain Property → Building as today? (R11 keeps Property.)

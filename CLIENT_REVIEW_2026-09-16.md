> Historical delivery notes. For the current schema, migration order and verification status,
> see [September 23 update](CLIENT_UPDATE_2026-09-23.md). Earlier test passes do not validate this update.

# Client acceptance review

Verdict: the corrected package is ready for the client's database checks.
Complete acceptance of the reported account requires the full source rows and
existing destination records; the screenshots cannot establish that result.

## Defect found and corrected

The earlier September 16 loader could combine X from one MA record with Y from
another. This is visible in the client's own account 00255115 at 11215 OAK LEAF
DR: the resulting pair `(1313917, 500144)` is absent from the supplied rows.
The old integration test checked entity counts and relationships but missed
this field-level mismatch. The added check fails on the old loader.

The reviewed loader selects a coordinate pair from one source row and narrowly
repairs previously generated combinations, retaining IDs and audit history.
Use `UPR_Corrections_2026-09-16_Reviewed.zip`, not the earlier September 16 ZIP.

## Acceptance questions

| What the client will check | Evidence and remaining limit |
|---|---|
| Does missing Parcel alone put a record in Review_Q? | No new entries on fresh loads or reruns. Tested for both sources with NULL, blanks, zeros and recognized placeholders. Missing accounts and invalid addresses still need review. |
| Why do old missing-parcel rows still appear? | Historical reviews are retained, including their existing status. Check the current run's row report to distinguish new writes from earlier entries. This update does not close or delete old reviews. |
| Is account 00255115 one Complex? | The 13 visible MA rows produce one Complex, two Buildings and 13 Units. This is a partial-source result. The complete SDAT address and CondoUnit, and the client's existing roots, remain needed to verify the full case. |
| Does this prove why the client got a Condo? | No. Both the preceding and updated repository loaders already classify the simple visible MA subset as a Complex. Synthetic regressions cover related failures and in-place Condo repair, but they do not establish the cause in the client's database. |
| Were all overlapping SDAT rows dropped? | No. MA takes precedence for classification; matching SDAT details and source links are retained. An eligible SDAT record with no CondoUnit can still create an unnamed Unit under the existing Unit rules. The blanket-drop fallback suggested by the client was not adopted. Confirm the full record inventory in the database check. |
| Does every node keep its own ID and parent? | The illustrated nine-node Property/Building/Unit/Condo tree survives closure rebuilding and reruns. The child Condo retains its separate account. The fixture supplies those relationships explicitly; incoming account numbers alone do not identify cross-account parents. |
| Are ancestor links immediately refreshed after a manual edit? | They are refreshed by the loader. Immediate closure-maintenance triggers were suggested in the document but have not been implemented in this delivery. |
| Can the client see each change as a record? | The report shows inserted, updated and deleted rows with their old/new values and load ID. An unchanged run shows zero business changes. History predating audit installation cannot be reconstructed. |
| Can this run against existing data? | The package upgrades auditing and reuses existing IDs. Compatible source-linked Condos are corrected in place; incompatible existing roots are reviewed. No schema reset is included. |

## Final check on the client's data

Follow the script order in `CLIENT_FIX_2026-09-16.md`. Save the account diagnostic
results before and after loading. Confirm the complete MA address/unit inventory
is represented, inspect SDAT row 22265's actual routing and check for competing
roots. Review the latest run's changed rows and genuine rejection reasons.
Do not treat the two-Building/13-Unit screenshot subset as a full-account total.

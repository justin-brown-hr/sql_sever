# UPR full-record listing — October 13, 2026

Send **UPR_Full_Records_2026-10-13.zip** through Freelancer. It contains exactly one file:
`list_upr_full_records_2026-10-13.sql`, identical to `scripts/list_upr_hierarchy.sql`.
This is the full-record listing report, separate from the loader and Property 360 demo.

## Run

1. Open the SQL file in SSMS and select the database containing the loaded UPR records.
   The script retains that database selection and prints its name in Messages.
2. Leave `@FilterAccount = NULL` and `@MaxRows = NULL` to list all UPRs, or set
   `@FilterAccount = N'00118285'` for that account's root trees and children.
3. Execute the entire file. Read the main hierarchy grid in Results; additional
   grids show summary counts, completeness issues and all address/contact links.
   Set `@ShowAllAssociations = 0` to omit the two association grids if needed.

The script reads existing loaded data. It requires no loader rerun, audit installation,
source incoming tables, stored procedures, or new permanent tables. It uses temporary
report tables only. It does not change UPR, closure, audit history or schema, and emits
readable columns without JSON.

## Fields and interpretation

The main grid includes UPRID, parent/root UPRIDs, account number, entity/status,
owner/contact, street and full address, building UPRID/ID/name, unit ID/number,
property/community name, property type, parcel and year built where recorded.

- Child rows use their own account number when present, otherwise the root account.
  `RecordAccountNumber` and `AccountSourceUPRID` distinguish these cases.
- Owner values prefer a direct recorded owner, then the nearest ancestor's owner.
  Only OWNER-role contacts qualify as contact-based owners. The source UPRID and
  inheritance flag are displayed. An inherited owner supplies property context;
  it does not establish legal ownership of an individual unit.
- The main grid selects one current address and owner/contact for each record.
  Other address/contact associations remain visible in the two additional grids,
  including dates and Current/Ended/Future labels. An address fallback identifies
  its source UPRID; a root may display a descendant building's address.
- The supplied schema has `BuildingID` and `BuildingName`, not a separate building
  number. `BuildingNumber` is shown only if that column exists in the database;
  otherwise the report explicitly marks it unavailable. StreetNumber, BuildingID
  and UnitNumber remain separate; no building number is invented.
- `LevelNo` follows actual ParentUPRID links: root 0, child 1, grandchild 2.
  A unit attached directly to a Condo is reported at its actual level and flagged
  for correction; this report does not alter the hierarchy to hide the issue.
- Default all-records mode also includes records without a reachable property root,
  marked unresolved with NULL level/root. Account filters and root caps select only
  matching root trees. A root cap prints a warning; counts and completeness checks
  still cover all records matching the account filter.
- Owner/address inheritance and some checks use the existing UPR_CLOSURE, so that
  table must reflect the loaded ParentUPRID relationships.

## Verification

Microsoft ScriptDom parsed the report and both literal dynamic batches with zero
syntax errors. Offline fixtures executed the actual tree, owner-selection and
address-selection queries with minimal SQLite dialect translations: root/child
levels, account filters, root caps, long IDs, unresolved records, direct/inherited
ownership, role/date exclusions and physical-address fallback passed.

The SQL Server integration test has been updated for the selected database, absent
legacy/ADU tables, inherited accounts and R9 unit-parent rules. It has **not** been
executed here. Client SQL Server schema binding, permissions and performance at
200,000 records remain unverified. Start with one account to confirm the output.

# Review of the client's UPR research

**Superseded conclusion, October 1:** The client has now explicitly confirmed that
stored closure Level must be pair distance and supplied the incorrect raw rows.
The root-depth loader is therefore a confirmed defect under that contract; this
is not an API-only issue. See [the correction](CLIENT_CLOSURE_DISTANCE_FIX_2026-10-01.md).
The review below records the earlier evidence and uncertainty, not current advice
to preserve incorrect values. Table structure remains unchanged.

The distinction between tree Level and HierarchyDistance is sound. The research
supports investigating API query direction and field interpretation first, but
does not establish that the deployed hierarchy data is correct or that the fault
is exclusively in the API.

Reviewed: `Research_What I would change in the UPR specification.docx`, the
provided API screenshots, and the current local SQL scripts. The document is a
proposed specification, not authorization to change the database contract.

## Two different quantities

Using the document's proposed chain 24 → 88788 → 207075:

| Returned UPR | Tree Level from root | HierarchyDistance from selected 207075 |
| --- | ---: | ---: |
| 207075 | 2 | 0 |
| 88788 | 1 | 1 |
| 24 | 0 | 2 |

The deployed ParentUPRID values have not been independently checked. Level 0
means the root; distance 0 means the selected record. The specification should
explicitly state that the ancestor response includes the selected record.

## Evidence in the current scripts

- `scripts/load_upr_master.sql`, Step 12, stores the descendant's absolute root
  depth in `UPR_CLOSURE.Level`, including self-rows. Filtering on one descendant
  repeats its depth for every ancestor. This alone does not demonstrate incorrect
  parent relationships.
- `scripts/list_upr_ancestor_path.sql` displays each ancestor's own root depth by
  joining its self-row. This explains the report/API difference. The report is
  read-only and does not modify the API or implement HierarchyDistance.
- `scripts/search_upr_master.sql`, `usp_UPR_Property360`, expands the selected
  node's ancestors and descendants. From a unit, it does not retrieve every sibling
  branch under the root. Complete-tree behavior requires explicit root resolution
  followed by a root-descendant query, preserving caller access and node limits.
- Search already exposes entity type in GRID/JSON and accepts an address-role
  filter. Whether the deployed API forwards these correctly is unverified. Equal
  addresses across different UPRs do not alone imply duplicate entities.
  Physical-address preference and physical-only filtering are different behaviors.

## The proposed Depth field differs from existing Level

The research defines closure Depth as endpoint-to-endpoint distance, with all
self-rows zero. Existing Level stores descendant root depth. Renaming Level to
Depth or overwriting its values would change the contract for existing consumers.
It is not required to expose a separate HierarchyDistance in the API.

In a valid single-parent tree with verified root-depth self-rows, ancestor distance
equals selected root depth minus ancestor root depth. Alternatively, count edges
while walking ParentUPRID. Self-row subtraction does not work with the proposed
distance-based Depth, whose self-rows would all be zero.

## Separate API direction concern

The screenshot's `/api/upr/24/ancestors` response has ancestorUPRID 24 with
descendantUPRID 24, 88787, 88788, 207074 and 207075. Those pairs describe downward
traversal. This suggests a route naming or query-direction mismatch under the
proposed definitions; implementation is needed to distinguish them. Ancestor
traversal from 207075 selects paths ending at 207075; descendant traversal from
24 selects paths beginning at 24. A root-start query cannot distinguish root
depth from relationship distance, because the two coincide there.

## Additional unit-detail screenshots

The subsequent screenshots show `GET /api/unit/207075` returning HTTP 200 with
a JSON `null` body. This is a different endpoint from
`GET /api/upr/207075/ancestors`; it does not test upward traversal or levels.

The local schema defines separate `dbo.UNIT.UnitID` (identity primary key) and
`dbo.UNIT.UPRID` (unique foreign key). If `/api/unit/{id}` expects UnitID, supplying
the known UPRID 207075 could explain the null. The route parameter's name alone
does not establish which identifier it expects. Missing unit detail, a different
deployed database, filtering or response mapping could also explain the result.

Read-only checks in the same database used by the API:

```sql
SELECT u.UPRID, u.ParentUPRID, un.UnitID
FROM dbo.UPR AS u
LEFT JOIN dbo.UNIT AS un ON un.UPRID = u.UPRID
WHERE u.UPRID = 207075;

SELECT UnitID, UPRID
FROM dbo.UNIT
WHERE UnitID = 207075 OR UPRID = 207075;
```

Check the endpoint's identifier contract before retrying with the returned UnitID.
Also obtain `/api/upr/207075` and `/api/upr/207075/ancestors` responses to isolate
the UPR lookup and hierarchy traversal. A successful HTTP status with a null body
does not establish that a unit was found, or that its hierarchy is wrong.

## Verification before assigning the cause

1. Obtain deployed endpoint queries/procedure calls and response mapping for
   ancestors/parents, property tree and search. API source is absent here.
2. Independently walk ParentUPRID from 207075 and verify the root, links, self-rows
   and all corresponding closure paths in the deployed database.
3. Compare the walk, raw query and actual API response for 207075. Under the
   research's example, distances are 0, 1, 2 and root levels are 2, 1, 0.
4. Request the complete tree from both 24 and 207075 with identical permissions.
   The node sets should match, with only the selected-node marker differing.
5. Verify search entity type, role filters and agreed physical-address preference.

At the time of this review, UPR_CLOSURE was left unchanged pending clarification.
No SQL Server or API execution was performed. The later client clarification
resulted in the October correction linked above. Obsolete exploratory snapshots
were removed during October 2 cleanup; their history remains in Git.

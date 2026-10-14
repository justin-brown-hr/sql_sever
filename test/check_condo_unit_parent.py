#!/usr/bin/env python3
"""R9: execute actual candidate SELECT and mapping in SQLite. Not a SQL Server run."""
from pathlib import Path
import re,sqlite3
root=Path(__file__).resolve().parents[1]
s=(root/'scripts/load_upr_master.sql').read_text()
query=re.search(r'/\* CONDO_UNIT_CANDIDATES_BEGIN \*/(.*?)/\* CONDO_UNIT_CANDIDATES_END \*/',s,re.S)[1]
query=query.replace('INTO #CondoUnitParentRepair','').replace("N'","'").replace('Issue=CASE','CASE').replace('ELSE NULL END','ELSE NULL END AS Issue')
args=dict(EtCondo=1,EtBuilding=2,EtUnit=3)
db=sqlite3.connect(':memory:');db.execute("ATTACH ':memory:' AS dbo")
db.executescript('''CREATE TABLE dbo.UPR(UPRID INTEGER PRIMARY KEY,ParentUPRID INTEGER,EntityTypeID INTEGER,AccountNumber TEXT);
CREATE TABLE dbo.UNIT(UnitID INTEGER PRIMARY KEY,UPRID INTEGER,BuildingID INTEGER,UnitNumber TEXT);
CREATE TABLE dbo.BUILDING(BuildingID INTEGER PRIMARY KEY,UPRID INTEGER);
CREATE TABLE dbo.EXTERNAL_IDENTIFIER_XREF(UPRID INTEGER,SourceSystem TEXT,IdentifierValue TEXT);
CREATE TABLE CondoUnitParentRepair(UnitUPRID INTEGER,OldParentUPRID INTEGER,BuildingID INTEGER,BuildingUPRID INTEGER,BuildingParentUPRID INTEGER,Issue TEXT);
INSERT INTO dbo.UPR VALUES(24,NULL,1,'00118285'),(147901,24,2,NULL),(345168,24,3,NULL),
(25,NULL,1,'OTHER'),(147902,25,2,NULL),(345169,147902,3,NULL),
(26,NULL,4,'COMPLEX'),(147903,26,2,NULL),(345170,147903,3,NULL);
INSERT INTO dbo.BUILDING VALUES(8001,147901),(8002,147902),(8003,147903);
INSERT INTO dbo.UNIT VALUES(9001,345168,8001,NULL),(9002,345169,8002,'101'),(9003,345170,8003,'101');
INSERT INTO dbo.EXTERNAL_IDENTIFIER_XREF VALUES(345168,'KDAT','CLIENT-SOURCE');''')
def candidates():return db.execute(query,args).fetchall()
assert candidates()==[(345168,24,8001,147901,24,None)]
identity_before=(list(db.execute('SELECT * FROM dbo.UNIT')),list(db.execute('SELECT * FROM dbo.EXTERNAL_IDENTIFIER_XREF')))
# Execute the actual UPDATE relationship after removing SQL Server OUTPUT/metadata.
join=re.search(r'UPDATE u SET ParentUPRID=r.BuildingUPRID,UpdatedBy=@RunUser,UpdatedDate=@Now.*?\n(FROM dbo.UPR u JOIN #CondoUnitParentRepair.*?);',s,re.S)[1]
select='SELECT u.UPRID,r.BuildingUPRID '+join.replace('#CondoUnitParentRepair','CondoUnitParentRepair')
def repair():
 rows=candidates();assert not any(r[-1] for r in rows)
 db.execute('DELETE FROM CondoUnitParentRepair');db.executemany('INSERT INTO CondoUnitParentRepair VALUES(?,?,?,?,?,?)',rows)
 changes=db.execute(select).fetchall()
 db.executemany('UPDATE dbo.UPR SET ParentUPRID=? WHERE UPRID=?',[(parent,unit) for unit,parent in changes]);return changes
assert repair()==[(345168,147901)]
assert identity_before==(list(db.execute('SELECT * FROM dbo.UNIT')),list(db.execute('SELECT * FROM dbo.EXTERNAL_IDENTIFIER_XREF')))
assert repair()==[]
# Independently derive expected pair distances for the screenshot after repair.
parents=dict(db.execute('SELECT UPRID,ParentUPRID FROM dbo.UPR'));paths=[];cur=345168;distance=0
while cur is not None:
 paths.append((cur,345168,distance));cur=parents[cur];distance+=1
assert paths==[(345168,345168,0),(147901,345168,1),(24,345168,2)]
print('PASS: screenshot chain repaired via BuildingID; IDs/links preserved; exact distances 0/1/2; second run makes no repair')
# Guard actual candidate CASE for missing link, wrong root/type, nonroot Condo,
# duplicate UNIT records and a Unit with children. No address-based guessing.
def bad(change,expected,undo):
 db.execute('UPDATE dbo.UPR SET ParentUPRID=24 WHERE UPRID=345168');db.executescript(change)
 rows=candidates();assert rows and all(expected in r[-1] for r in rows),(rows,expected)
 db.executescript(undo)
bad('UPDATE dbo.UNIT SET BuildingID=999 WHERE UnitID=9001','no linked','UPDATE dbo.UNIT SET BuildingID=8001 WHERE UnitID=9001;')
bad('UPDATE dbo.UNIT SET BuildingID=8002 WHERE UnitID=9001','same Condo','UPDATE dbo.UNIT SET BuildingID=8001 WHERE UnitID=9001;')
bad('UPDATE dbo.UPR SET EntityTypeID=4 WHERE UPRID=147901','wrong entity','UPDATE dbo.UPR SET EntityTypeID=2 WHERE UPRID=147901;')
bad('UPDATE dbo.UPR SET ParentUPRID=25 WHERE UPRID=24','not a root','UPDATE dbo.UPR SET ParentUPRID=NULL WHERE UPRID=24;')
bad('INSERT INTO dbo.UNIT VALUES(9004,345168,8001,NULL)','exactly one','DELETE FROM dbo.UNIT WHERE UnitID=9004;')
bad('INSERT INTO dbo.UPR VALUES(999,345168,3,NULL)','has children','DELETE FROM dbo.UPR WHERE UPRID=999;')
bad('DELETE FROM dbo.UNIT WHERE UnitID=9001','exactly one','INSERT INTO dbo.UNIT VALUES(9001,345168,8001,NULL);')
print('PASS: missing/ambiguous UNIT, missing/wrong Building, different root, nested Condo and children all produce diagnostic issues')
# Crucial rule for NEW units and duplicate reconciliation, not merely closure.
unit_joined=s.split('UnitJoined AS (',1)[1].split('BuildingTableID =',1)[0]
assert 'ParentUPRID = bm.BuildingUPRID,' in unit_joined and "WHEN ub.PathType = N'CONDO' THEN pm.UPRID" not in s
assert 'sup.ParentUPRID = sb.UPRID' in s and 'mup.ParentUPRID = mb.UPRID' in s
assert s.index('CONDO_UNIT_REPAIR_BEGIN')<s.index('INTO #OverlapRepair')<s.index('UnitJoined AS (')
block=s.split('/* CONDO_UNIT_REPAIR_BEGIN',1)[1].split('/* CONDO_UNIT_REPAIR_END */',1)[0]
assert "OUTPUT N'UPR'" in block and 'deleted.[ParentUPRID]' in block and 'inserted.[ParentUPRID]' in block
assert 'INTO #AuditEvents' in block
assert s.index('BEGIN TRANSACTION;')<s.index('CONDO_UNIT_REPAIR_BEGIN')<s.index('Rebuild UPR_CLOSURE from ParentUPRID')<s.index('COMMIT TRANSACTION;')
print('PASS: new units and duplicate reconciliation use Building parent; existing repair precedes reuse, is audited and shares closure transaction')
# Execute the client checker's actual verdict SELECT against repaired and broken
# fixtures, so a mathematically consistent but wrong parent relationship fails.
repair()
db.executescript('''CREATE TABLE dbo.REF_ENTITYTYPE(EntityTypeID INTEGER,Description TEXT);
INSERT INTO dbo.REF_ENTITYTYPE VALUES(1,'Condo'),(2,'Building'),(3,'Unit'),(4,'Complex');
CREATE TABLE dbo.UPR_CLOSURE(AncestorUPRID INTEGER,DescendantUPRID INTEGER,Level INTEGER);''')
parents=dict(db.execute('SELECT UPRID,ParentUPRID FROM dbo.UPR'))
for unit in parents:
 cur=unit;distance=0
 while cur is not None:
  db.execute('INSERT INTO dbo.UPR_CLOSURE VALUES(?,?,?)',(cur,unit,distance));cur=parents[cur];distance+=1
checker=(root/'scripts/check_upr_unit_hierarchy.sql').read_text()
verify=checker[checker.index('SELECT un.UnitID'):checker.index('SELECT DB_NAME()')]
verify=verify.replace('INTO #UnitHierarchyCheck','').replace("N'","'").replace('Verdict=CASE','CASE').replace("ELSE 'PASS' END", "ELSE 'PASS' END AS Verdict")
assert all(r[-1]=='PASS' for r in db.execute(verify))
db.execute('UPDATE dbo.UPR_CLOSURE SET Level=1 WHERE AncestorUPRID=24 AND DescendantUPRID=345168')
assert any('root-to-Unit distance must be 2' in r[-1] for r in db.execute(verify))
db.execute('UPDATE dbo.UPR SET ParentUPRID=24 WHERE UPRID=345168')
assert any('Unit parent differs' in r[-1] for r in db.execute(verify))
print('PASS: actual client checker detects both wrong parent links and wrong stored distances')

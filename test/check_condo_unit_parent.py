#!/usr/bin/env python3
"""R13: execute the actual direct Condo -> Unit candidate SELECT in SQLite. Not a SQL Server run.

The client layout has no UNIT.BuildingID, so a Unit attached directly to a Condo
cannot be moved to its Building; the loader reports it and stops instead."""
from pathlib import Path
import re,sqlite3
root=Path(__file__).resolve().parents[1]
s=(root/'scripts/load_upr_master.sql').read_text()
block=re.search(r'/\* CONDO_UNIT_REPAIR_BEGIN(.*?)/\* CONDO_UNIT_REPAIR_END \*/',s,re.S)[1]
outer=re.sub(r"N?'(?:[^']|'')*'|/\*.*?\*/",' ',block,flags=re.S)
assert not re.search(r'\b(?:UPDATE|DELETE|MERGE)\b|\bINSERT\s+(?:INTO\s+)?dbo\.',outer,re.I),'repair block must not change data'
assert 'THROW 50008' in block and 'UNIT has no BuildingID' in block
query=re.search(r'/\* CONDO_UNIT_CANDIDATES_BEGIN \*/(.*?)/\* CONDO_UNIT_CANDIDATES_END \*/',s,re.S)[1]
query=query.replace('INTO #CondoUnitParentRepair','').replace("N'","'").replace('Issue=',"'' AS IssueLabel,")
db=sqlite3.connect(':memory:');db.execute("ATTACH ':memory:' AS dbo")
db.executescript('''CREATE TABLE dbo.UPR(UPRID INTEGER PRIMARY KEY,ParentUPRID INTEGER,EntityTypeID INTEGER,AccountNumber TEXT);
INSERT INTO dbo.UPR VALUES(24,NULL,1,'00118285'),(147901,24,2,NULL),(345168,24,3,NULL),
(25,NULL,1,'OTHER'),(147902,25,2,NULL),(345169,147902,3,NULL),
(26,NULL,4,'COMPLEX'),(147903,26,2,NULL),(345170,147903,3,NULL);''')
rows=db.execute(query,dict(EtCondo=1,EtBuilding=2,EtUnit=3)).fetchall()
assert [(r[0],r[1]) for r in rows]==[(345168,24)],rows
print('PASS: only a Unit attached directly to a Condo is reported; Units under Buildings are not')
print('PASS: the repair block changes no data and stops the load with a diagnostic (no Building is guessed)')

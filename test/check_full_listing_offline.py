#!/usr/bin/env python3
"""Actual listing tree/owner/address queries on local fixtures; not SQL Server."""
from pathlib import Path
import re,sqlite3
root=Path(__file__).resolve().parents[1]
s=(root/'scripts/list_upr_hierarchy.sql').read_text()
# SQL string/comment aware outer code: optional objects must be dynamic only.
outer=re.sub(r"N?'(?:[^']|'')*'|/\*.*?\*/|--[^\n]*",' ',s,flags=re.S)
assert not re.search(r'\bUSE\s',outer,re.I)
assert 'UPR_CONDO_LEGACY' not in s
assert 'dbo.ADU' not in outer and 'bn.BuildingNumber' in outer
assert 'FROM #ReportTree t\nINNER JOIN dbo.REF_ENTITYTYPE' in s
assert 'FROM Tree t\n    INNER JOIN dbo.UPR c' in s
assert 'FOR JSON' not in s
assert not re.search(r'\b(?:UPDATE|DELETE|INSERT\s+(?:INTO\s+)?|ALTER\s+TABLE)\s*dbo\.',outer,re.I)
print('PASS: read-only report, selected database retained, missing legacy table removed, optional columns late-bound')
db=sqlite3.connect(':memory:');db.execute("ATTACH ':memory:' AS dbo")
db.create_function('REPLICATE',2,lambda s,n:s*n);db.create_function('RRIGHT',2,lambda s,n:s[-n:]);db.create_function('TEXT',1,str)
db.create_function('CONCAT',-1,lambda *xs: ''.join('' if x is None else str(x) for x in xs))
db.executescript('''
CREATE TABLE dbo.UPR(UPRID INTEGER PRIMARY KEY,ParentUPRID INTEGER,EntityTypeID INTEGER,AccountNumber TEXT,StatusCode TEXT);
CREATE TABLE dbo.REF_ENTITYTYPE(EntityTypeID INTEGER,Description TEXT);
INSERT INTO dbo.REF_ENTITYTYPE VALUES(1,'Condo'),(2,'Building'),(3,'Unit');
INSERT INTO dbo.UPR VALUES(24,NULL,1,'00118285','ACTIVE'),(147901,24,2,NULL,'ACTIVE'),(345168,147901,3,NULL,'ACTIVE'),
 (90,NULL,1,'OTHER','ACTIVE'),(1000000000001,90,2,NULL,'ACTIVE'),(1000000000002,1000000000001,3,NULL,'ACTIVE'),
 (999,998,3,NULL,'ACTIVE');
CREATE TABLE dbo.UPR_CLOSURE(AncestorUPRID INTEGER,DescendantUPRID INTEGER,Level INTEGER);
INSERT INTO dbo.UPR_CLOSURE VALUES(24,24,0),(24,147901,1),(24,345168,2),(147901,147901,0),(147901,345168,1),(345168,345168,0);
CREATE TABLE dbo.PROPERTY(UPRID INTEGER,OwnerName TEXT); CREATE TABLE dbo.CONDO(UPRID INTEGER,OwnerName TEXT);
CREATE TABLE dbo.CONTACT(ContactID INTEGER,FirstName TEXT,LastName TEXT,OrganizationName TEXT,StatusCode TEXT);
CREATE TABLE dbo.UPR_CONTACT(UPRContactID INTEGER,UPRID INTEGER,ContactID INTEGER,RoleTypeID INTEGER,EffectiveDate TEXT,EndDate TEXT);
CREATE TABLE dbo.REF_ROLETYPE(RoleTypeID INTEGER,RoleTypeCode TEXT);
INSERT INTO dbo.REF_ROLETYPE VALUES(1,'OWNER'),(2,'AGENT');
INSERT INTO dbo.CONTACT VALUES(1,'Owner','Person',NULL,'ACTIVE'),(2,'Agent','Person','AgentCo','ACTIVE'),(3,'Old','Owner',NULL,'ACTIVE');
INSERT INTO dbo.UPR_CONTACT VALUES(1,24,1,1,NULL,NULL),(2,345168,2,2,NULL,NULL),(3,345168,3,1,NULL,'2000-01-01');
CREATE TABLE dbo.ADDRESS(AddressID INTEGER,NormalizedAddress TEXT,StreetNumber TEXT,StreetName TEXT,StreetDirection TEXT,StreetType TEXT,StreetSuffix TEXT,City TEXT,State TEXT,ZipCode TEXT);
CREATE TABLE dbo.UPR_ADDRESS(UPRAddressID INTEGER,UPRID INTEGER,AddressID INTEGER,AddressRoleID INTEGER,IsPrimary INTEGER,EffectiveDate TEXT,EndDate TEXT);
CREATE TABLE dbo.REF_ADDRESSROLE(AddressRoleID INTEGER,AddressRoleCode TEXT);
CREATE TABLE dbo.BUILDING(BuildingID INTEGER,UPRID INTEGER,BuildingName TEXT);
INSERT INTO dbo.BUILDING VALUES(8001,147901,'Recorded building');
INSERT INTO dbo.REF_ADDRESSROLE VALUES(1,'PHYSICAL'),(2,'MAILING');
INSERT INTO dbo.ADDRESS VALUES(1,'123 MAIN ST','123','MAIN',NULL,'ST',NULL,'Rockville','MD','20850');
INSERT INTO dbo.ADDRESS VALUES(2,'99 POST RD','99','POST',NULL,'RD',NULL,'Rockville','MD','20850');
INSERT INTO dbo.UPR_ADDRESS VALUES(1,147901,1,1,1,NULL,NULL),(2,147901,2,2,0,NULL,NULL),(3,345168,2,1,1,NULL,'2000-01-01');
''')
q=s[s.index(';WITH Roots AS')+1:s.index('CREATE UNIQUE CLUSTERED INDEX IX_ReportTree')]
q=q.replace('TOP (@RootLimit)','').replace('ORDER BY u.AccountNumber, u.UPRID','ORDER BY u.AccountNumber, u.UPRID LIMIT @RootLimit')
q=q.replace('LevelNo = 0,','0 AS LevelNo,').replace('LevelNo = t.LevelNo + 1,','t.LevelNo + 1 AS LevelNo,').replace('SortPath = ','')
q=q.replace('CONVERT(VARCHAR(8000),','TEXT(').replace('RIGHT(','RRIGHT(').replace("N'","'")
q=re.sub(r'CONVERT\(VARCHAR\(20\), ([uc]\.UPRID)\)',r'CAST(\1 AS TEXT)',q)
q=q.replace(" + CAST("," || CAST(").replace("t.SortPath + '.'\n            +", "t.SortPath || '.'\n            ||")
q=q.replace('SELECT * INTO #ReportTree FROM Tree OPTION(MAXRECURSION 100);','SELECT * FROM Tree;')
# Give the recursive CTE explicit names as TSQL SortPath= aliases were removed.
q=q.replace('Tree AS','Tree(RootUPRID,RootAccount,UPRID,ParentUPRID,EntityTypeID,AccountNumber,StatusCode,LevelNo,SortPath) AS')
rows=db.execute(q,dict(RootLimit=99,NormAccount=None)).fetchall()
assert len(rows)==6
assert [(r[2],r[7]) for r in rows if r[0]==24]==[(24,0),(147901,1),(345168,2)]
assert len({r[8] for r in rows})==6
assert len(db.execute(q,dict(RootLimit=1,NormAccount=None)).fetchall())==3
assert len(db.execute(q,dict(RootLimit=99,NormAccount='00118285')).fetchall())==3
assert db.execute(q,dict(RootLimit=99,NormAccount='MISSING')).fetchall()==[]
print('PASS: actual recursive tree yields all roots/children, exact filters/root caps and distinct 13-digit ID paths')
# Orphan fallback: cannot assign fabricated root depth, but includes the record.
db.execute('CREATE TABLE ReportTree(RootUPRID INTEGER,RootAccount TEXT,UPRID INTEGER PRIMARY KEY,ParentUPRID INTEGER,EntityTypeID INTEGER,AccountNumber TEXT,StatusCode TEXT,LevelNo INTEGER,SortPath TEXT)')
db.executemany('INSERT INTO ReportTree VALUES(?,?,?,?,?,?,?,?,?)',rows)
fallback=re.search(r'INSERT #ReportTree\(.*?\)\s*(SELECT .*?);',s,re.S)[1]
fallback=fallback.replace('#ReportTree','ReportTree').replace('CONVERT(VARCHAR(8000),','TEXT(').replace('CONVERT(VARCHAR(20),u.UPRID)','CAST(u.UPRID AS TEXT)').replace("N'~'+","'~'||")
db.execute('INSERT INTO ReportTree '+fallback)
assert db.execute('SELECT COUNT(*) FROM ReportTree').fetchone()==(7,)
assert db.execute('SELECT LevelNo FROM ReportTree WHERE UPRID=999').fetchone()==(-1,)
# Actual owner OUTER APPLY as a correlated parameterized scalar query.
owner=re.search(r'SELECT TOP\(1\) oc.OwnerUPRID.*?\n\) owner',s,re.S)[0].removesuffix('\n) owner')
owner=owner.replace('TOP(1) ','').replace('t.UPRID','@SelectedUPRID').replace("N'","'")+' LIMIT 1'
args=dict(SelectedUPRID=345168,AsOfDate='2026-10-13')
assert db.execute(owner,args).fetchone()[:2]==(24,'Owner Person') # not unit agent or expired owner
# Direct ownership wins over inherited ownership and contacts.
db.execute("INSERT INTO dbo.PROPERTY VALUES(345168,'Unit-specific owner')")
assert db.execute(owner,args).fetchone()[:2]==(345168,'Unit-specific owner')
print('PASS: unresolved records retained; actual owner selection handles personal names, inheritance, direct override, roles and expiry')
a=re.search(r'SELECT TOP\(1\) addr.AddressID.*?\n\) a',s,re.S)[0].removesuffix('\n) a')
a=a.replace('TOP(1) ','').replace('t.UPRID','@SelectedUPRID').replace('Pri=0,Distance=0','0 AS Pri,0 AS Distance').replace("N'","'")+' LIMIT 1'
address=db.execute(a,args).fetchone()
assert address[0]==1 and address[-2:]==(147901,'PHYSICAL')
print('PASS: actual address fallback ignores expired unit link, selects physical Building address and retains source UPRID')
print('LIMIT: offline relational tests do not prove SQL Server runtime binding, permissions or performance')

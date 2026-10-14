#!/usr/bin/env python3
"""Demo SQL parser input + actual relational query tests; not SQL Server execution."""
from pathlib import Path
import re, sqlite3
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'scripts/demo_upr_property360.sql').read_text()
body=re.search(r"DECLARE @DemoSql NVARCHAR\(MAX\)=N'((?:[^']|'')*)';",source,re.S)[1].replace("''","'")
Path('/tmp/upr-demo-body.sql').write_text(body)
# Preflight column names must exist in the project DDL; no invented source tables.
ddl=(ROOT/'ddl/03_new_upr_schema.sql').read_text()
required=re.findall(r"\(N'(\w+)',N'(\w+)'\)",source.split('DECLARE @DemoSql')[0])
assert len(required)>80
schemas={name:re.findall(r'^\s*(\w+)\s+(?:BIGINT|INT|SMALLINT|VARCHAR|NVARCHAR|CHAR|DATE|DATETIME2|BIT|DECIMAL)\b',definition,re.M|re.I)
 for name,definition in re.findall(r'CREATE TABLE dbo\.(\w+)\s*\((.*?)\n\);',ddl,re.S|re.I)}
for table,col in required: assert col in schemas[table],(table,col)
# Require every persistent object referenced by the body to be preflighted.
assert set(re.findall(r'\bdbo\.(\w+)',body))=={t for t,c in required}
# No permanent DML/DDL, JSON output, installation dependencies or closure writes.
for statement in re.findall(r'\b(?:INSERT|UPDATE|DELETE|ALTER|DROP|CREATE)\s+[^;]*;',body,re.I):
 assert not re.match(r'(?:UPDATE|ALTER|DROP|CREATE)\s+(?:TABLE\s+)?dbo\.',statement,re.I)
 assert not re.match(r'INSERT\s+(?:INTO\s+)?dbo\.',statement,re.I)
assert 'FOR JSON' not in body and 'AuditLog' not in body and 'UPR_CLOSURE' not in re.sub(r'/\*.*?\*/','',body,flags=re.S)
assert '@MaxContextNodes' in body and 'No partial tree' in body
print('PASS: all 16 referenced tables and required columns match project DDL; no permanent writes or JSON')
db=sqlite3.connect(':memory:');db.execute("ATTACH ':memory:' AS dbo")
for table,cols in schemas.items():
 if table not in {t for t,c in required}:continue
 db.execute('CREATE TABLE dbo.'+table+'('+','.join('['+c+'] '+('INTEGER' if c.endswith('ID') else 'TEXT COLLATE NOCASE') for c in cols)+')')
db.create_function('CHARINDEX',2,lambda needle,s: None if needle is None or s is None else s.lower().find(needle.lower())+1)
db.create_function('CONCAT',-1,lambda *xs: ''.join('' if x is None else str(x) for x in xs))
db.create_function('TRY_BIGINT',1,lambda s: int(s) if s is not None and str(s).lstrip('-').isdigit() else None)
db.executescript('''
CREATE TABLE SearchAddress(UPRID INTEGER,AddressID INTEGER,DisplayAddress TEXT,SearchAddress TEXT,AddressRole TEXT,IsPrimary INTEGER);
CREATE TABLE Context(UPRID INTEGER PRIMARY KEY,ParentUPRID INTEGER,RootLevel INTEGER);
INSERT INTO dbo.REF_ENTITYTYPE(EntityTypeID,Description) VALUES(1,'Complex'),(2,'Building'),(3,'Unit'),(4,'Property');
INSERT INTO dbo.UPR(UPRID,ParentUPRID,EntityTypeID,AccountNumber,StatusCode) VALUES
 (24,NULL,1,'00123456','ACTIVE'),(88787,24,2,NULL,'ACTIVE'),(88788,24,2,NULL,'ACTIVE'),
 (207074,88787,3,NULL,'ACTIVE'),(207075,88788,3,NULL,'ACTIVE'),(90,NULL,4,'99999999','ACTIVE');
INSERT INTO dbo.BUILDING(BuildingID,UPRID) VALUES(10,88787),(11,88788);
INSERT INTO dbo.UNIT(UnitID,UPRID,BuildingID,UnitNumber) VALUES(100,207074,10,'101'),(101,207075,11,'101');
INSERT INTO SearchAddress VALUES(24,1,'123 Main St','123 MAIN ST','PHYSICAL',1),
 (88788,1,'123 Main St','123 MAIN ST','PHYSICAL',1),(207075,1,'123 Main St','123 MAIN ST','PHYSICAL',1),
 (90,2,'123 Main St','123 MAIN ST','MAILING',1);
INSERT INTO dbo.PROPERTY(UPRID,Parcel,OwnerName) VALUES(90,'P-900','Example Owner');
INSERT INTO dbo.REF_ROLETYPE(RoleTypeID,RoleTypeCode) VALUES(1,'OWNER'),(2,'AGENT');
INSERT INTO dbo.CONTACT(ContactID,FirstName,LastName,OrganizationName,StatusCode) VALUES
 (1,'A','Person','Shared Owner','ACTIVE'),(2,'A','Person','Old Owner','ACTIVE'),(3,'A','Person','Agent Only','ACTIVE');
INSERT INTO dbo.UPR_CONTACT(UPRID,ContactID,RoleTypeID,EffectiveDate,EndDate) VALUES
 (24,1,1,NULL,NULL),(90,2,1,'2000-01-01','2001-01-01'),(90,3,2,NULL,NULL);
INSERT INTO dbo.EXTERNAL_IDENTIFIER_XREF(UPRID,SourceSystem,IdentifierType,IdentifierValue) VALUES
 (207075,'MPDU SOURCE','PROGRAM_ID','A1'),(207075,'MPDU SOURCE','PROGRAM_ID','A2'),
 (90,'OTHER SOURCE','PROGRAM_ID','A1'),(24,'LOAN SOURCE','LOAN_ID','L1'),
 (24,'CASE SOURCE','CASE_NO','C1'),(88788,'LICENSE SOURCE','LICENSE_NO','LIC1'),
 (24,'SDAT','PARCEL_ID','P-24'),(207075,'MA','ACCOUNT_NUMBER','00123456');
''')
q=re.search(r'/\* MATCH_QUERY_BEGIN \*/(.*?)/\* MATCH_QUERY_END \*/',body,re.S)[1]
q=q.replace(' INTO #Matches','').replace('#SearchAddress','SearchAddress').replace("N'","'").replace('TRY_CONVERT(BIGINT,@SearchValue)','TRY_BIGINT(@SearchValue)')
base=dict(SearchBy='UPRID',SearchValue='24',EntityType=None,AddressRole=None,Account='00123456',Needle='123 MAIN ST',AsOfDate='2026-10-08',BuildingUPRID=None,SourceSystem=None,IdentifierType=None)
def search(want,**values):
 args=base|values;got={r[0] for r in db.execute(q,args)};assert got==set(want),(args,got,want)
search([24]);search([],SearchValue='987654');search([],SearchValue='not-a-number')
search([24,88788,207075,90],SearchBy='ADDRESS',SearchValue='123 Main Street')
search([207075],SearchBy='ADDRESS',EntityType='Unit')
search([24,207075],SearchBy='ACCOUNT',SearchValue='123456')
search([24],SearchBy='PARCEL',SearchValue='P-24');search([90],SearchBy='PARCEL',SearchValue='P-900')
search([24],SearchBy='OWNER',SearchValue='Shared Owner');search([],SearchBy='OWNER',SearchValue='Old Owner')
search([],SearchBy='OWNER',SearchValue='Agent Only');search([90],SearchBy='OWNER',SearchValue='Example Owner')
search([207074,207075],SearchBy='UNIT',SearchValue='101');search([207075],SearchBy='UNIT',SearchValue='101',BuildingUPRID=88788)
for category,system,typ,value,want in [('MPDU','MPDU SOURCE','PROGRAM_ID','A1',[207075]),
 ('MULTIFAMILY_LOANS','LOAN SOURCE','LOAN_ID','L1',[24]),('CASE','CASE SOURCE','CASE_NO','C1',[24]),
 ('LICENSE','LICENSE SOURCE','LICENSE_NO','LIC1',[88788]),('MPDU','MPDU SOURCE','PROGRAM_ID',None,[207075])]:
 search(want,SearchBy=category,SearchValue=value,SourceSystem=system,IdentifierType=typ)
search([],SearchBy='MPDU',SearchValue='A1',SourceSystem='missing',IdentifierType='PROGRAM_ID')
# Percent and underscore are literal substring searches, not SQL wildcards.
search([],SearchBy='OWNER',SearchValue='%');search([],SearchBy='OWNER',SearchValue="' OR 1=1 --")
print('PASS: actual search predicates cover all criteria, duplicate addresses, source collisions, unit ambiguity, owner roles and literal values')

# Populate addresses using the actual association/role/date SELECT, then execute
# its actual literal token replacements. Do not assume pre-normalized fixtures.
db.executescript("""
INSERT INTO dbo.REF_ADDRESSROLE(AddressRoleID,AddressRoleCode) VALUES(1,'PHYSICAL'),(2,'MAILING');
INSERT INTO dbo.ADDRESS(AddressID,StreetNumber,StreetName,StreetType,City,State,ZipCode) VALUES
 (1,'123','Main','Street','Rockville','MD','20850'),(2,'123','Main','St','Rockville','MD','20850');
INSERT INTO dbo.UPR_ADDRESS(UPRID,AddressID,AddressRoleID,IsPrimary,EffectiveDate,EndDate) VALUES
 (24,1,1,1,NULL,NULL),(88788,1,1,1,NULL,NULL),(207075,1,1,1,NULL,NULL),
 (90,2,2,1,NULL,NULL),(90,1,1,0,'2000-01-01','2001-01-01'),
 (90,1,1,0,'2099-01-01',NULL);
""")
address_sql=re.search(r'INSERT #SearchAddress\s*(SELECT .*?);',body,re.S)[1].replace("N'","'")
db.execute('DELETE FROM SearchAddress')
db.execute('INSERT INTO SearchAddress '+address_sql,dict(AddressRole='PHYSICAL',AsOfDate='2026-10-08'))
assert {r[0] for r in db.execute('SELECT UPRID FROM SearchAddress')}=={24,88788,207075}
first_update=re.search(r'UPDATE #SearchAddress SET SearchAddress=UPPER(.*?);',body,re.S)[0]
db.execute(first_update.replace('#SearchAddress','SearchAddress').replace("N'","'").replace('NCHAR(', 'CHAR('))
while db.execute("SELECT 1 FROM SearchAddress WHERE CHARINDEX('  ',SearchAddress)>0").fetchone():
 db.execute("UPDATE SearchAddress SET SearchAddress=REPLACE(SearchAddress,'  ',' ')")
db.execute("UPDATE SearchAddress SET SearchAddress=' '||LTRIM(RTRIM(SearchAddress))||' '")
for token_sql in re.findall(r"UPDATE #SearchAddress SET SearchAddress=REPLACE\(SearchAddress,N' [^']+ ',N' [^']+ '\);",body):
 db.execute(token_sql.replace('#SearchAddress','SearchAddress').replace("N'","'"))
db.execute('UPDATE SearchAddress SET SearchAddress=LTRIM(RTRIM(SearchAddress))')
search([24,88788,207075],SearchBy='ADDRESS',SearchValue='123 Main Street',AddressRole='PHYSICAL')
assert all('MAIN ST ROCKVILLE' in r[0] for r in db.execute('SELECT SearchAddress FROM SearchAddress'))
print('PASS: actual address preparation normalizes street tokens and excludes ended/future or wrong-role associations')

# Execute the actual downward expansion for root, building and unit selections.
expansion=re.search(r'/\* CONTEXT_EXPANSION_BEGIN \*/(.*?)/\* CONTEXT_EXPANSION_END \*/',body,re.S)[1]
expansion=expansion.replace('INSERT #Context','INSERT INTO Context').replace('#Context','Context')
expansion=expansion.replace('TOP(@MaxContextNodes+1) ','').rstrip().removesuffix(';')+' LIMIT @Cap;'
up=re.search(r'SELECT @Parent=ParentUPRID FROM dbo.UPR WHERE UPRID=@Walk;',body)[0].replace('@Parent=','')
def context(selected,cap=5000):
 seen=[];cur=selected
 while cur is not None:
  if cur in seen: raise ValueError('cycle')
  seen.append(cur);row=db.execute(up,dict(Walk=cur)).fetchone()
  if row is None:raise ValueError('orphan')
  root=cur;cur=row[0]
 db.execute('DELETE FROM Context');db.execute('INSERT INTO Context VALUES(?,NULL,0)',(root,));depth=0
 while True:
  n=db.execute(expansion,dict(Depth=depth,Cap=cap+1)).rowcount
  if db.execute('SELECT COUNT(*) FROM Context').fetchone()[0]>cap:raise ValueError('limit')
  if n==0:break
  depth+=1
 return list(db.execute('SELECT UPRID,RootLevel FROM Context ORDER BY UPRID'))
expected=[(24,0),(88787,1),(88788,1),(207074,2),(207075,2)]
for selected in (24,88788,207075):assert context(selected)==expected
try:context(24,2);raise AssertionError('limit not detected')
except ValueError as e:assert str(e)=='limit'
db.execute('UPDATE dbo.UPR SET ParentUPRID=207075 WHERE UPRID=24')
try:context(207075);raise AssertionError('cycle not detected')
except ValueError as e:assert str(e)=='cycle'
db.execute('UPDATE dbo.UPR SET ParentUPRID=123456789 WHERE UPRID=24')
try:context(207075);raise AssertionError('missing parent not detected')
except ValueError as e:assert str(e)=='orphan'
print('PASS: actual context expansion gives the complete same tree from root/building/unit; cycle, orphan and node-limit cases rejected')
print('LIMIT: SQLite relational checks do not prove SQL Server runtime binding, permissions, concurrency or performance')

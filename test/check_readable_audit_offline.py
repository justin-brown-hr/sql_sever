#!/usr/bin/env python3
"""Exercise actual audit projections and batched SQL with 200,000 synthetic events.
SQLite is used for relational/text tests, not SQL Server execution/performance.
First export OUTPUT expressions with SqlSyntax --audit-coverage ... output.json.
"""
from pathlib import Path
import argparse,json,re,sqlite3,time
root=Path(__file__).resolve().parents[1]
a=argparse.ArgumentParser();a.add_argument('outputs',type=Path);args=a.parse_args()
outputs=json.loads(args.outputs.read_text());source=(root/'scripts/load_upr_master.sql').read_text()
# Plain audit text: evaluate the exact expressions after dialect-only conversion.
# Preserve NULL vs literal text, quotes, CR/LF, Unicode and long values.
def sqlite_expression(s):
 s=re.sub(r'CONVERT\s*\(NVARCHAR\s*\(MAX\),\s*(inserted|deleted)\.\[?(\w+)\]?,\s*126\)',r'CAST(\1.[\2] AS TEXT)',s,flags=re.I)
 s=re.sub(r"CONVERT\s*\(NVARCHAR\s*\(MAX\),\s*N''\)","CAST('' AS TEXT)",s,flags=re.I)
 s=re.sub(r'CAST\s*\(NULL AS NVARCHAR\s*\(MAX\)\)', 'NULL',s,flags=re.I)
 return s.replace("N'","'").replace('NCHAR(', 'CHAR(').replace('+','||')
db=sqlite3.connect(':memory:')
values=['17','<NULL>','O\'Brien "quoted"','line1\r\nline2','Espa\u00f1a',r'literal\n\r',r'C:\new\records','x'*9000,None,'']
for item in outputs:
 for expression in item['columns'][-2:] if item['target']=='#AuditEvents' else item['columns'][-1:]:
  cols=re.findall(r'(inserted|deleted)\.\[?(\w+)\]?',expression)
  if not cols: continue
  cols=list(dict.fromkeys(cols));side=cols[0][0];assert all(x[0]==side for x in cols)
  db.execute(f'DROP TABLE IF EXISTS {side}')
  db.execute(f'CREATE TABLE {side}('+','.join('['+col+'] TEXT' for _,col in cols)+')')
  for value in values:
   db.execute(f'DELETE FROM {side}')
   db.execute(f'INSERT INTO {side} VALUES('+','.join('?' for _ in cols)+')',[value]*len(cols))
   text=db.execute('SELECT '+sqlite_expression(expression)+f' FROM {side}').fetchone()[0]
   expected='\n'.join(col+' = '+('<NULL>' if value is None else '"'+value.replace('\\','\\\\').replace('"','""').replace('\r','\\r').replace('\n','\\n')+'"') for _,col in cols)
   assert text==expected,(item['table'],value,text[:80],expected[:80])
print('PASS: actual INSERT/UPDATE/DELETE audit images preserve NULL, quotes, line breaks, Unicode and long values as labeled text')
# Test the exact batched INSERT/SELECT (remove SQL Server OUTPUT and rowcount SET).
parts=re.search(r"DECLARE @RowAuditSql NVARCHAR\(MAX\)=N'((?:[^']|'')*)'\+QUOTENAME\(@AuditNewColumn\)\+N'((?:[^']|'')*)';",source)
assert parts
row_sql=parts[1].replace("''","'")+'[NewValue]'+parts[2].replace("''","'")
row_sql=re.sub(r'OUTPUT inserted.AuditID INTO #PersistedAuditIDs\(AuditID\)','',row_sql)
row_sql=row_sql.split(';')[0].replace('INSERT dbo.','INSERT INTO dbo.').replace('#','').replace('@prefix+','@prefix||')
db.executescript('''ATTACH ':memory:' AS dbo;
CREATE TABLE dbo.AuditLog(AuditID INTEGER PRIMARY KEY,UPRID BIGINT,EntityNameID INT NOT NULL,EntityRecordID BIGINT NOT NULL,
OperationType TEXT,ChangedBy TEXT,ChangedDate TEXT,OldValues TEXT,NewValue TEXT);
CREATE TABLE AuditEntityMap(EntityName TEXT PRIMARY KEY,EntityID INT NOT NULL);
INSERT INTO AuditEntityMap VALUES('UPR',1),('UNIT',2);
CREATE TABLE AuditEvents(EventID INTEGER PRIMARY KEY,EntityName TEXT,UPRID BIGINT,EntityRecordID BIGINT,OperationType TEXT,OldValues TEXT,NewValue TEXT);
''')
count=200000
start=time.monotonic()
db.executemany('INSERT INTO AuditEvents VALUES(?,?,?,?,?,?,?)',
 ((i,'UPR' if i%2 else 'UNIT',i,i,'INSERT',None,f'UPRID = "{i}"\nStatusCode = "ACTIVE"') for i in range(1,count+1)))
loops=0
while db.execute('SELECT 1 FROM AuditEvents LIMIT 1').fetchone():
 last=db.execute('SELECT MAX(EventID) FROM (SELECT EventID FROM AuditEvents ORDER BY EventID LIMIT 10000)').fetchone()[0]
 expected=db.execute('SELECT COUNT(*) FROM AuditEvents WHERE EventID<=?',(last,)).fetchone()[0]
 written=db.execute(row_sql,{'who':'Fixture','at':'2026-10-06','prefix':'RunID = offline-fixture\n','last':last}).rowcount
 assert written==expected
 db.execute('DELETE FROM AuditEvents WHERE EventID<=?',(last,));loops+=1
assert loops==20
assert db.execute('SELECT COUNT(*),COUNT(DISTINCT EntityRecordID) FROM dbo.AuditLog').fetchone()==(count,count)
assert db.execute('SELECT COUNT(*) FROM dbo.AuditLog WHERE EntityNameID=1 AND UPRID IS NOT NULL').fetchone()==(100000,)
assert db.execute("SELECT COUNT(*) FROM dbo.AuditLog WHERE NewValue NOT LIKE 'RunID = offline-fixture%' OR NewValue LIKE '{%' OR NewValue LIKE '[%'").fetchone()==(0,)
print('PASS: 200,000 synthetic events written exactly once in 20 batches; UPR associations and readable values retained (SQLite correctness test, not SQL Server throughput)')

#!/usr/bin/env python3
"""Prevent the missing-support-table dependency regression seen by the client.

This is a static dependency check, not a SQL Server compilation test.
"""
from pathlib import Path
import argparse
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'scripts/load_upr_master.sql').read_text()
# One lexical pass respects comment markers inside quoted SQL strings.
tokens = re.compile(r"N?'(?:[^']|'')*'|/\*[\s\S]*?\*/|--[^\n]*", re.I)
outer = tokens.sub(lambda m: '\n' * m[0].count('\n') + ' ', source)
assert "'" not in outer, 'Unterminated SQL string'
depth = 0
for c in outer:
    if c == '(':
        depth += 1
    elif c == ')':
        depth -= 1
        assert depth >= 0, 'Unbalanced outer SQL parentheses'
assert depth == 0, 'Unbalanced outer SQL parentheses'
optional = {'UPR_CONDO_LEGACY', 'AUDIT_LOG_CONTEXT', 'UPR_LOAD_RUN',
            'AUDIT_LOG', 'AUDIT_ENTITY_RECORD'}
refs = set(re.findall(r'\bdbo\.([A-Za-z_][A-Za-z_0-9]*)', outer, re.I))
assert not optional.intersection(x.upper() for x in refs), refs
assert not re.search(r'CREATE\s+TABLE\s+dbo\.', outer, re.I), 'Unexpected permanent support table'
assert not re.search(r'(?:DISABLE|DROP)\s+TRIGGER', outer, re.I), 'Client triggers altered'
assert not re.search(r'ALTER\s+TABLE\s+dbo\.UPR_CLOSURE\s+ALTER\s+COLUMN', outer, re.I), 'Existing closure column definition changed'
assert not re.search(r'ALTER\s+TABLE\s+dbo\.UPR_CLOSURE\s+(?:WITH\s+CHECK\s+)?ADD\s+CONSTRAINT', outer, re.I), 'Unrequested closure constraint added'
assert not re.search(r'DROP\s+INDEX', outer, re.I), 'Existing index dropped'
assert 'FROM #AuditEvents' in outer and 'FROM #ProtectedCondoUPR' in outer
print('PASS: no static references to absent support objects; no new tables or trigger removal')

# Every statically bound model object is from the established DDL or incoming schema.
ddl = (ROOT / 'ddl/03_new_upr_schema.sql').read_text()
known = set(re.findall(r'CREATE TABLE dbo\.(\w+)', ddl, re.I))
known.update({'MAIncomingTableX1', 'SDATIncomingTableX1'})
known.update(re.findall(r'FUNCTION dbo\.(\w+)', source, re.I))
assert not (refs - known), refs - known
print('PASS: remaining static object references belong to the base model/source schema')

# Client diagnostics must cover the loader's core objects and written columns,
# including INSERT syntax where the optional INTO keyword is omitted.
diagnostic = (ROOT / 'scripts/check_upr_client_schema.sql').read_text()
expected = {(t.lower(), c.lower()) for t, c in re.findall(
    r"\(N'([^']+)',N'([^']+)',N'(?:CORE|LOADER_ADDS_IF_ABSENT)'\)", diagnostic)}
core_tables = {t for t, _ in expected}
functions = {x.lower() for x in re.findall(r'FUNCTION dbo\.(\w+)', source, re.I)}
assert not ({x.lower() for x in refs} - functions - core_tables), 'Core object missing from diagnostic'
for table, columns in re.findall(
        r'INSERT\s+(?:INTO\s+)?dbo\.(\w+)\s*\(([^()]*)\)', outer, re.I):
    for column in columns.split(','):
        key = (table.lower(), column.strip().strip('[]').lower())
        assert key in expected, f'Written column absent from diagnostic: {key}'
for table, columns in re.findall(
        r'MERGE\s+dbo\.(\w+)\s+AS\s+t\b.*?WHEN\s+NOT\s+MATCHED\s+THEN\s*INSERT\s*\(([^)]*)\)',
        outer, re.I | re.S):
    for column in columns.split(','):
        key = (table.lower(), column.strip().strip('[]').lower())
        assert key in expected, f'MERGE column absent from diagnostic: {key}'
assert len(expected) >= 150, 'Client diagnostic coverage unexpectedly shrank'
print('PASS: client diagnostic covers all core tables and INSERT/MERGE columns')

# Exercise actual optional archive/live-name SELECTs in SQLite with temp protection.
db = sqlite3.connect(':memory:')
db.executescript("""
ATTACH ':memory:' AS dbo;
CREATE TABLE ProtectedCondoUPR(UPRID INTEGER PRIMARY KEY);
CREATE TABLE dbo.CONDO(UPRID INTEGER,CondoName TEXT,Parcel TEXT);
INSERT INTO dbo.CONDO VALUES(1,'CLIENT NAME',NULL),(2,NULL,NULL),(3,'BOTH',NULL),(5,NULL,'KEEP PARCEL');
CREATE TABLE dbo.UPR_CONDO_LEGACY(UPRID INTEGER,CondoName TEXT);
INSERT INTO dbo.UPR_CONDO_LEGACY VALUES(3,'BOTH'),(4,'ARCHIVED NAME'),(4,'OLDER NAME');
""")
dynamic = [m[0][2:-1].replace("''", "'") for m in tokens.finditer(source)
           if m[0].startswith("N'")]
archive = next(s for s in dynamic if s.startswith('INSERT #ProtectedCondoUPR')
               and 'UPR_CONDO_LEGACY' in s)
live = next(s for s in dynamic if s.startswith('INSERT #ProtectedCondoUPR')
            and 'c.CondoName IS NOT NULL' in s)
parcel = next(s for s in dynamic if s.startswith('INSERT #ProtectedCondoUPR')
              and 'c.Parcel IS NOT NULL' in s)
for query in (archive, live, parcel):
    db.executescript(query.replace('INSERT #', 'INSERT INTO #').replace('#ProtectedCondoUPR', 'ProtectedCondoUPR'))
assert set(db.execute('SELECT UPRID FROM ProtectedCondoUPR')) == {(1,), (3,), (4,), (5,)}
db.execute('DELETE FROM ProtectedCondoUPR')
db.execute('DROP TABLE dbo.UPR_CONDO_LEGACY')
db.executescript(live.replace('INSERT #', 'INSERT INTO #').replace('#ProtectedCondoUPR', 'ProtectedCondoUPR'))
db.executescript(parcel.replace('INSERT #', 'INSERT INTO #').replace('#ProtectedCondoUPR', 'ProtectedCondoUPR'))
assert set(db.execute('SELECT UPRID FROM ProtectedCondoUPR')) == {(1,), (3,), (5,)}
print('PASS: live Condo names/parcels are protected without an archive; combined records are deduplicated')

# Exercise the actual assembled audit SQL for each known payload name. The
# client fixture has singular NewValue and VARCHAR, independently of project DDL.
# SQLite validates column binding/values here; ScriptDom separately parses the
# complete rendered T-SQL, including identity capture. Neither is a server test.
arguments = argparse.ArgumentParser()
arguments.add_argument('--audit-sql-dir', type=Path)
args = arguments.parse_args()
if args.audit_sql_dir:
    args.audit_sql_dir.mkdir(parents=True, exist_ok=True)

def render_audit(variable, column):
    match = re.search(r'DECLARE @' + variable + r' NVARCHAR\(MAX\)\s*=\s*'
        r"N'((?:[^']|'')*)'\s*\+\s*QUOTENAME\(@AuditNewColumn\)\s*\+\s*N'((?:[^']|'')*)';", source)
    assert match, f'Unrecognized SQL construction for {variable}; extend test deliberately'
    return match[1].replace("''", "'") + '[' + column + ']' + match[2].replace("''", "'")

assert 'a.NewValues' not in outer and 'a.NewValue' not in outer
assert '@audit=@SummaryAuditID OUTPUT' in outer
for payload_column in ('NewValue', 'NewValues'):
    insert = render_audit('AuditInsertSql', payload_column)
    read = render_audit('AuditDetailSql', payload_column)
    row_insert = render_audit('RowAuditSql', payload_column)
    if args.audit_sql_dir:
        (args.audit_sql_dir / (payload_column + '.sql')).write_text(insert + '\nGO\n' + read + '\nGO\n' + row_insert)
    native = sqlite3.connect(':memory:')
    native.executescript(f'''
        ATTACH ':memory:' AS dbo;
        CREATE TABLE dbo.AuditLog(AuditID INTEGER PRIMARY KEY,UPRID BIGINT NULL,
            EntityNameID INT NOT NULL,EntityRecordID BIGINT NOT NULL,
            OperationType VARCHAR(20) NOT NULL,ChangedBy VARCHAR(100) NOT NULL,
            ChangedDate TEXT NOT NULL,OldValues VARCHAR NULL,{payload_column} VARCHAR NULL);
        CREATE TABLE dbo.REF_ENTITY_IDENTIFICATION(EntityID INT,EntityName TEXT);
        INSERT INTO dbo.REF_ENTITY_IDENTIFICATION VALUES(1,'UPR_HIER_LOAD');
        CREATE TABLE PersistedAuditIDs(AuditID INT); CREATE TABLE AuditEntityMap(EntityID INT,EntityName TEXT);
        CREATE TABLE RunAuditRows(AuditID INT,RunID TEXT,EntityName TEXT,EntityKey TEXT,
            OperationType TEXT,ChangedDate TEXT,ChangedBy TEXT,OldValues TEXT,NewValues TEXT);
    ''')
    payload = 'RunID = test-run\nClosure rows = 3'
    native.execute(insert.split(';')[0].replace("N'", "'"),
        {'entity':1,'who':'Ade','at':'2026-10-05 12:00:00','payload':payload})
    assert native.execute(f'SELECT {payload_column},EntityRecordID FROM dbo.AuditLog').fetchone()==(payload,0)
    native.execute("INSERT INTO PersistedAuditIDs VALUES(1)")
    native.execute("INSERT INTO AuditEntityMap VALUES(1,'UPR_HIER_LOAD')")
    result=native.execute(read.replace('#PersistedAuditIDs','PersistedAuditIDs').replace('#AuditEntityMap','AuditEntityMap')).fetchone()
    assert result[-1]==payload
    native.close()
print('PASS: assembled audit INSERT/read binds singular and plural layouts and retains summary data')

# Parse both rendered payload variants of the client reconciliation query too.
checker = (ROOT / 'scripts/check_upr_audit_result.sql').read_text()
construction = re.search(r"DECLARE @Sql NVARCHAR\(MAX\)=(.*?);\s*EXEC sys.sp_executesql", checker, re.S)[1]
for payload_column in ('NewValue', 'NewValues'):
    tokens = re.findall(r"N'((?:[^']|'')*)'|QUOTENAME\(@Payload\)", construction)
    # Empty captures here are QUOTENAME tokens; there are no empty SQL literals.
    rendered = ''.join(token.replace("''", "'") if token else '['+payload_column+']' for token in tokens)
    assert 'FROM dbo.AuditLog WHERE' in rendered and rendered.count('['+payload_column+']')==2
    if args.audit_sql_dir:
        (args.audit_sql_dir / ('check_'+payload_column+'.sql')).write_text(rendered)


# Execute dictionary INSERTs assembled from the actual fixed fragments. A server
# test separately exercises the metadata discovery, identity and table locks.
base_columns = re.search(r"DECLARE @DictionaryInsertColumns NVARCHAR\(MAX\)=N'([^']*)'",source)[1]
base_values = re.search(r"DECLARE @DictionaryInsertValues NVARCHAR\(MAX\)=N'([^']*)'",source)[1]
fragments = re.findall(r"SET @DictionaryInsertColumns\+=N'([^']*)';\s*SET @DictionaryInsertValues\+=N'([^']*)';",source)
assert len(fragments)==5
for required in (set(), {'IsActive','CreatedDate','CreatedBy'},
                 {'EntityID','EntityDescription','IsActive','CreatedDate','CreatedBy'}):
    cols, vals = base_columns, base_values
    for col, val in fragments:
        if col.strip(',[]') in required:
            cols += col
            vals += val
    statement = 'INSERT INTO dbo.REF_ENTITY_IDENTIFICATION ('+cols+') VALUES ('+vals+');'
    mode = 'manual' if 'EntityID' in required else 'metadata' if required else 'defaults'
    if args.audit_sql_dir:
        (args.audit_sql_dir / ('dictionary_'+mode+'.sql')).write_text(statement)
    db=sqlite3.connect(':memory:')
    db.executescript("""ATTACH ':memory:' AS dbo;
        CREATE TABLE dbo.REF_ENTITY_IDENTIFICATION(EntityID INTEGER PRIMARY KEY,
            EntityName VARCHAR(100) NOT NULL UNIQUE,EntityDescription VARCHAR(250) NOT NULL DEFAULT('default description'),
            IsActive INT NOT NULL DEFAULT(1),CreatedDate TEXT NOT NULL DEFAULT('2026-10-05'),
            CreatedBy VARCHAR(100) NOT NULL DEFAULT('default creator'));
        INSERT INTO dbo.REF_ENTITY_IDENTIFICATION(EntityID,EntityName) VALUES(41,'UPR');""")
    db.execute(statement,{'name':'UPR_HIER_LOAD','id':42,'description':'Load batch summary',
                          'active':1,'created':'2026-10-05','creator':'Ade'})
    assert db.execute("SELECT EntityID,IsActive FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD'").fetchone()==(42,1)
    assert db.execute("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR'").fetchone()==(41,)
    db.close()
assert 'WITH(TABLOCKX,HOLDLOCK)' in source and '@LargestEntityID>=2147483647' in source
print('PASS: dictionary INSERT variants preserve existing IDs and supply standard required metadata')

# Reproduce the October 6 failure with a nullable, NON-identity manual key.
# INTEGER PRIMARY KEY would auto-generate in SQLite and hide this regression.
nullable = sqlite3.connect(':memory:')
nullable.executescript("""ATTACH ':memory:' AS dbo;
    CREATE TABLE dbo.REF_ENTITY_IDENTIFICATION(EntityID INT NULL,EntityName TEXT NOT NULL);
    INSERT INTO dbo.REF_ENTITY_IDENTIFICATION VALUES(41,'UPR');
    INSERT INTO dbo.REF_ENTITY_IDENTIFICATION(EntityName) VALUES('UPR_HIER_LOAD');""")
assert nullable.execute("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD'").fetchone() == (None,)
# Use the loader's actual metadata predicate: both nullable and required manual
# IDs are included; identity, computed and default-generated IDs are excluded.
predicate = re.search(r"SELECT name,system_type_id FROM sys.columns\s+WHERE object_id=OBJECT_ID\(N'dbo.REF_ENTITY_IDENTIFICATION'\)(.*?)\s*;",source,re.S)[1]
nullable.execute('CREATE TABLE Metadata(name TEXT,system_type_id INT,is_nullable INT,is_identity INT,is_computed INT,default_object_id INT)')
for nullable_flag, identity, computed, default_id, expected in (
        (1,0,0,0,True),(0,0,0,0,True),(0,1,0,0,False),
        (1,0,1,0,False),(1,0,0,17,False)):
    nullable.execute('DELETE FROM Metadata')
    nullable.execute('INSERT INTO Metadata VALUES(?,?,?,?,?,?)',('EntityID',56,nullable_flag,identity,computed,default_id))
    selected = nullable.execute('SELECT name FROM Metadata WHERE 1=1 '+predicate.replace("N'","'")).fetchall()
    assert bool(selected)==expected,(nullable_flag,identity,computed,default_id,selected)
# Execute the actual NULL-only repair statement; repeat does not remap an ID.
repair = re.search(r"UPDATE dbo.REF_ENTITY_IDENTIFICATION SET EntityID=@NextEntityID\s+WHERE EntityName=@AuditEntityName AND EntityID IS NULL;",source)[0]
nullable.execute(repair.replace("N'","'"),{'NextEntityID':42,'AuditEntityName':'UPR_HIER_LOAD'})
nullable.execute(repair.replace("N'","'"),{'NextEntityID':43,'AuditEntityName':'UPR_HIER_LOAD'})
assert nullable.execute('SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION ORDER BY EntityID').fetchall()==[(41,),(42,)]
nullable.execute("DELETE FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD'")
manual_cols,manual_vals=base_columns,base_values
for col,val in fragments:
    if col.strip(',[]')=='EntityID':
        manual_cols+=col
        manual_vals+=val
nullable.execute('INSERT INTO dbo.REF_ENTITY_IDENTIFICATION ('+manual_cols+') VALUES ('+manual_vals+')',{'name':'UPR_HIER_LOAD','id':42})
assert nullable.execute("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD'").fetchone()==(42,)
preflight = source[source.index('BEGIN TRANSACTION;\n/* Create the batch-summary dictionary'):source.index("PRINT N'Step 1:")]
assert 'IF @ResolvedAuditEntityID IS NULL' in preflight
assert 'WHERE EntityID=@ResolvedAuditEntityID)<>1' in preflight
assert source.index('IF @SummaryEntityID IS NULL',source.index("PRINT N'Step 14:")) < source.index('DECLARE @AuditInsertSql')
nullable.execute("CREATE TABLE dbo.AuditLog(AuditID INTEGER PRIMARY KEY,EntityNameID INT NOT NULL,EntityRecordID BIGINT NOT NULL,OperationType TEXT NOT NULL,ChangedBy TEXT NOT NULL,ChangedDate TEXT NOT NULL,NewValue TEXT)")
audit_statement=render_audit('AuditInsertSql','NewValue').split(';')[0].replace("N'","'")
parameters={'entity':None,'who':'Ade','at':'2026-10-06','payload':'{}'}
try:
    nullable.execute(audit_statement,parameters)
    raise AssertionError('Old NULL key unexpectedly accepted by AuditLog')
except sqlite3.IntegrityError as error:
    assert 'EntityNameID' in str(error)
parameters['entity']=nullable.execute("SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName='UPR_HIER_LOAD'").fetchone()[0]
nullable.execute(audit_statement,parameters)
assert nullable.execute('SELECT EntityNameID FROM dbo.AuditLog').fetchall()==[(42,)]
nullable.close()
print('PASS: reproduced nullable-key omission; actual metadata predicate, manual INSERT and NULL-only repair preserve non-NULL IDs; early and final ID guards present')

# Execute the actual audit metadata predicates against modeled catalog rows.
# These exercise NULL/default/generated handling without pretending SQLite is SQL Server.
guard=source.split('/* AUDIT_INSERT_PREFLIGHT_BEGIN',1)[1].split('/* AUDIT_INSERT_PREFLIGHT_END */',1)[0]
predicates=re.findall(r"SELECT 1 FROM sys.columns c\s+WHERE c.object_id=OBJECT_ID\(N'dbo.AuditLog'\)(.*?)\)\s*(?:BEGIN|THROW)",guard,re.S)
assert len(predicates)==3
catalog=sqlite3.connect(':memory:')
catalog.execute('CREATE TABLE Columns(name TEXT,is_nullable INT,is_identity INT,is_computed INT,default_object_id INT,system_type_id INT,generated_always_type INT)')
rows=[('AuditID',0,1,0,0,56,0),('UPRID',1,0,0,0,127,0),
      ('EntityNameID',0,0,0,0,56,0),('EntityRecordID',0,0,0,0,127,0),
      ('OperationType',0,0,0,0,167,0),('ChangedBy',0,0,0,0,167,0),
      ('ChangedDate',0,0,0,1,42,0),('OldValues',1,0,0,0,167,0),('NewValue',1,0,0,0,167,0)]
def audit_issues(extra=(),replacement=None):
    catalog.execute('DELETE FROM Columns')
    data=rows.copy()
    if replacement:
        data=[replacement if r[0]==replacement[0] else r for r in data]
    catalog.executemany('INSERT INTO Columns VALUES(?,?,?,?,?,?,?)',data+list(extra))
    found=[catalog.execute('SELECT c.name FROM Columns c WHERE 1=1 '+p.replace("N'","'"),
                           {'AuditNewColumn':'NewValue'}).fetchall() for p in predicates]
    return bool(found[0]),not bool(found[1]),bool(found[2])
assert audit_issues()==(False,False,False)
assert audit_issues([('ClientRequired',0,0,0,0,56,0)])==(True,False,False)
assert audit_issues([('ClientDefault',0,0,0,1,56,0)])==(False,False,False)
assert audit_issues([('ClientNullable',1,0,0,0,56,0)])==(False,False,False)
assert audit_issues([('ClientGenerated',0,0,0,0,42,1)])==(False,False,False)
assert audit_issues(replacement=('OldValues',0,0,0,0,167,0))==(True,False,False)
assert audit_issues(replacement=('UPRID',0,0,0,0,127,0))==(True,False,False)
assert audit_issues(replacement=('AuditID',0,0,0,1,56,0))==(False,True,False)
assert audit_issues(replacement=('NewValue',1,0,1,0,167,0))==(False,False,True)
assert source.index('/* AUDIT_INSERT_PREFLIGHT_BEGIN')<source.index('BEGIN TRANSACTION;\n/* Create the batch-summary dictionary')
assert source.index('IF @SummaryAuditID IS NULL OR NOT EXISTS(')<source.index('SET @AuditInserted = 1;')<source.index('COMMIT TRANSACTION;')
catalog.close()
print('PASS: audit metadata rejects omitted required/generated target/nonidentity ID columns before business loading; persisted-row check precedes commit')

# Test the exact persisted-row SELECT, including a trigger-like deleted/remapped row.
retained=re.search(r'IF @SummaryAuditID IS NULL OR NOT EXISTS\(\s*(SELECT 1 FROM dbo.AuditLog.*?)\)\s*THROW',source,re.S)[1].replace("N'","'")
check_db=sqlite3.connect(':memory:')
check_db.executescript("ATTACH ':memory:' AS dbo; CREATE TABLE dbo.AuditLog(AuditID INT,EntityNameID INT,EntityRecordID INT,OperationType TEXT); INSERT INTO dbo.AuditLog VALUES(7,42,0,'INSERT');")
params={'SummaryAuditID':7,'SummaryEntityID':42}
assert check_db.execute(retained,params).fetchone()==(1,)
check_db.execute('UPDATE dbo.AuditLog SET EntityNameID=41')
assert check_db.execute(retained,params).fetchone() is None
check_db.execute('DELETE FROM dbo.AuditLog')
assert check_db.execute(retained,params).fetchone() is None
check_db.close()
print('PASS: actual persisted-audit query accepts correct summary and rejects removed/remapped summary')

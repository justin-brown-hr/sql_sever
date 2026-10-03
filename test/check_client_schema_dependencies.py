#!/usr/bin/env python3
"""Prevent the missing-support-table dependency regression seen by the client.

This is a static dependency check, not a SQL Server compilation test.
"""
from pathlib import Path
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
assert 'FROM #RunAuditRows' in outer and 'FROM #ProtectedCondoUPR' in outer
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

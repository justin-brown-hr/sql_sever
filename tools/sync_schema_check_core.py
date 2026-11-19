#!/usr/bin/env python3
"""Sync the CORE column list of scripts/check_upr_client_schema.sql with the DDL.

Every UPR table the loader reads or writes lists ALL of its DDL columns as CORE
(source tables MAIncomingTableX1 / SDATIncomingTableX1 and the special-cased
AuditLog / REF_ENTITY_IDENTIFICATION entries are left as they are, except for
the AuditLog names given in AUDITLOG below).
Usage: sync_schema_check_core.py DDL   (rewrites the checker in place)
Then run tools/regen_layout_preflight.py to refresh the loader's lists.
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
checker_path = root / 'scripts/check_upr_client_schema.sql'
ddl = re.sub(r'--[^\n]*', '', Path(sys.argv[1]).read_text())
TYPE = (r'(?:BIGINT|INT|SMALLINT|TINYINT|BIT|DECIMAL|NUMERIC|MONEY|FLOAT|REAL|N?VARCHAR|N?CHAR|N?TEXT|'
        r'DATE|DATETIME2?|SMALLDATETIME|TIME|UNIQUEIDENTIFIER|VARBINARY)\b')
columns = {}
for name, body in re.findall(r'CREATE TABLE dbo\.(\w+)\s*\((.*?)\n\);', ddl, re.S):
    columns[name] = [m[1] for line in body.split('\n')
                     if (m := re.match(r'\s*\[?(\w+)\]?\s+' + TYPE, line, re.I))]

# AuditLog: the columns the loader's audit INSERTs name (payload column is chosen at run time).
AUDITLOG = ['AuditID', 'UPRID', 'EntityNameID', 'EntityRecordID', 'OperationType', 'UpdatedBy',
            'LastUpdated', 'OldValues', 'CreationUserID', 'CreationDate', 'LastUpdateUserID',
            'LastUpdateDate']
KEEP = {'MAIncomingTableX1', 'SDATIncomingTableX1', 'REF_ENTITY_IDENTIFICATION'}

src = checker_path.read_text()
line_re = re.compile(r"^(\s*)\(N'([^']+)',N'([^']+)',N'CORE'\),?\n", re.M)
tables = []
for m in line_re.finditer(src):
    if m[2] not in tables:
        tables.append(m[2])
missing = [t for t in tables if t not in KEEP and t != 'AuditLog' and t not in columns]
assert not missing, f'tables absent from DDL: {missing}'


def block(indent, table):
    cols = AUDITLOG if table == 'AuditLog' else columns[table]
    return ''.join(f"{indent}(N'{table}',N'{c}',N'CORE'),\n" for c in cols)


out, done, pos = [], set(), 0
for m in line_re.finditer(src):
    out.append(src[pos:m.start()])
    pos = m.end()
    table = m[2]
    if table in KEEP:
        out.append(m[0])
    elif table not in done:
        out.append(block(m[1], table))
        done.add(table)
out.append(src[pos:])
new = ''.join(out)
checker_path.write_text(new)
count = len(re.findall(r"N'CORE'\)", new))
print(f'checker: {count} CORE entries across {len(tables)} tables')

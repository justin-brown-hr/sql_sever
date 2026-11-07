#!/usr/bin/env python3
"""Refresh the loader's RECORD_LAYOUT_PREFLIGHT column lists.

@LoaderColumns   = CORE columns of scripts/check_upr_client_schema.sql
@SuppliedColumns = columns the loader names in INSERT / MERGE ... INSERT lists
test/check_client_schema_dependencies.py asserts the two stay in sync.
"""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
loader_path = root / 'scripts/load_upr_master.sql'
src = loader_path.read_text()
diag = (root / 'scripts/check_upr_client_schema.sql').read_text()
core = sorted(set(re.findall(r"\(N'([^']+)',N'([^']+)',N'CORE'\)", diag)))
outer = re.sub(r"N?'(?:[^']|'')*'|/\*[\s\S]*?\*/|--[^\n]*", lambda m: ' ' * len(m[0]), src)
supplied = set()
for t, cols in re.findall(r'INSERT\s+(?:INTO\s+)?dbo\.(\w+)\s*\(([^()]*)\)', outer, re.I):
    supplied.update((t, c.strip().strip('[]')) for c in cols.split(','))
for t, cols in re.findall(r'MERGE\s+dbo\.(\w+)\s+AS\s+t\b.*?WHEN\s+NOT\s+MATCHED\s+THEN\s*INSERT\s*\(([^)]*)\)', outer, re.I | re.S):
    supplied.update((t, c.strip().strip('[]')) for c in cols.split(','))
supplied = sorted(x for x in supplied if x[0] not in ('AuditLog', 'REF_ENTITY_IDENTIFICATION'))


def values(rows):
    return ',\n'.join("    (N'%s',N'%s')" % r for r in rows)


for name, rows in (('LoaderColumns', core), ('SuppliedColumns', supplied)):
    pattern = re.compile(r'(INSERT @' + name + r'\(TableName,ColumnName\) VALUES\n)(.*?)(;\n)', re.S)
    assert len(pattern.findall(src)) == 1, name
    src = pattern.sub(lambda m: m[1] + values(rows) + m[3], src)
loader_path.write_text(src)
print(f'preflight: {len(core)} loader columns, {len(supplied)} supplied columns')

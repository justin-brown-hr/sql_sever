#!/usr/bin/env python3
"""Rebuild the loader's readable audit images from the reference DDL column lists.

Each image is the run `CONVERT(NVARCHAR(MAX),N'') + N'Col = ' + CASE WHEN p.[Col] ...`
inside an OUTPUT clause. The table is the one named by that OUTPUT (or the MERGE
target for MERGE ... OUTPUT INTO #Map). Every DDL column is listed, in DDL order.
Usage: regen_audit_images.py LOADER DDL   (rewrites LOADER in place)
"""
import re
import sys
from pathlib import Path

loader_path, ddl_path = Path(sys.argv[1]), Path(sys.argv[2])
ddl = re.sub(r'--[^\n]*', '', ddl_path.read_text())
columns = {}
for name, body in re.findall(r'CREATE TABLE dbo\.(\w+)\s*\((.*?)\n\);', ddl, re.S):
    cols = []
    for line in body.split('\n'):
        m = re.match(r'\s*\[?(\w+)\]?\s+(?:BIGINT|INT|SMALLINT|TINYINT|BIT|DECIMAL|NUMERIC|MONEY|FLOAT|REAL|'
                     r'N?VARCHAR|N?CHAR|N?TEXT|DATE|DATETIME2?|SMALLDATETIME|TIME|UNIQUEIDENTIFIER|VARBINARY)\b',
                     line, re.I)
        if m:
            cols.append(m[1])
    columns[name.upper()] = cols


def segment(prefix, col):
    return (f"N'{col} = ' + CASE WHEN {prefix}.[{col}] IS NULL THEN N'<NULL>' ELSE N'\"' + "
            f"REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX),{prefix}.[{col}],126),"
            f"N'\\',N'\\\\'),N'\"',N'\"\"'),NCHAR(13),N'\\r'),NCHAR(10),N'\\n') + N'\"' END")


SEG = (r"N'(\w+) = ' \+ CASE WHEN (deleted|inserted)\.\[\w+\] IS NULL THEN N'<NULL>' ELSE N'\"' \+ "
       r"REPLACE\(REPLACE\(REPLACE\(REPLACE\(CONVERT\(NVARCHAR\(MAX\),\2\.\[\w+\],126\),"
       r"N'\\',N'\\\\'\),N'\"',N'\"\"'\),NCHAR\(13\),N'\\r'\),NCHAR\(10\),N'\\n'\) \+ N'\"' END")
start_re = re.compile(r"CONVERT\(NVARCHAR\(MAX\),N''\) \+ (?=N'\w+ = ' \+ CASE WHEN (deleted|inserted)\.)")
seg_re = re.compile(SEG.replace(r'\2', r'(?:deleted|inserted)'))
src = loader_path.read_text()
out, pos, count = [], 0, 0
for m in start_re.finditer(src):
    if m.start() < pos:
        continue
    prefix = m[1]
    head = src[:m.start()]
    owner = max((x for x in re.finditer(r"OUTPUT N'(\w+)'|MERGE dbo\.(\w+) AS t", head)), key=lambda x: x.start())
    table = (owner[1] or owner[2]).upper()
    # consume segments
    end = m.end()
    sm = seg_re.match(src, end)
    assert sm, src[end:end + 200]
    end = sm.end()
    while True:
        j = re.match(r" \+ NCHAR\(10\) \+\n[ \t]*", src[end:])
        nxt = j and seg_re.match(src, end + j.end())
        if not nxt:
            break
        end = nxt.end()
    cols = columns[table]
    image = "CONVERT(NVARCHAR(MAX),N'') + " + (" + NCHAR(10) +\n" + '        ').join(segment(prefix, c) for c in cols)
    out.append(src[pos:m.start()])
    out.append(image)
    pos = end
    count += 1
out.append(src[pos:])
loader_path.write_text(''.join(out))
print(f'rebuilt {count} audit images from {len(columns)} DDL tables')

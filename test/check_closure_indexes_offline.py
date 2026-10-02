#!/usr/bin/env python3
"""Exercise actual index-selection predicates against simulated SQL catalogs.

SQLite checks predicate logic; SQL Server DDL, locking and rollback still require
the integration cases in check_closure_levels.py.
"""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
loader = (ROOT / 'scripts/load_upr_master.sql').read_text()
checker = (ROOT / 'test/check_upr_closure_distance.sql').read_text()
db = sqlite3.connect(':memory:')
db.executescript("""
ATTACH ':memory:' AS sys;
CREATE TABLE sys.indexes(object_id INT,index_id INT,type INT,is_unique INT,
    ignore_dup_key INT,is_disabled INT,has_filter INT,is_hypothetical INT);
CREATE TABLE sys.index_columns(object_id INT,index_id INT,column_id INT,key_ordinal INT);
CREATE TABLE sys.columns(object_id INT,column_id INT,name TEXT);
INSERT INTO sys.columns VALUES(42,1,'AncestorUPRID'),(42,2,'DescendantUPRID'),(42,3,'Level');
""")

queries = []
for marker in ('CLOSURE_FORWARD_INDEX_CHECK', 'CLOSURE_REVERSE_INDEX_CHECK'):
    pattern = r'/\* ' + marker + r' \*/\s*IF NOT EXISTS \(\s*(SELECT .*?)\n\)'
    query = re.search(pattern, loader, re.S)[1]
    assert query == re.search(pattern, checker, re.S)[1], 'Checker and loader differ'
    queries.append(query.replace("N'", "'"))

def match(keys, unique=True, included=(), **flags):
    db.execute('DELETE FROM sys.indexes')
    db.execute('DELETE FROM sys.index_columns')
    db.execute('INSERT INTO sys.indexes VALUES(42,1,?,?,?,?,?,?)',
               (flags.get('type', 2), int(unique), flags.get('ignore_dup_key', 0),
                flags.get('is_disabled', 0), flags.get('has_filter', 0),
                flags.get('is_hypothetical', 0)))
    for ordinal, column in enumerate(keys, 1):
        db.execute('INSERT INTO sys.index_columns VALUES(42,1,?,?)', (column, ordinal))
    for column in included:
        db.execute('INSERT INTO sys.index_columns VALUES(42,1,?,0)', (column,))
    return tuple(bool(db.execute(q, {'ClosureObjectID': 42}).fetchone()) for q in queries)

assert match([1, 2], type=1) == (True, False)  # clustered PK
assert match([1, 2], included=[3]) == (True, False)
assert match([1, 2], unique=False) == (False, False)
assert match([1, 2, 3]) == (False, False)  # unique on Level too does not protect pair
assert match([1]) == (False, False)
assert match([2]) == (False, False)
assert match([2, 1], unique=False) == (False, True)
assert match([2, 1], included=[3]) == (False, True)
assert match([2, 1, 3], unique=False) == (False, True)  # leading keys suffice
assert match([1, 2], ignore_dup_key=1) == (False, False)
for flag in ('is_disabled', 'has_filter', 'is_hypothetical'):
    assert match([1, 2], **{flag: 1}) == (False, False)
    assert match([2, 1], **{flag: 1}) == (False, False)
assert match([1, 2], type=7) == (False, False)  # hash index not a B-tree
print('PASS: index catalog predicates accept correct keys and reject insufficient definitions')

db.executescript('CREATE TABLE Closure(AncestorUPRID INT,DescendantUPRID INT,Level INT);'
                 'CREATE UNIQUE INDEX Pairs ON Closure(AncestorUPRID,DescendantUPRID);')
db.executemany('INSERT INTO Closure VALUES(?,?,?)',
               [(24,24,0),(24,88788,1),(24,207075,2),(88788,207075,1),(207075,207075,0)])
try:
    db.execute('INSERT INTO Closure VALUES(24,207075,99)')
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError('Duplicate pair with different Level was accepted')
assert db.execute('SELECT COUNT(*) FROM Closure').fetchone()[0] == 5
print('PASS: composite uniqueness rejects duplicate pairs but permits shared ancestors/descendants')

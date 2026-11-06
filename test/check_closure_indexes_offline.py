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

# R10: simulate setup using the actual catalog predicates/name collision queries.
# This validates name allocation/reuse, not execution of SQL Server CREATE INDEX.
db.execute('ALTER TABLE sys.indexes ADD COLUMN name TEXT')
setup=loader.split('/* CLOSURE_INDEX_SETUP_BEGIN',1)[1].split('/* CLOSURE_INDEX_SETUP_END */',1)[0]
assert 'THROW 50007' not in setup
assert not re.search(r'\b(?:DROP|ALTER)\s+INDEX',setup,re.I)
assert loader.index('/* CLOSURE_INDEX_SETUP_BEGIN')<loader.index("PRINT N'Step 1:")
assert loader.index('HAVING COUNT_BIG(*)>1')<loader.index('/* CLOSURE_INDEX_SETUP_BEGIN')
assert loader.index('BEGIN TRANSACTION;')<loader.index('/* CLOSURE_INDEX_SETUP_BEGIN')
rendered=[]
for direction,q,requiredkeys,unique in [('Forward',queries[0],[1,2],True),('Reverse',queries[1],[2,1],False)]:
    base=re.search(r'DECLARE @Closure'+direction+r"IndexName SYSNAME=N'([^']+)'",setup)[1]
    suffix=re.search(r'SET @Closure'+direction+r"IndexName=N'([^']+)'\+CONVERT",setup)[1]
    namequery=re.search(r'WHILE EXISTS\((SELECT .*?name=@Closure'+direction+r'IndexName)\)',setup)[1]
    expr=re.search(r'DECLARE @Closure'+direction+r"IndexSql NVARCHAR\(MAX\)=N'([^']*)'\s*\+QUOTENAME\(@Closure"+direction+r"IndexName\)\s*\+N'([^']*)';",setup)
    assert expr
    def add_index(name,keys,is_unique=False,**flags):
        i=db.execute('SELECT COALESCE(MAX(index_id),0)+1 FROM sys.indexes').fetchone()[0]
        db.execute('INSERT INTO sys.indexes VALUES(42,?,?,?,?,?,?,?,?)',
          (i,2,int(is_unique),flags.get('ignore_dup_key',0),flags.get('is_disabled',0),flags.get('has_filter',0),0,name))
        for ordinal,col in enumerate(keys,1): db.execute('INSERT INTO sys.index_columns VALUES(42,?,?,?)',(i,col,ordinal))
    def ensure():
        if db.execute(q,dict(ClosureObjectID=42)).fetchone(): return None
        name=base;n=0
        while db.execute(namequery,{'ClosureObjectID':42,'Closure'+direction+'IndexName':name}).fetchone():
            n+=1;name=suffix+str(n)
        rendered.append(expr[1]+'['+name+']'+expr[2])
        add_index(name,requiredkeys,unique)
        return name
    def reset():
        db.execute('DELETE FROM sys.indexes');db.execute('DELETE FROM sys.index_columns')
    reset();assert ensure()==base and ensure() is None
    for flags in ({},{'is_disabled':1},{'has_filter':1}):
        reset();add_index(base,[3],**flags);add_index(suffix+'1',[3]);add_index(suffix+'2',[3])
        before=db.execute('SELECT * FROM sys.indexes').fetchall()
        assert ensure()==suffix+'3'
        assert db.execute('SELECT * FROM sys.indexes ORDER BY index_id').fetchall()[:len(before)]==before
        assert ensure() is None # repeated load does not accumulate new indexes
    reset();add_index(base,[3]);add_index('ClientCompatibleName',requiredkeys,unique)
    assert ensure() is None # correct definition under another name wins
    reset();add_index(base,[3]);add_index(suffix+'1',requiredkeys,unique,is_disabled=1)
    assert ensure()==suffix+'2' and ensure() is None
Path('/tmp/upr-r10-index-ddl.sql').write_text('\nGO\n'.join(rendered))
print('PASS: R10 name collisions, occupied suffixes, compatible alternate names, disabled/filtered definitions, preservation and rerun reuse')
print('Rendered actual dynamic index DDL: /tmp/upr-r10-index-ddl.sql (for ScriptDom parsing)')

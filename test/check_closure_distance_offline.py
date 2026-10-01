#!/usr/bin/env python3
"""Run actual closure SELECTs in SQLite against an independent parent-chain oracle.

This checks relational calculations, not SQL Server batch compilation, locking,
triggers, transaction rollback or deployed API behavior. Run check_closure_levels.py
against SQL Server for those integration checks.
"""
from pathlib import Path
import sqlite3,re,random
ROOT=Path(__file__).resolve().parents[1]
loader=(ROOT/'scripts/load_upr_master.sql').read_text()
start=loader.index('INSERT INTO #ExpectedClosure (AncestorUPRID, DescendantUPRID, [Level])')
selects=re.findall(r'INSERT INTO #ExpectedClosure \(AncestorUPRID, DescendantUPRID, \[Level\]\)\s*(SELECT .*?);',loader[start:],re.S)[:2]
assert len(selects)==2
rng=random.Random(30)
parents={1:None}
for n in range(2,120):parents[n]=None if n%17==0 else rng.randrange(1,n)
parents.update({24:None,88787:24,88788:24,207074:88787,207075:88788,207076:24})
# Include a chain deeper than SQL Server's default recursive CTE limit.
for n in range(500000,500105):parents[n]=None if n==500000 else n-1
roots={};depths={};expected=set()
for child in parents:
 chain=[];node=child
 while node is not None:chain.append(node);node=parents[node]
 depths[child]=len(chain)-1;roots[child]=chain[-1]
 expected.update((a,child,step) for step,a in enumerate(chain))
db=sqlite3.connect(':memory:');db.execute("ATTACH ':memory:' AS dbo")
db.executescript('CREATE TABLE dbo.UPR(UPRID INTEGER PRIMARY KEY,ParentUPRID INTEGER); CREATE TABLE UPRLevels(UPRID INTEGER PRIMARY KEY,Level INTEGER); CREATE TABLE ExpectedClosure(AncestorUPRID INTEGER,DescendantUPRID INTEGER,Level INTEGER,PRIMARY KEY(AncestorUPRID,DescendantUPRID));')
db.executemany('INSERT INTO dbo.UPR VALUES(?,?)',parents.items());db.executemany('INSERT INTO UPRLevels VALUES(?,?)',depths.items())
for index,q in enumerate(selects):
 q=q.replace('#ExpectedClosure','ExpectedClosure').replace('#UPRLevels','UPRLevels')
 while True:
  rows=db.execute(q).fetchall()
  if not rows:break
  db.executemany('INSERT INTO ExpectedClosure VALUES(?,?,?)',rows)
  if index==0:break
assert set(db.execute('SELECT * FROM ExpectedClosure'))==expected
assert all(distance==0 for a,d,distance in expected if a==d)
print('PASS: actual loader closure SELECTs match independent parent-chain distances for',len(parents),'nodes and',len(expected),'paths')
# Existing report's actual dynamic SELECT must still show ancestor root depth.
s=(ROOT/'scripts/list_upr_ancestor_path.sql').read_text()
expr=s.split('DECLARE @SQL NVARCHAR(MAX) = ',1)[1].split('\n\nPRINT',1)[0].strip().removesuffix(';')
pat=re.compile(r"N'(?:[^']|'')*'|QUOTENAME\(@AncestryColumn\)|\+")
for col in ['AncestorUPRID','UPRAncestry']:
 parts=[];pos=0
 while pos<len(expr):
  if expr[pos].isspace():pos+=1;continue
  m=pat.match(expr,pos);assert m;tok=m[0];pos=m.end()
  if tok!='+':parts.append(tok[2:-1].replace("''","'") if tok.startswith("N'") else '['+col+']')
 sql=''.join(parts);q=sql[sql.index('SELECT node.[Level],'):]
 db.execute('DROP TABLE IF EXISTS dbo.UPR_CLOSURE');db.execute(f'CREATE TABLE dbo.UPR_CLOSURE({col} INTEGER,DescendantUPRID INTEGER,Level INTEGER,PRIMARY KEY({col},DescendantUPRID))')
 for semantics in ['old-depth','pair-distance']:
  db.execute('DELETE FROM dbo.UPR_CLOSURE')
  db.executemany('INSERT INTO dbo.UPR_CLOSURE VALUES(?,?,?)',[(a,d,depths[d] if semantics=='old-depth' else step) for a,d,step in expected])
  for child in parents:
   actual=db.execute(q,{'SelectedUPRID':child,'RootUPRID':roots[child]}).fetchall()
   want=sorted((depths[a],a,child) for a,d,_ in expected if d==child)
   assert actual==want,(semantics,col,child,actual,want)
  print('PASS: original root-depth report under',col,semantics)

# The standalone repair must calculate exactly the same paths as the loader.
repair=(ROOT/'scripts/repair_upr_closure_distance.sql').read_text()
seed=repair.index('INSERT INTO #ExpectedClosure (AncestorUPRID, DescendantUPRID, [Level])')
repair_selects=re.findall(r'INSERT INTO #ExpectedClosure \(AncestorUPRID, DescendantUPRID, \[Level\]\)\s*(SELECT .*?);',repair[seed:],re.S)[:2]
db.execute('CREATE TABLE HierarchyInput AS SELECT * FROM dbo.UPR')
db.execute('DELETE FROM ExpectedClosure')
for i,q in enumerate(repair_selects):
 while True:
  rows=db.execute(q.replace('#','')).fetchall()
  if not rows:break
  db.executemany('INSERT INTO ExpectedClosure VALUES(?,?,?)',rows)
  if i==0:break
assert set(db.execute('SELECT * FROM ExpectedClosure'))==expected
assert db.execute('SELECT Level,AncestorUPRID,DescendantUPRID FROM ExpectedClosure WHERE DescendantUPRID=207075 ORDER BY Level DESC').fetchall()==[(2,24,207075),(1,88788,207075),(0,207075,207075)]
print('PASS: repair SELECTs match loader and client 207075 example exactly')

# Execute the verification script's upward expansion and cycle predicate.
check=(ROOT/'test/check_upr_closure_distance.sql').read_text()
up=re.search(r'INSERT #ExpectedPaths\(AncestorUPRID,DescendantUPRID,\[Level\]\)\s*(SELECT .*?);',check,re.S)[1]
cycle=re.search(r'IF EXISTS\((SELECT 1 FROM #ExpectedPaths e.*?)\)\s*THROW',check,re.S)[1]
db.executescript('CREATE TABLE Parents(UPRID INTEGER PRIMARY KEY,ParentUPRID INTEGER); CREATE TABLE ExpectedPaths(AncestorUPRID INTEGER,DescendantUPRID INTEGER,Level INTEGER,PRIMARY KEY(AncestorUPRID,DescendantUPRID));')
def verify_upward(nodes):
 db.execute('DELETE FROM Parents');db.execute('DELETE FROM ExpectedPaths')
 db.executemany('INSERT INTO Parents VALUES(?,?)',nodes.items())
 db.execute('INSERT INTO ExpectedPaths SELECT UPRID,UPRID,0 FROM Parents')
 distance=0
 while True:
  if db.execute(cycle.replace('#',''),{'Distance':distance}).fetchone():
   raise ValueError('cycle')
  rows=db.execute(up.replace('#',''),{'Distance':distance}).fetchall()
  if not rows:break
  db.executemany('INSERT INTO ExpectedPaths VALUES(?,?,?)',rows)
  distance+=1
 return set(db.execute('SELECT * FROM ExpectedPaths'))
assert verify_upward(parents)==expected
for nodes in ({1:1},{1:2,2:1},{1:None,2:3,3:2,4:3}):
 try:verify_upward(nodes)
 except ValueError:pass
 else:raise AssertionError('Verifier missed a cycle')
print('PASS: independent upward verification agrees for all paths; self/multi-node cycles detected')

# Search/Property360 must preserve absolute node depth after self rows become 0.
db.execute('DROP TABLE dbo.UPR_CLOSURE')
db.execute('CREATE TABLE dbo.UPR_CLOSURE(AncestorUPRID INTEGER,DescendantUPRID INTEGER,Level INTEGER,PRIMARY KEY(AncestorUPRID,DescendantUPRID))')
db.executemany('INSERT INTO dbo.UPR_CLOSURE VALUES(?,?,?)',expected)
search=(ROOT/'scripts/search_upr_master.sql').read_text()
rootq=re.search(r'OUTER APPLY \((SELECT c\.\[Level\] AS RootLevel.*?)\) depth;',search,re.S)[1].replace('u.UPRID',':node')
for node in parents:
 assert db.execute(rootq,{'node':node}).fetchall()==[(depths[node],)]
# Two possible Property ancestors: the immediate one must win over the root.
db.executescript('ALTER TABLE dbo.UPR ADD COLUMN EntityTypeID INTEGER; CREATE TABLE dbo.REF_ENTITYTYPE(EntityTypeID INTEGER,Description TEXT); CREATE TABLE Allowed(UPRID INTEGER);')
db.execute("INSERT INTO dbo.REF_ENTITYTYPE VALUES(1,'Property')")
db.execute('UPDATE dbo.UPR SET EntityTypeID=1 WHERE UPRID IN (24,88788)')
db.executemany('INSERT INTO Allowed VALUES(?)',[(24,),(88788,),(207075,)])
nearest=re.search(r'OUTER APPLY \((SELECT TOP \(1\) au\.UPRID FROM dbo.UPR_CLOSURE cl.*?)\) anc',search,re.S)[1]
nearest=nearest.replace('TOP (1) ','').replace('#Allowed','Allowed').replace('e.UPRID',':node')+' LIMIT 1'
assert db.execute(nearest,{'node':207075}).fetchall()==[(88788,)]
db.execute('DELETE FROM Allowed WHERE UPRID=88788')
assert db.execute(nearest,{'node':207075}).fetchall()==[(24,)]
print('PASS: Property360 root levels and nearest authorized Property selection')

# Execute the repair's root walk to test refusal of unrooted parent input.
root_selects=re.findall(r'INSERT INTO #UPRLevels \(UPRID, \[Level\]\)\s*(SELECT .*?);',repair,re.S)
assert len(root_selects)==2
invalid=re.search(r'IF EXISTS \((SELECT 1 FROM\s+#HierarchyInput u.*?)\)\s*THROW',repair,re.S)[1]
for nodes,want_invalid in [(parents,False),({1:None,2:3,3:2},True),({1:None,2:99},True)]:
 db.execute('DELETE FROM HierarchyInput');db.execute('DELETE FROM UPRLevels')
 db.executemany('INSERT INTO HierarchyInput VALUES(?,?)',nodes.items())
 for i,q in enumerate(root_selects):
  while True:
   rows=db.execute(q.replace('#','')).fetchall()
   if not rows:break
   db.executemany('INSERT INTO UPRLevels VALUES(?,?)',rows)
   if i==0:break
 assert bool(db.execute(invalid.replace('#','')).fetchone())==want_invalid
print('PASS: repair root validation accepts rooted forest and rejects cycle/missing parent')

# Actual EXCEPT expressions gate repair before any writes when pairs differ.
pair_queries=re.findall(r'(SELECT AncestorUPRID,DescendantUPRID FROM #[A-Za-z]+\s+EXCEPT SELECT AncestorUPRID,DescendantUPRID FROM #[A-Za-z]+)',repair)
assert len(pair_queries)==2
db.execute('CREATE TABLE ClosureSnapshot AS SELECT * FROM ExpectedClosure')
def mismatched_pairs():
 return any(db.execute(q.replace('#','')).fetchone() for q in pair_queries)
assert not mismatched_pairs()
db.execute('DELETE FROM ClosureSnapshot WHERE AncestorUPRID=88788 AND DescendantUPRID=207075')
assert mismatched_pairs()
db.execute('INSERT INTO ClosureSnapshot VALUES(88788,207075,1)')
db.execute('INSERT INTO ClosureSnapshot VALUES(207075,24,2)')
assert mismatched_pairs()
print('PASS: repair rejects missing or extra relationship pairs')

#!/usr/bin/env python3
"""
Schema contract check for the hierarchical UPR scripts.

Parses ddl/03_new_upr_schema.sql for real table definitions and verifies that
every INSERT / MERGE in scripts/load_upr_master.sql:

  * targets a table that exists in the DDL
  * only names columns that exist on that table
  * supplies every NOT NULL column that has no DEFAULT
  * matches column count to value/select count where countable

Also checks temp tables: every INSERT INTO #t (cols) and OUTPUT ... INTO #t (cols)
names columns that the CREATE TABLE #t declares, with matching counts.

Catches the class of errors that only surface at run time on the client's server.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DDL = (ROOT / "ddl/03_new_upr_schema.sql").read_text(encoding="utf-8")
LOAD = (ROOT / "scripts/load_upr_master.sql").read_text(encoding="utf-8")

failures = []
notes = []


def fail(msg):
    failures.append(msg)


def strip_comments(sql: str) -> str:
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", " ", sql)
    return sql


DDL_NC = strip_comments(DDL)
LOAD_NC = strip_comments(LOAD)

CONSTRAINT_START = re.compile(
    r"^\s*(CONSTRAINT|PRIMARY\s+KEY|UNIQUE|FOREIGN\s+KEY|CHECK|INDEX)\b", re.I
)


def split_top_level(body: str):
    """Split a CREATE TABLE body on commas that are not inside parentheses."""
    parts, depth, cur = [], 0, []
    for ch in body:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def parse_tables(sql: str, prefix="dbo."):
    """Return {table_lower: {col_lower: {'notnull':bool,'default':bool,'identity':bool}}}"""
    tables = {}
    opt_prefix = "(?:" + re.escape(prefix) + ")?" if prefix else ""
    pat = re.compile(
        r"CREATE\s+TABLE\s+(" + opt_prefix + r"[#\w.]+)\s*\((.*?)\)\s*;",
        re.I | re.S,
    )
    for m in pat.finditer(sql):
        name = m.group(1).lower()
        if name.startswith("dbo."):
            name = name[4:]
        cols = {}
        for part in split_top_level(m.group(2)):
            part = part.strip()
            if not part or CONSTRAINT_START.match(part):
                continue
            cm = re.match(r"[\[\s]*([A-Za-z_]\w*)[\]\s]", part + " ")
            if not cm:
                continue
            col = cm.group(1).lower()
            upper = part.upper()
            cols[col] = {
                "notnull": " NOT NULL" in upper,
                "default": "DEFAULT" in upper,
                "identity": "IDENTITY" in upper,
            }
        tables[name] = cols
    return tables


real_tables = parse_tables(DDL_NC)
temp_tables = parse_tables(LOAD_NC, prefix="")
temp_tables = {k: v for k, v in temp_tables.items() if k.startswith("#")}

# SELECT INTO #temp tables have no CREATE TABLE - collect their names so we
# do not report them as unknown.
select_into = {
    m.group(1).lower() for m in re.finditer(r"\bINTO\s+(#\w+)\s", LOAD_NC, re.I)
}

print("=" * 60)
print("  SCHEMA CONTRACT CHECK")
print("=" * 60)
print(f"  DDL tables parsed        : {len(real_tables)}")
print(f"  Temp tables declared     : {len(temp_tables)}")

if len(real_tables) < 20:
    fail(f"only parsed {len(real_tables)} DDL tables - parser or DDL problem")

# ---------------------------------------------------------------- INSERT check
insert_pat = re.compile(
    r"INSERT\s+INTO\s+(dbo\.\w+|#\w+)\s*\(([^;]*?)\)\s*(VALUES|SELECT)", re.I | re.S
)
checked = 0
for m in insert_pat.finditer(LOAD_NC):
    target = m.group(1).lower()
    collist = m.group(2)
    if "(" in collist:  # not a plain column list
        continue
    cols = [c.strip().strip("[]").lower() for c in collist.split(",") if c.strip()]
    tname = target[4:] if target.startswith("dbo.") else target
    table = real_tables.get(tname) or temp_tables.get(tname)
    if table is None:
        if tname.startswith("#") and tname in select_into:
            continue
        fail(f"INSERT targets unknown table {target}")
        continue
    checked += 1
    for c in cols:
        if c not in table:
            fail(f"INSERT INTO {target}: column '{c}' not in table definition")
    if target.startswith("dbo."):
        missing = [
            c
            for c, meta in table.items()
            if meta["notnull"]
            and not meta["default"]
            and not meta["identity"]
            and c not in cols
        ]
        if missing:
            fail(
                f"INSERT INTO {target}: NOT NULL column(s) with no default not "
                f"supplied: {', '.join(missing)}"
            )

print(f"  INSERT statements checked: {checked}")

# ----------------------------------------------------------------- MERGE check
merge_pat = re.compile(
    r"MERGE\s+(dbo\.\w+)\s+AS\s+t\b.*?WHEN\s+NOT\s+MATCHED\s+THEN\s*INSERT\s*\(([^)]*)\)",
    re.I | re.S,
)
merges = 0
for m in merge_pat.finditer(LOAD_NC):
    tname = m.group(1).lower()[4:]
    cols = [c.strip().strip("[]").lower() for c in m.group(2).split(",") if c.strip()]
    table = real_tables.get(tname)
    if table is None:
        fail(f"MERGE targets unknown table dbo.{tname}")
        continue
    merges += 1
    for c in cols:
        if c not in table:
            fail(f"MERGE dbo.{tname}: column '{c}' not in table definition")
    missing = [
        c
        for c, meta in table.items()
        if meta["notnull"]
        and not meta["default"]
        and not meta["identity"]
        and c not in cols
    ]
    if missing:
        fail(
            f"MERGE dbo.{tname}: NOT NULL column(s) with no default not "
            f"supplied: {', '.join(missing)}"
        )
print(f"  MERGE statements checked : {merges}")

# ---------------------------------------------------- OUTPUT ... INTO #t (cols)
out_pat = re.compile(r"OUTPUT\s+(.*?)\s+INTO\s+(#\w+)\s*\(([^)]*)\)", re.I | re.S)
outs = 0
for m in out_pat.finditer(LOAD_NC):
    src = [c.strip() for c in m.group(1).split(",") if c.strip()]
    tname = m.group(2).lower()
    dest = [c.strip().strip("[]").lower() for c in m.group(3).split(",") if c.strip()]
    table = temp_tables.get(tname)
    outs += 1
    if len(src) != len(dest):
        fail(f"OUTPUT INTO {tname}: {len(src)} output columns vs {len(dest)} targets")
    if table is None:
        fail(f"OUTPUT INTO {tname}: temp table has no CREATE TABLE")
        continue
    for c in dest:
        if c not in table:
            fail(f"OUTPUT INTO {tname}: column '{c}' not declared")
    missing = [c for c, meta in table.items() if meta["notnull"] and not meta["default"]
               and not meta["identity"] and c not in dest]
    if missing:
        fail(f"OUTPUT INTO {tname}: NOT NULL column(s) not populated: {', '.join(missing)}")
print(f"  OUTPUT INTO checked      : {outs}")

# ------------------------------------------------ INSERT ... SELECT arity check
arity_pat = re.compile(
    r"INSERT\s+INTO\s+(dbo\.\w+|#\w+)\s*\(([^()]*?)\)\s*VALUES\s*\((.*?)\)\s*;",
    re.I | re.S,
)
for m in arity_pat.finditer(LOAD_NC):
    if re.search(r"\)\s*,\s*\(", m.group(3)):
        continue  # multi-row VALUES list
    cols = [c for c in m.group(2).split(",") if c.strip()]
    vals = split_top_level(m.group(3))
    if len(cols) != len(vals):
        fail(
            f"INSERT INTO {m.group(1)} VALUES: {len(cols)} columns vs {len(vals)} values"
        )

# --------------------------------------------- INSERT ... SELECT arity check
def find_depth0_from(sql: str, start: int):
    """Index of the first FROM at paren depth 0, or -1."""
    depth = 0
    i = start
    while i < len(sql):
        c = sql[i]
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                return -1
            depth -= 1
        elif depth == 0 and sql[i : i + 4].upper() == "FROM" and (
            i == 0 or not sql[i - 1].isalnum()
        ) and not sql[i + 4 : i + 5].isalnum():
            return i
        i += 1
    return -1


sel_pat = re.compile(r"INSERT\s+INTO\s+(dbo\.\w+|#\w+)\s*\(([^()]*?)\)\s*SELECT\b", re.I | re.S)
arity_checked = 0
for m in sel_pat.finditer(LOAD_NC):
    cols = [c for c in m.group(2).split(",") if c.strip()]
    end = find_depth0_from(LOAD_NC, m.end())
    if end == -1:
        continue
    sel_list = LOAD_NC[m.end() : end]
    if re.search(r"\bDISTINCT\b|\bTOP\b", sel_list, re.I):
        sel_list = re.sub(r"^\s*(DISTINCT|TOP\s*\(?\d+\)?)\s*", " ", sel_list, flags=re.I)
    items = [p for p in split_top_level(sel_list) if p.strip()]
    arity_checked += 1
    if len(cols) != len(items):
        fail(
            f"INSERT INTO {m.group(1)}: {len(cols)} columns vs {len(items)} "
            f"selected expressions"
        )
print(f"  INSERT..SELECT arity     : {arity_checked}")

# --------------------------------------------------------- structural sanity
def count_kw(sql, kw):
    return len(re.findall(r"\b" + kw + r"\b", sql, re.I))


if count_kw(LOAD_NC, "BEGIN TRY") != count_kw(LOAD_NC, "END TRY"):
    fail("BEGIN TRY / END TRY not balanced")
if count_kw(LOAD_NC, "BEGIN CATCH") != count_kw(LOAD_NC, "END CATCH"):
    fail("BEGIN CATCH / END CATCH not balanced")
if count_kw(LOAD_NC, "BEGIN TRANSACTION") != 1:
    fail("expected exactly one BEGIN TRANSACTION")
if count_kw(LOAD_NC, "COMMIT TRANSACTION") != 1:
    fail("expected exactly one COMMIT TRANSACTION")

# every #temp referenced must be created or SELECT INTO'd first
declared = set(temp_tables) | set(select_into)
for m in re.finditer(r"(#\w+)", LOAD_NC):
    t = m.group(1).lower()
    if t not in declared:
        fail(f"temp table {t} used but never created")
        break

# CondoUnit must be added in a batch before the batch that reads it
alter_pos = LOAD_NC.upper().find("ADD CONDOUNIT")
read_pos = LOAD_NC.find("s.CondoUnit")
if alter_pos == -1:
    fail("no ALTER TABLE ... ADD CondoUnit safeguard")
elif read_pos != -1:
    between = LOAD_NC[alter_pos:read_pos]
    if not re.search(r"^\s*GO\s*$", between, re.M):
        fail("ALTER TABLE ADD CondoUnit is in the same batch that reads it (needs GO)")

# no index key wider than 900 bytes on a clustered/PK temp column
for tname, cols in temp_tables.items():
    for col, meta in cols.items():
        pass
for m in re.finditer(r"(\w+)\s+NVARCHAR\((\d+)\)\s+NOT NULL\s+PRIMARY KEY", LOAD_NC, re.I):
    if int(m.group(2)) * 2 > 900:
        fail(
            f"temp PRIMARY KEY column {m.group(1)} NVARCHAR({m.group(2)}) exceeds "
            f"900-byte clustered index limit"
        )

# non-ascii would garble under sqlcmd default codepage
for f in ["ddl/03_new_upr_schema.sql", "scripts/load_upr_master.sql",
          "scripts/search_upr_master.sql"]:
    txt = (ROOT / f).read_text(encoding="utf-8")
    bad = sorted({c for c in txt if ord(c) > 127})
    if bad:
        fail(f"{f} contains non-ASCII characters: {bad}")

print("-" * 60)
if failures:
    for f in failures:
        print(f"  FAIL  {f}")
    print("=" * 60)
    print(f"SCHEMA CONTRACT CHECK: {len(failures)} PROBLEM(S)")
    sys.exit(1)
for n in notes:
    print(f"  NOTE  {n}")
print("=" * 60)
print("SCHEMA CONTRACT CHECK: ALL PASSED")

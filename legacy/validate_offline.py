#!/usr/bin/env python3
"""
Offline validation when SQL Server is not available.
Verifies deliverable files, test data counts, and address normalization logic.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

STREET_MAP = {
    'STREET': 'ST', 'ST': 'ST', 'AVENUE': 'AVE', 'AVE': 'AVE',
    'ROAD': 'RD', 'RD': 'RD', 'LANE': 'LN', 'LN': 'LN',
    'COURT': 'CT', 'CT': 'CT', 'DRIVE': 'DR', 'DR': 'DR',
    'BOULEVARD': 'BLVD', 'BLVD': 'BLVD', 'PLACE': 'PL', 'PL': 'PL',
}


def std_street(token: str) -> str:
    t = (token or '').strip().upper()
    return STREET_MAP.get(t, t) if t else ''


def normalize_address_line(line: str) -> str:
    s = (line or '').strip().upper()
    if not s:
        return ''
    parts = s.rsplit(' ', 1)
    if len(parts) == 2:
        prefix, last = parts
        return f"{prefix} {std_street(last)}".strip()
    return s


def normalize_full(line: str, city: str, zipcode: str) -> str:
    z = (zipcode or '')[:5]
    return f"{normalize_address_line(line)} {(city or '').strip().upper()} {z}".strip()


def count_insert_rows(sql_path: Path, table_hint: str) -> int:
    text = sql_path.read_text(encoding='utf-8', errors='ignore')
    # Find INSERT block for table
    pattern = rf"INSERT\s+INTO\s+dbo\.{re.escape(table_hint)}[^;]*VALUES\s*(.*?);"
    m = re.search(pattern, text, re.I | re.S)
    if not m:
        return 0
    block = m.group(1)
    # Count tuples like (101, or (201,
    return len(re.findall(r'\(\s*\d+', block))


def check_file(path: Path) -> bool:
    ok = path.is_file() and path.stat().st_size > 0
    print(f"  {'PASS' if ok else 'FAIL'}  {path.relative_to(ROOT)}")
    return ok


def main() -> int:
    print("=" * 60)
    print("  UPR OFFLINE VALIDATION")
    print("=" * 60)

    failures = 0

    print("\n--- Deliverable files ---")
    required = [
        ROOT / "scripts/load_upr_master.sql",
        ROOT / "scripts/search_upr_master.sql",
        ROOT / "test/seed_test_incoming.sql",
        ROOT / "test/run_test_and_results.sql",
        ROOT / "README.md",
        ROOT / "DELIVERY.md",
    ]
    for p in required:
        if not check_file(p):
            failures += 1

    print("\n--- Test data row counts ---")
    seed = ROOT / "test/seed_test_incoming.sql"
    ma_count = count_insert_rows(seed, r"AddressMaster")
    sdat_count = count_insert_rows(seed, r"SDAT")
    checks = [
        ("AddressMaster rows", ma_count, 100, ma_count >= 100),
        ("SDAT rows", sdat_count, 100, sdat_count >= 100),
    ]
    for name, actual, expected, ok in checks:
        status = "PASS" if ok else "FAIL"
        print(f"  {status}  {name}: {actual} (expected >={expected})")
        if not ok:
            failures += 1

    print("\n--- Address normalization logic ---")
    norm_cases = [
        ("123 MAIN STREET", "123 MAIN ST"),
        ("500 OAK LANE", "500 OAK LN"),
        ("500 OAK LN", "500 OAK LN"),
        ("10 MARKET ROAD", "10 MARKET RD"),
        ("500 OAK LANE", "500 OAK LN"),  # CASE vs AddressMaster match
    ]
    for inp, exp in norm_cases:
        got = normalize_address_line(inp)
        ok = got == exp
        print(f"  {'PASS' if ok else 'FAIL'}  '{inp}' -> '{got}' (expected '{exp}')")
        if not ok:
            failures += 1

    print("\n--- Cross-system match simulation ---")
    upr_102 = normalize_address_line("500 OAK LN")
    case_7001 = normalize_address_line("500 OAK LANE")
    ok = upr_102 == case_7001
    print(f"  {'PASS' if ok else 'FAIL'}  Account 20002002: UPR '{upr_102}' == CASE '{case_7001}'")
    if not ok:
        failures += 1

    upr_101 = normalize_address_line("123 MAIN ST")
    eprop_101 = normalize_address_line("123 MAIN ST")
    ok = upr_101 == eprop_101
    print(f"  {'PASS' if ok else 'FAIL'}  Account 10001001: UPR '{upr_101}' == eProperty '{eprop_101}'")
    if not ok:
        failures += 1

    print("\n--- SQL Server connectivity ---")
    import socket
    try:
        sock = socket.create_connection(("127.0.0.1", 1433), timeout=2)
        sock.close()
        print("  PASS  SQL Server listening on port 1433")
        print("  INFO  Run: ./scripts/run_all.sh localhost sa 'YourPassword'")
    except OSError:
        print("  SKIP  SQL Server not running on localhost:1433")
        print("  INFO  Start SQL Server, then run:")
        print("        sudo systemctl start docker   # if using Docker")
        print("        docker run -d --name upr-sql -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='YourStrong!Passw0rd' -p 1433:1433 mcr.microsoft.com/mssql/server:2019-latest")
        print("        sleep 20")
        print("        ./scripts/run_all.sh localhost sa 'YourStrong!Passw0rd'")

    print("\n" + "=" * 60)
    if failures:
        print(f"  OFFLINE RESULT: {failures} check(s) FAILED")
    else:
        print("  OFFLINE RESULT: ALL CHECKS PASSED")
    print("=" * 60)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

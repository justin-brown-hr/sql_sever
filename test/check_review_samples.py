#!/usr/bin/env python3
"""R15: the client's 'valid records in Review' samples load (SQL Server, client layout 11/17/2026).

Fixture test/client_review_samples.sql copies the document rows. Each SDAT sample's
MA side exercises one SDAT_MA_MATCH tier. CONTAINER defaults to uprtest.
"""
import os
import re
import subprocess
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = os.environ.get('CONTAINER', 'uprtest')
LOADER = (ROOT / 'scripts/load_upr_master.sql').read_text()
CREATED = []


def sql(database, text, error=False):
    result = subprocess.run(
        ['docker', 'exec', '-i', CONTAINER, 'bash', '-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa '
         '-P "$MSSQL_SA_PASSWORD" -C -b -W -s "|" -h -1 -w 65535'],
        input=f'USE [{database}];\nGO\nSET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;\n' + text,
        text=True, capture_output=True)
    output = result.stdout + result.stderr
    if (result.returncode != 0) != error:
        raise AssertionError(output[-7000:])
    return '\n'.join(x for x in output.splitlines()
                     if x.strip() and not x.startswith('Changed database context to'))


def new_database(label):
    database = f'UPR_{label}_IT_' + uuid.uuid4().hex
    sql('master', f'CREATE DATABASE [{database}];')
    CREATED.append(database)
    for script in ('test/local_it_setup.sql', 'ddl/03_new_upr_schema.sql', 'test/client_review_samples.sql'):
        sql(database, (ROOT / script).read_text().replace('UPRXDB_TEST', database))
    return database


def load(database, loader=LOADER):
    return sql(database, loader.replace('UPRXDB_TEST', database))


PLACED = """
SELECT CONVERT(VARCHAR(20), x.IdentifierValue) + '|' + et.Description + '|' + rt.Description + '|'
    + root.AccountNumber + '|' + ISNULL(a.NormalizedAddress, '-') + '|' + ISNULL(un.UnitNumber, '-')
FROM dbo.EXTERNAL_IDENTIFIER_XREF x
JOIN dbo.UPR u ON u.UPRID = x.UPRID
JOIN dbo.REF_ENTITYTYPE et ON et.EntityTypeID = u.EntityTypeID
CROSS APPLY (SELECT TOP 1 r.AccountNumber, r.EntityTypeID FROM dbo.UPR_CLOSURE c JOIN dbo.UPR r
    ON r.UPRID = c.AncestorUPRID WHERE c.DescendantUPRID = u.UPRID AND r.ParentUPRID IS NULL) root
JOIN dbo.REF_ENTITYTYPE rt ON rt.EntityTypeID = root.EntityTypeID
OUTER APPLY (SELECT TOP 1 ad.NormalizedAddress FROM dbo.UPR_ADDRESS ua JOIN dbo.ADDRESS ad
    ON ad.AddressID = ua.AddressID WHERE ua.UPRID = u.UPRID ORDER BY ua.PrimaryInd DESC) a
LEFT JOIN dbo.UNIT un ON un.UPRID = u.UPRID
WHERE x.IdentifierType = 'SOURCE_RECORD_ID' AND x.IdentifierValue IN ({ids})
ORDER BY x.IdentifierValue;"""
SDAT_IDS = ('1348', '1352', '1402', '1426', '1500', '1501', '1502')
SHOP_IDS = ('106862', '109562', '171725', '216016', '312950', '433210')


def placed(database, ids):
    return dict(line.split('|', 1) for line in
                sql(database, PLACED.format(ids=','.join(f"'{i}'" for i in ids))).splitlines())


try:
    db = new_database('ReviewSamples')
    output = load(db)
    assert 'UPR MAIN LOADER 2026-11-19 R15' in output and 'Record layout check passed.' in output, output[-3000:]
    sdat = placed(db, SDAT_IDS)
    assert sdat == {
        '1348': 'Property|Property|00016905|13601 W OLD BALTIMORE RD BOYDS 20841|-',
        '1352': 'Property|Property|00016984|22518 SCHOOL FIELD CT CLARKSBURG 20871|-',
        '1402': 'Property|Property|00017580|23200 SHILOH CHURCH RD BOYDS 20841|-',
        '1426': 'Property|Property|00017886|13123 SUNCREST AVE CLARKSBURG 20871|-',
        '1500': 'Property|Property|00227620|2308 MCAULIFFE DR ROCKVILLE 20851|-',
        '1501': 'Property|Property|00018001|300 THIRD ST BOYDS 20841|-',
        '1502': 'Unit|Condo|00019999|400 FOURTH ST BOYDS 20841|-'}, sdat
    # STREET_SPELLING / ACCOUNT_ONLY rows share the MA Property, not a second root.
    for account in ('00016905', '00016984', '00017580', '00227620'):
        assert sql(db, f"SELECT COUNT(*) FROM dbo.UPR WHERE ParentUPRID IS NULL AND AccountNumber = '{account}';") == '1', account
    for method, ids in (('STREET_SPELLING', ('1348', '1352', '1500')), ('ACCOUNT_ONLY', ('1402',)),
                        ('OWN_PROPERTY', ('1501',))):
        for i in ids:
            assert re.search(rf'^KDAT\|{i}\|\d+\|{method}\|', output, re.M), (method, i)
    print('PASS: SDAT samples with an MA account load (exact, spelling/direction, account-only, own Property)', flush=True)

    assert sql(db, "SELECT COUNT(*) FROM dbo.UPRMATCHREVIEW_Q WHERE COALESCE(SDAT_AccountNumber, MA_Account) IN "
               "('00017886','00016905','00016984','00017580','00227620','00018001','00019999','01876952','00142855');") == '0'
    assert sql(db, "SELECT COUNT(*) FROM dbo.UNIT WHERE UnitNumber = 'NULL';") == '0', "CondoUnit text 'NULL' became a unit"
    print("PASS: no sample is in Review_Q; CondoUnit text 'NULL' is no unit number", flush=True)

    shops = placed(db, SHOP_IDS)
    assert sorted(v.split('|')[3] for v in shops.values()) == [
        '822 ROCKVILLE PIKE ROCKVILLE 20851', '822-A ROCKVILLE PIKE ROCKVILLE 20852',
        '822-B ROCKVILLE PIKE ROCKVILLE 20851', '822-C ROCKVILLE PIKE ROCKVILLE 20851',
        '822-D ROCKVILLE PIKE ROCKVILLE 20851', '822-H ROCKVILLE PIKE ROCKVILLE 20851'], shops
    assert placed(db, ('160719', '190001')) == {
        '160719': 'Property|Property|00227620|2308 MCAULIFFE DR ROCKVILLE 20851|-',
        '190001': 'Property|Property|01876952|18900 MCFARLIN DR GERMANTOWN 20874|-'}
    print('PASS: MA StreetSuffix keeps 822-A..822-H as distinct addresses; MA single-family samples load', flush=True)

    # Review detail grid: only genuinely invalid rows, each with its source record ID.
    detail = re.findall(r'^(ADDRESS_MASTER|KDAT)\|(\d+)\|[^|]*\|(INSUFFICIENT_DATA|NO_ADDRESS_MATCH|AMBIGUOUS_CANDIDATES)\|([^|]*)\|',
                        output, re.M)
    assert detail and all(d[3].startswith('Rejected:') or 'more than one MA parent' in d[3] for d in detail), detail
    assert not {d[1] for d in detail} & set(SDAT_IDS + SHOP_IDS + ('160719', '190001')), detail
    rerun = load(db)
    for metric in ('UPR rows inserted', 'UPR rows updated', 'UPR rows deleted', 'Review_Q inserted'):
        assert re.search(rf'^{metric} +: 0$', rerun, re.M), (metric, rerun[-2000:])
    assert placed(db, SDAT_IDS) == sdat
    print('PASS: review detail lists only invalid rows with source IDs; unchanged rerun writes nothing', flush=True)

    # Pending client decision: SDAT-only rows without CondoUnit as Property.
    alt = new_database('ReviewSamplesProperty')
    load(alt, LOADER.replace("DECLARE @SdatOnlyWithoutCondoUnit NVARCHAR(10) = N'CONDO';",
                             "DECLARE @SdatOnlyWithoutCondoUnit NVARCHAR(10) = N'PROPERTY';"))
    assert placed(alt, ('1502',))['1502'].split('|')[:2] == ['Property', 'Property'], placed(alt, ('1502',))
    assert placed(alt, SDAT_IDS[:-1]) == {k: v for k, v in sdat.items() if k != '1502'}
    print('PASS: @SdatOnlyWithoutCondoUnit = PROPERTY loads SDAT-only rows without CondoUnit as Properties', flush=True)
finally:
    for database in CREATED:
        sql('master', f"ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
            f"DROP DATABASE [{database}];")

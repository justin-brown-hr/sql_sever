#!/usr/bin/env python3
"""Execute R10's actual early index setup on a disposable SQL Server database.
Requires the SQL Server container used by run_local_it.sh. Not an offline test.
"""
import os
from pathlib import Path
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]
CONTAINER=os.environ.get('CONTAINER','uprtest')
DATABASE='UPR_Index_IT_'+uuid.uuid4().hex
source=(ROOT/'scripts/load_upr_master.sql').read_text()
block=source[source.index("DECLARE @ClosureObjectID INT=OBJECT_ID(N'dbo.UPR_CLOSURE');"):
             source.index('/* CLOSURE_INDEX_SETUP_END */')]

def sql(text,error=False,master=False):
    cmd=['docker','exec','-i',CONTAINER,'bash','-lc',
         'exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -W -h -1 -s "|"']
    out=subprocess.run(cmd,input=('USE master;' if master else f'USE [{DATABASE}];')+
        '\nGO\nSET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET NOCOUNT ON;\n'+text,
        text=True,capture_output=True)
    assert bool(out.returncode)==error,(out.stdout+out.stderr)[-5000:]
    return '\n'.join(l for l in (out.stdout+out.stderr).splitlines() if l.strip() and not l.startswith('Changed database'))

def setup(rollback=False,error=False):
    return sql('SET XACT_ABORT ON; BEGIN TRY BEGIN TRANSACTION;\n'+block+
        ('\nROLLBACK TRANSACTION;' if rollback else '\nCOMMIT TRANSACTION;')+
        '\nEND TRY BEGIN CATCH IF @@TRANCOUNT>0 ROLLBACK TRANSACTION; THROW; END CATCH;',error=error)

def names():
    return sql("SELECT name FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.UPR_CLOSURE') AND index_id>0 ORDER BY name;")

sql(f'CREATE DATABASE [{DATABASE}];',master=True)
try:
    for existing in ('none','legacy','occupied_suffix','disabled','filtered','compatible_alternate',
                     'client_2026_11','include_only'):
        sql('DROP TABLE IF EXISTS dbo.UPR_CLOSURE; CREATE TABLE dbo.UPR_CLOSURE('
            'AncestorUPRID BIGINT NOT NULL,DescendantUPRID BIGINT NOT NULL,[Level] INT NULL);'
            'INSERT dbo.UPR_CLOSURE VALUES(24,24,0),(24,88788,1),(88788,88788,0);')
        if existing not in ('none','client_2026_11','include_only'):
            sql('CREATE INDEX IX_UPR_CLOSURE_Descendant ON dbo.UPR_CLOSURE(DescendantUPRID);'
                'CREATE INDEX UX_UPR_CLOSURE_AncestorDescendant ON dbo.UPR_CLOSURE(AncestorUPRID);')
        if existing=='occupied_suffix':
            sql('CREATE INDEX IX_UPR_CLOSURE_Descendant_Loader1 ON dbo.UPR_CLOSURE([Level]);'
                'CREATE INDEX UX_UPR_CLOSURE_AncestorDescendant_Loader1 ON dbo.UPR_CLOSURE([Level]);')
        if existing=='disabled':
            sql('CREATE INDEX IX_UPR_CLOSURE_Descendant_Loader1 ON dbo.UPR_CLOSURE(DescendantUPRID,AncestorUPRID);'
                'ALTER INDEX IX_UPR_CLOSURE_Descendant_Loader1 ON dbo.UPR_CLOSURE DISABLE;')
        if existing=='filtered':
            sql('CREATE INDEX IX_UPR_CLOSURE_Descendant_Loader1 ON dbo.UPR_CLOSURE(DescendantUPRID,AncestorUPRID) WHERE [Level]>0;')
        if existing=='compatible_alternate':
            sql('ALTER TABLE dbo.UPR_CLOSURE ADD CONSTRAINT ClientPair PRIMARY KEY(AncestorUPRID,DescendantUPRID);'
                'CREATE INDEX ClientReverse ON dbo.UPR_CLOSURE(DescendantUPRID,AncestorUPRID);')
        if existing=='client_2026_11':
            # Exact index set of the client's November 6 2026 UPR_CLOSURE layout.
            sql('ALTER TABLE dbo.UPR_CLOSURE ADD CONSTRAINT PK_UPR_CLOSURE PRIMARY KEY CLUSTERED(AncestorUPRID,DescendantUPRID);'
                'CREATE INDEX IX_UPR_CLOSURE_Ancestor ON dbo.UPR_CLOSURE(AncestorUPRID,[Level],DescendantUPRID);'
                'CREATE INDEX IX_UPR_CLOSURE_Descendant ON dbo.UPR_CLOSURE(DescendantUPRID,[Level],AncestorUPRID);'
                'CREATE UNIQUE INDEX UX_UPR_CLOSURE_Ancestor_Descendant ON dbo.UPR_CLOSURE(AncestorUPRID,DescendantUPRID);')
        if existing=='include_only':
            sql('ALTER TABLE dbo.UPR_CLOSURE ADD CONSTRAINT ClientPair PRIMARY KEY(AncestorUPRID,DescendantUPRID);'
                'CREATE INDEX ClientReverse ON dbo.UPR_CLOSURE(DescendantUPRID) INCLUDE(AncestorUPRID);')
        before=names()
        setup(rollback=True)
        assert names()==before,'Failed rollback of added indexes'
        setup();after=names();setup();assert names()==after,'Rerun accumulated indexes'
        assert set(before.splitlines())<=set(after.splitlines()),'Existing index removed'
        if existing in ('compatible_alternate','client_2026_11','include_only'):assert after==before,(existing,after)
        elif existing=='none':assert len(after.splitlines())==2
        else:
            assert len(after.splitlines())==len(before.splitlines())+2
            assert sql("SELECT key_ordinal FROM sys.index_columns WHERE object_id=OBJECT_ID('dbo.UPR_CLOSURE') AND index_id=(SELECT index_id FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.UPR_CLOSURE') AND name='IX_UPR_CLOSURE_Descendant') AND key_ordinal>0;")=='1'
        assert '1'==sql("SELECT is_nullable FROM sys.columns WHERE object_id=OBJECT_ID('dbo.UPR_CLOSURE') AND name='Level';")
        assert '3'==sql('SELECT COUNT(*) FROM dbo.UPR_CLOSURE;')
        sql('INSERT dbo.UPR_CLOSURE VALUES(24,88788,99);',error=True)
        print('PASS: actual SQL Server index setup:',existing)
    sql('DROP TABLE dbo.UPR_CLOSURE; CREATE TABLE dbo.UPR_CLOSURE(AncestorUPRID BIGINT,DescendantUPRID BIGINT,[Level] INT);'
        'INSERT dbo.UPR_CLOSURE VALUES(24,24,0),(24,24,1);')
    assert 'duplicate ancestor/descendant pairs' in setup(error=True)
    assert names()==''
    print('PASS: duplicates still rejected before index creation')
finally:
    sql(f'ALTER DATABASE [{DATABASE}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{DATABASE}];',master=True)

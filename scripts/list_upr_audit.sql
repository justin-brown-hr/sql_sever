/*
  Row-change report. Run after install_upr_audit.sql; safe on existing data.
  Opening this file shows the latest run without field expansion.
  The procedure supports retained history and edits outside loads with filters.
  Change the EXEC parameters at the bottom to select one run/table/date range.
  Result sets: load runs, changed rows, individual changed fields.
  Old audit rows retain their original values; unknown run/session stays NULL.
  RecordKey displays the stored key as labelled values by default.
  @RawRecordKey = 1 restores the previous JSON display. No stored key is changed.
  EntityID identifies the table; EntityRecordID identifies its audited record.
  Composite/text keys use an internal negative registry ID, not a negative UPRID.
  Field details require database compatibility level 130 or later (OPENJSON).
*/
USE UPRXDB_TEST;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UPR_AuditReport
    @RunID UNIQUEIDENTIFIER = NULL,
    @LatestRun BIT = 0,
    @TableName NVARCHAR(100) = NULL,
    @Since DATETIME2(3) = NULL,
    @Until DATETIME2(3) = NULL, -- exclusive
    @IncludeFieldDetails BIT = 1,
    @UPRID BIGINT = NULL,
    @EntityID INT = NULL,
    @RawRecordKey BIT = 0 -- append-only option: 1 preserves the previous key display
AS
BEGIN
    SET NOCOUNT ON;
    IF @Since IS NOT NULL AND @Until IS NOT NULL AND @Since >= @Until
        THROW 50001, '@Until must be later than @Since.', 1;
    IF @LatestRun = 1 AND @RunID IS NULL
    BEGIN
        SELECT TOP (1) @RunID = RunID FROM dbo.UPR_LOAD_RUN
        ORDER BY StartedAt DESC, RunID;
        IF @RunID IS NULL
        BEGIN
            PRINT N'No load runs recorded yet. Use @LatestRun = 0 to see edits outside loads.';
            RETURN;
        END;
    END;

    /* Resolve the entity name once; event filters use integer IDs. */
    IF @TableName IS NOT NULL
    BEGIN
        DECLARE @NamedEntityID INT = (SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName = @TableName);
        IF @NamedEntityID IS NULL OR (@EntityID IS NOT NULL AND @EntityID <> @NamedEntityID)
            SET @EntityID = -1;
        ELSE SET @EntityID = @NamedEntityID;
    END;
    DECLARE @SummaryEntityID INT = (SELECT EntityID FROM dbo.REF_ENTITY_IDENTIFICATION WHERE EntityName = 'UPR_HIER_LOAD');
    SELECT a.AuditLogID AS AuditID, a.RunID, a.SessionID, e.EntityName, a.EntityKey,
        a.ActionType AS OperationType, a.ChangedDate, a.ChangedBy, a.OldValues, a.NewValues,
        a.UPRID, a.OriginalUPRID, a.EntityID, a.EntityRecordID,
        DisplayRecordKey = CONVERT(NVARCHAR(MAX), a.EntityKey)
    INTO #AuditEvents
    FROM dbo.AUDIT_LOG a
    JOIN dbo.REF_ENTITY_IDENTIFICATION e ON e.EntityID = a.EntityID
    WHERE (@SummaryEntityID IS NULL OR a.EntityID <> @SummaryEntityID)
      AND (@RunID IS NULL OR a.RunID = @RunID)
      AND (@EntityID IS NULL OR a.EntityID = @EntityID)
      AND (@UPRID IS NULL OR a.OriginalUPRID = @UPRID OR a.UPRID = @UPRID)
      AND (@Since IS NULL OR a.ChangedDate >= @Since)
      AND (@Until IS NULL OR a.ChangedDate < @Until)
    OPTION (RECOMPILE);

    /* Display only: never reserialize/update historical EntityKey or record IDs.
       Unknown legacy text, empty objects and nested keys retain the raw value.
       Keep OPENJSON dynamic for databases below compatibility level 130. */
    IF ISNULL(@RawRecordKey, 0) = 0
    BEGIN
        IF (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()) >= 130
            EXEC sys.sp_executesql N'
            UPDATE a SET DisplayRecordKey = labels.RecordKey
            FROM #AuditEvents a
            CROSS APPLY (
                SELECT STUFF((
                    SELECT N''; ['' + REPLACE(STRING_ESCAPE(j.[key], ''json''), N'']'', N'']]'') + N''] = ''
                        + CASE WHEN j.[type] = 0 THEN N''NULL''
                               WHEN j.[type] = 1 THEN N''"'' + STRING_ESCAPE(j.value, ''json'') + N''"''
                               ELSE j.value END
                    FROM OPENJSON(CASE WHEN ISJSON(a.EntityKey) = 1
                        AND LEFT(LTRIM(a.EntityKey), 1) = N''{'' THEN a.EntityKey ELSE N''{}'' END) j
                    ORDER BY CASE WHEN j.[key] IN (N''UPRAncestry'', N''AncestorUPRID'') THEN 0
                                  WHEN j.[key] = N''DescendantUPRID'' THEN 1 ELSE 2 END,
                             j.[key] COLLATE Latin1_General_100_BIN2
                    FOR XML PATH(''''), TYPE
                ).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''') AS RecordKey
            ) labels
            WHERE NULLIF(labels.RecordKey, N'''') IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM OPENJSON(CASE WHEN ISJSON(a.EntityKey) = 1
                      THEN a.EntityKey ELSE N''{}'' END) j WHERE j.[type] IN (4, 5)
              );';
        ELSE PRINT N'Readable record keys require compatibility level 130+. Showing stored keys.';
    END;
    PRINT N'Key guide: EntityID identifies the table. EntityRecordID identifies the record within that table.';
    PRINT N'Composite/text keys use an internal negative EntityRecordID; it is not a UPRID or an error.';
    IF @RawRecordKey = 1
        PRINT N'RecordKey shows stored EntityKey JSON (or retained legacy text).';
    ELSE
        PRINT N'RecordKey shows the identifying column(s) and value(s). Stored EntityKey and audit history are unchanged.';

    PRINT N'Load runs (row-change counts reflect the selected report filters)';
    SELECT r.RunID, r.StartedAt, r.FinishedAt, r.RunStatus, r.StartedBy,
        r.SourceRowsRead, r.RejectedRows,
        RowsInserted = COALESCE(a.RowsInserted, 0),
        RowsUpdated = COALESCE(a.RowsUpdated, 0),
        RowsDeleted = COALESCE(a.RowsDeleted, 0), r.ErrorMessage
    FROM dbo.UPR_LOAD_RUN r
    LEFT JOIN (
        SELECT RunID,
            RowsInserted = SUM(CASE WHEN OperationType = 'INSERT' THEN 1 ELSE 0 END),
            RowsUpdated = SUM(CASE WHEN OperationType = 'UPDATE' THEN 1 ELSE 0 END),
            RowsDeleted = SUM(CASE WHEN OperationType = 'DELETE' THEN 1 ELSE 0 END)
        FROM #AuditEvents GROUP BY RunID
    ) a ON a.RunID = r.RunID
    WHERE (@RunID IS NULL OR r.RunID = @RunID)
      AND ((@EntityID IS NULL AND @UPRID IS NULL) OR a.RunID IS NOT NULL)
      AND (@Since IS NULL OR r.StartedAt >= @Since OR a.RunID IS NOT NULL)
      AND (@Until IS NULL OR r.StartedAt < @Until OR a.RunID IS NOT NULL)
    ORDER BY r.StartedAt DESC, r.RunID;

    PRINT N'Changed rows - one record per row event';
    SELECT AuditID, RunID, UPRID, OriginalUPRID, EntityID, EntityRecordID,
        ChangeSource = CASE WHEN RunID IS NOT NULL THEN N'Load run'
            WHEN SessionID IS NOT NULL THEN N'Outside load'
            ELSE N'Earlier audit (run unknown)' END,
        SessionID, EntityName AS TableName, DisplayRecordKey AS RecordKey,
        OperationType AS Action, ChangedDate, ChangedBy, OldValues, NewValues
    FROM #AuditEvents ORDER BY AuditID;

    IF @IncludeFieldDetails = 1
    BEGIN
        IF (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()) < 130
        BEGIN
            PRINT N'Field details require compatibility level 130+. Full row values are shown above.';
            RETURN;
        END;
        PRINT N'Field details - changed fields for UPDATE; all fields for INSERT/DELETE';
        /* Compile OPENJSON only when supported. Binary comparisons preserve
           changes in letter case and trailing spaces; type 0 represents NULL. */
        EXEC sys.sp_executesql N'
            SELECT a.AuditID, a.RunID, a.UPRID, a.OriginalUPRID, a.EntityID, a.EntityRecordID, a.EntityName AS TableName, a.DisplayRecordKey AS RecordKey,
                a.OperationType AS Action, a.ChangedDate, a.ChangedBy,
                f.FieldName, f.OldValue, f.NewValue,
                f.OldValueState, f.NewValueState
            FROM #AuditEvents a
            CROSS APPLY (
                SELECT COALESCE(o.[key], n.[key]) AS FieldName,
                    o.value AS OldValue, n.value AS NewValue,
                    CASE WHEN o.[key] IS NULL THEN N''Not present''
                         WHEN o.type = 0 THEN N''NULL'' ELSE N''Value'' END AS OldValueState,
                    CASE WHEN n.[key] IS NULL THEN N''Not present''
                         WHEN n.type = 0 THEN N''NULL'' ELSE N''Value'' END AS NewValueState
                FROM OPENJSON(CASE WHEN ISJSON(a.OldValues) = 1 THEN a.OldValues ELSE N''{}'' END) o
                FULL OUTER JOIN OPENJSON(CASE WHEN ISJSON(a.NewValues) = 1 THEN a.NewValues ELSE N''{}'' END) n
                    ON n.[key] = o.[key]
                WHERE a.OperationType <> N''UPDATE''
                   OR EXISTS (SELECT o.type, CONVERT(VARBINARY(MAX), o.value)
                              EXCEPT SELECT n.type, CONVERT(VARBINARY(MAX), n.value))
            ) f
            ORDER BY a.AuditID, f.FieldName;';
    END;
END;
GO

EXEC dbo.usp_UPR_AuditReport @LatestRun = 1, @IncludeFieldDetails = 0;
-- All history (can be large): EXEC dbo.usp_UPR_AuditReport;
-- Most recent run: EXEC dbo.usp_UPR_AuditReport @LatestRun = 1;
-- One table: EXEC dbo.usp_UPR_AuditReport @TableName = N'UNIT';
-- One UPR (including deleted): EXEC dbo.usp_UPR_AuditReport @UPRID = 123;
-- One entity: EXEC dbo.usp_UPR_AuditReport @EntityID = 4;
-- Original JSON keys: EXEC dbo.usp_UPR_AuditReport @LatestRun = 1, @RawRecordKey = 1;
-- One run: EXEC dbo.usp_UPR_AuditReport @RunID = 'paste-run-id-here';
GO

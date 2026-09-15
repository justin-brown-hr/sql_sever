/*
  Row-change report. Run after install_upr_audit.sql; safe on existing data.
  Default: all retained load runs and row events, including edits outside loads.
  Change the EXEC parameters at the bottom to select one run/table/date range.
  Result sets: load runs, changed rows, individual changed fields.
  Old audit rows retain their original values; unknown run/session stays NULL.
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
    @IncludeFieldDetails BIT = 1
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

    /* One snapshot of the selected events feeds all three result sets. */
    SELECT AuditID, RunID, SessionID, EntityName, EntityKey, OperationType,
        ChangedDate, ChangedBy, OldValues, NewValues
    INTO #AuditEvents
    FROM dbo.AuditLog
    WHERE EntityName <> N'UPR_HIER_LOAD'
      AND (@RunID IS NULL OR RunID = @RunID)
      AND (@TableName IS NULL OR EntityName = @TableName)
      AND (@Since IS NULL OR ChangedDate >= @Since)
      AND (@Until IS NULL OR ChangedDate < @Until);

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
      AND (@TableName IS NULL OR a.RunID IS NOT NULL)
      AND (@Since IS NULL OR r.StartedAt >= @Since OR a.RunID IS NOT NULL)
      AND (@Until IS NULL OR r.StartedAt < @Until OR a.RunID IS NOT NULL)
    ORDER BY r.StartedAt DESC, r.RunID;

    PRINT N'Changed rows - one record per row event';
    SELECT AuditID, RunID,
        ChangeSource = CASE WHEN RunID IS NOT NULL THEN N'Load run'
            WHEN SessionID IS NOT NULL THEN N'Outside load'
            ELSE N'Earlier audit (run unknown)' END,
        SessionID, EntityName AS TableName, EntityKey AS RecordKey,
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
            SELECT a.AuditID, a.RunID, a.EntityName AS TableName, a.EntityKey AS RecordKey,
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

EXEC dbo.usp_UPR_AuditReport;
-- Most recent run: EXEC dbo.usp_UPR_AuditReport @LatestRun = 1;
-- One table: EXEC dbo.usp_UPR_AuditReport @TableName = N'UNIT';
-- One run: EXEC dbo.usp_UPR_AuditReport @RunID = 'paste-run-id-here';
GO

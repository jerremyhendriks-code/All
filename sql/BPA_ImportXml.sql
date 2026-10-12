USE [BPAStaging]
GO
/****** Object:  StoredProcedure [dbo].[BPA_ImportXml]    Script Date: 12/10/2026 09:03:41 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
    Generic XML-to-relational importer for Microsoft SQL Server.

    Rules:
      * By default, the widest repeated/Array-marked record collection is used
        as the import root. Wrapper and unrelated metadata tables are skipped.
      * @RecordPath can explicitly select the import root when AUTO selection
        would be ambiguous. It uses local-name paths such as
        /WebService/SuiteQL/OutputSchema/root/items.
      * A child element becomes a child table when, anywhere below the current
        parent table, it is repeated, has attributes, or has element children.
      * A non-repeated leaf child becomes an nvarchar(max) column on its parent.
        All generated XML value columns are string-compatible nvarchar(max).
      * Attributes become columns named "@attributeName".
      * A row element's own text is stored in BPA_Value when applicable.
      * All occurrences at a level are inspected before deciding its shape.
      * Every generated table has the standard BPA metadata columns. Child
        tables receive a BPA_ParentID foreign key to the parent table's
        BPA_EntryID.
      * @BPA_Origin, @BPA_Direction, @BPA_Company and @BPA_Reference_Description
        are constant values for the whole call. They are written only to the
        rows created in the root/header table (@BaseTableName); child tables
        are left NULL for these columns and can be resolved by joining back to
        the root table through BPA_ParentID.
      * @BPA_ReferenceField names the root record's own element (e.g. 'id') or
        attribute (e.g. '@id') that holds that record's primary key in the
        source system. Unlike the other control fields, a record's primary key
        is different for every row, so it cannot be passed as one scalar
        value; instead its already-imported column value is copied into
        BPA_Reference for every row inserted into the root table by this call.
      * @BPA_CompanyField (default 'Subsidiary_ID') names the root record's own
        element or attribute that holds the record's company. Its value is
        copied into BPA_Company for every root row inserted by this call. When
        a record has no value for that field, or the selected record has no
        such field at all, BPA_Company falls back to the constant @BPA_Company.
        Pass NULL or '' to always use @BPA_Company.

    @BaseTableName accepts [schema].[table] or just [table] (defaults to dbo).
    The automatically or explicitly selected import root always uses exactly
    @BaseTableName. Only tables below that import root receive _ChildName suffixes.
    XML element names are used verbatim as quoted SQL identifiers. SQL Server's
    128-character identifier limit therefore also applies to generated names.
*/
ALTER PROCEDURE [dbo].[BPA_ImportXml]
    @Xml                        xml,
    @BaseTableName              nvarchar(257),
    @RecordPath                 nvarchar(4000) = NULL,
    @BPA_Origin                 nvarchar(50)   = NULL,
    @BPA_Direction              nvarchar(50)   = NULL,
    @BPA_Company                nvarchar(50)   = NULL,
    @BPA_ReferenceField         nvarchar(4000) = NULL,
    @BPA_Reference_Description  nvarchar(100)  = NULL,
    @BPA_CompanyField           nvarchar(4000) = N'Subsidiary_ID'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Xml IS NULL
        THROW 50000, 'The XML document cannot be NULL.', 1;

    DECLARE
        @SchemaName sysname = COALESCE(PARSENAME(@BaseTableName, 2), N'dbo'),
        @TableName  sysname = PARSENAME(@BaseTableName, 1),
        @DocumentHandle int = NULL,
        @StartedTransaction bit = 0;

    IF @TableName IS NULL
       OR PARSENAME(@BaseTableName, 3) IS NOT NULL
       OR PARSENAME(@BaseTableName, 4) IS NOT NULL
        THROW 50001, 'BaseTableName must be a one- or two-part SQL Server table name.', 1;

    IF SCHEMA_ID(@SchemaName) IS NULL
        THROW 50002, 'The schema in BaseTableName does not exist.', 1;

    BEGIN TRY
        IF @@TRANCOUNT = 0
        BEGIN
            BEGIN TRANSACTION;
            SET @StartedTransaction = 1;
        END
        ELSE
            SAVE TRANSACTION BPA_ImportXml_Savepoint;

        EXEC sys.sp_xml_preparedocument @DocumentHandle OUTPUT, @Xml;

        CREATE TABLE #Edge
        (
            NodeID        int            NOT NULL PRIMARY KEY,
            ParentNodeID  int            NULL,
            NodeType      int            NOT NULL,
            LocalName     nvarchar(4000) NULL,
            NodeValue     nvarchar(max)  NULL
        );

        CREATE TABLE #Element
        (
            ElementID        int            NOT NULL PRIMARY KEY,
            ParentElementID  int            NULL,
            LocalName        nvarchar(4000) NOT NULL,
            ElementPath      nvarchar(4000) NULL,
            ElementDepth     int            NULL
        );

        CREATE TABLE #Attribute
        (
            AttributeID      int            NOT NULL PRIMARY KEY,
            ParentElementID  int            NOT NULL,
            LocalName        nvarchar(4000) NOT NULL,
            NodeValue        nvarchar(max)  NULL
        );

        CREATE TABLE #Text
        (
            TextID           int            NOT NULL PRIMARY KEY,
            ParentElementID  int            NOT NULL,
            NodeValue        nvarchar(max)  NULL
        );

        /* '/' without a WITH clause returns the complete OPENXML edge table. */
        INSERT #Edge (NodeID, ParentNodeID, NodeType, LocalName, NodeValue)
        SELECT id, parentid, nodetype, localname, CONVERT(nvarchar(max), [text])
        FROM OPENXML(@DocumentHandle, N'/');

        CREATE INDEX IX_BPA_ImportXml_Edge_ParentNode
            ON #Edge (ParentNodeID, NodeType, NodeID)
            INCLUDE (LocalName);

        INSERT #Element (ElementID, ParentElementID, LocalName)
        SELECT NodeID, ParentNodeID, LocalName
        FROM #Edge
        WHERE NodeType = 1;

        INSERT #Attribute (AttributeID, ParentElementID, LocalName, NodeValue)
        SELECT a.NodeID, a.ParentNodeID, a.LocalName, valueNode.NodeValue
        FROM #Edge AS a
        LEFT JOIN #Edge AS valueNode
          ON valueNode.ParentNodeID = a.NodeID
         AND valueNode.NodeType = 3
        WHERE a.NodeType = 2;

        INSERT #Text (TextID, ParentElementID, NodeValue)
        SELECT textNode.NodeID, textNode.ParentNodeID, textNode.NodeValue
        FROM #Edge AS textNode
        JOIN #Edge AS parentNode ON parentNode.NodeID = textNode.ParentNodeID
        WHERE textNode.NodeType = 3
          AND parentNode.NodeType = 1;

        CREATE INDEX IX_BPA_ImportXml_Element_Parent
            ON #Element (ParentElementID, ElementID)
            INCLUDE (LocalName);

        CREATE INDEX IX_BPA_ImportXml_Attribute_Parent
            ON #Attribute (ParentElementID, AttributeID)
            INCLUDE (LocalName);

        CREATE INDEX IX_BPA_ImportXml_Text_Parent
            ON #Text (ParentElementID, TextID);

        DECLARE @RootElementID int;

        SELECT @RootElementID = e.ElementID
        FROM #Element AS e
        WHERE NOT EXISTS
        (
            SELECT 1 FROM #Element AS p WHERE p.ElementID = e.ParentElementID
        );

        IF @RootElementID IS NULL
            THROW 50003, 'The XML document has no document element.', 1;

        /* Build stable local-name paths for automatic and explicit root selection. */
        ;WITH ElementTree AS
        (
            SELECT
                e.ElementID,
                CONVERT(nvarchar(4000), N'/' + e.LocalName) AS ElementPath,
                0 AS ElementDepth
            FROM #Element AS e
            WHERE e.ElementID = @RootElementID

            UNION ALL

            SELECT
                child.ElementID,
                CONVERT(nvarchar(4000), parent.ElementPath + N'/' + child.LocalName),
                parent.ElementDepth + 1
            FROM ElementTree AS parent
            JOIN #Element AS child ON child.ParentElementID = parent.ElementID
        )
        UPDATE target
            SET ElementPath = source.ElementPath,
                ElementDepth = source.ElementDepth
        FROM #Element AS target
        JOIN ElementTree AS source ON source.ElementID = target.ElementID
        OPTION (MAXRECURSION 32767);

        DECLARE
            @DocumentRootPath nvarchar(4000),
            @SelectedRecordPath nvarchar(4000);

        SELECT @DocumentRootPath = ElementPath
        FROM #Element
        WHERE ElementID = @RootElementID;

        IF NULLIF(LTRIM(RTRIM(@RecordPath)), N'') IS NOT NULL
        BEGIN
            SET @SelectedRecordPath = LTRIM(RTRIM(@RecordPath));

            IF LEFT(@SelectedRecordPath, 1) <> N'/'
            BEGIN
                IF 1 < (SELECT COUNT(DISTINCT ElementPath) FROM #Element WHERE LocalName = @SelectedRecordPath)
                    THROW 50010, 'RecordPath is ambiguous; provide its complete /root/.../record path.', 1;

                SELECT @SelectedRecordPath = MIN(ElementPath)
                FROM #Element
                WHERE LocalName = @SelectedRecordPath;
            END;

            IF NOT EXISTS (SELECT 1 FROM #Element WHERE ElementPath = @SelectedRecordPath)
                THROW 50011, 'RecordPath does not exist in the supplied XML document.', 1;
        END
        ELSE
        BEGIN
            CREATE TABLE #Candidate
            (
                ElementPath  nvarchar(4000) NOT NULL,
                ElementDepth int NOT NULL,
                CandidateRowCount   int NOT NULL,
                CandidateFieldCount int NOT NULL
            );

            /*
               Candidate collections either repeat at one logical path or are
               explicitly marked Array="true". Only direct scalar children
               count as fields; the widest record shape wins before row count.
            */
            INSERT #Candidate (ElementPath, ElementDepth, CandidateRowCount, CandidateFieldCount)
            SELECT
                recordNode.ElementPath,
                MIN(recordNode.ElementDepth),
                COUNT(DISTINCT recordNode.ElementID),
                COUNT(DISTINCT scalarChild.LocalName)
            FROM #Element AS recordNode
            JOIN #Element AS scalarChild ON scalarChild.ParentElementID = recordNode.ElementID
            WHERE NOT EXISTS
                  (
                      SELECT 1
                      FROM #Element AS grandChild
                      WHERE grandChild.ParentElementID = scalarChild.ElementID
                  )
            GROUP BY recordNode.ElementPath
            HAVING COUNT(DISTINCT recordNode.ElementID) > 1
                OR EXISTS
                   (
                       SELECT 1
                       FROM #Element AS markedNode
                       JOIN #Attribute AS marker ON marker.ParentElementID = markedNode.ElementID
                       WHERE markedNode.ElementPath = recordNode.ElementPath
                         AND marker.LocalName = N'Array'
                         AND LOWER(LTRIM(RTRIM(marker.NodeValue))) IN (N'true', N'1')
                   );

            SELECT TOP (1) @SelectedRecordPath = ElementPath
            FROM #Candidate
            ORDER BY CandidateFieldCount DESC, CandidateRowCount DESC, ElementDepth ASC, ElementPath;

            /*
               If nothing repeats and no Array marker exists, choose the widest
               record-shaped element. This handles single-record payloads while
               still preferring a repeated collection whenever one is present.
            */
            IF @SelectedRecordPath IS NULL
            BEGIN
                SELECT TOP (1) @SelectedRecordPath = recordNode.ElementPath
                FROM #Element AS recordNode
                JOIN #Element AS scalarChild ON scalarChild.ParentElementID = recordNode.ElementID
                WHERE NOT EXISTS
                      (
                          SELECT 1
                          FROM #Element AS grandChild
                          WHERE grandChild.ParentElementID = scalarChild.ElementID
                      )
                GROUP BY recordNode.ElementPath, recordNode.ElementDepth
                ORDER BY COUNT(DISTINCT scalarChild.LocalName) DESC,
                         COUNT(DISTINCT recordNode.ElementID) DESC,
                         recordNode.ElementDepth ASC,
                         recordNode.ElementPath;
            END;

            SET @SelectedRecordPath = COALESCE(@SelectedRecordPath, @DocumentRootPath);

            DROP TABLE #Candidate;
        END;

        CREATE TABLE #Work
        (
            WorkID           int IDENTITY(1,1) NOT NULL PRIMARY KEY,
            SchemaName       sysname NOT NULL,
            TableName        sysname NOT NULL,
            ParentWorkID     int NULL,
            IsProcessed      bit NOT NULL DEFAULT (0)
        );

        CREATE TABLE #Instance
        (
            WorkID           int NOT NULL,
            ElementID        int NOT NULL,
            ParentEntryID    uniqueidentifier NULL,
            PRIMARY KEY (WorkID, ElementID)
        );

        CREATE TABLE #RowMap
        (
            WorkID           int NOT NULL,
            ElementID        int NOT NULL,
            EntryID          uniqueidentifier NOT NULL,
            PRIMARY KEY (WorkID, ElementID)
        );

        CREATE INDEX IX_BPA_ImportXml_RowMap_WorkEntry
            ON #RowMap (WorkID, EntryID)
            INCLUDE (ElementID);

        CREATE TABLE #BpaColumn
        (
            SortOrder          int NOT NULL PRIMARY KEY,
            ColumnName         sysname NOT NULL UNIQUE,
            ColumnDefinition   nvarchar(max) NOT NULL,
            TypeName           sysname NOT NULL,
            MaxLength          smallint NOT NULL,
            IsRequired         bit NOT NULL,
            DefaultExpression  nvarchar(4000) NULL
        );

        INSERT #BpaColumn
            (SortOrder, ColumnName, ColumnDefinition, TypeName, MaxLength, IsRequired, DefaultExpression)
        VALUES
            (1,  N'BPA_EntryID',                   N'uniqueidentifier NOT NULL DEFAULT (newsequentialid())', N'uniqueidentifier', 16,  1, N'(newsequentialid())'),
            (2,  N'BPA_Origin',                    N'nvarchar(50) NULL',                                      N'nvarchar',         100, 0, NULL),
            (3,  N'BPA_Direction',                 N'nvarchar(50) NULL',                                      N'nvarchar',         100, 0, NULL),
            (4,  N'BPA_Company',                   N'nvarchar(50) NULL',                                      N'nvarchar',         100, 0, NULL),
            (5,  N'BPA_ParentID',                  N'uniqueidentifier NULL',                                  N'uniqueidentifier', 16,  0, NULL),
            (6,  N'BPA_Status',                    N'int NULL DEFAULT (0)',                                   N'int',              4,   0, N'(0)'),
            (7,  N'BPA_Reference',                 N'nvarchar(50) NULL',                                      N'nvarchar',         100, 0, NULL),
            (8,  N'BPA_Reference_Description',     N'nvarchar(100) NULL',                                     N'nvarchar',         200, 0, NULL),
            (9,  N'BPA_Reference2',                N'nvarchar(50) NULL',                                      N'nvarchar',         100, 0, NULL),
            (10, N'BPA_Reference2_Description',    N'nvarchar(100) NULL',                                     N'nvarchar',         200, 0, NULL),
            (11, N'BPA_Action',                    N'nvarchar(1) NULL',                                       N'nvarchar',         2,   0, NULL),
            (12, N'BPA_ReturnedID',                N'nvarchar(50) NULL',                                      N'nvarchar',         100, 0, NULL),
            (13, N'BPA_Syscreated',                N'datetime NULL DEFAULT (getdate())',                      N'datetime',         8,   0, N'(getdate())'),
            (14, N'BPA_Sysmodified',               N'datetime NULL DEFAULT (getdate())',                      N'datetime',         8,   0, N'(getdate())'),
            (15, N'BPA_Syscreator',                N'nvarchar(50) NULL',                                      N'nvarchar',         100, 0, NULL),
            (16, N'BPA_Error',                     N'varchar(max) NULL',                                      N'varchar',          -1,  0, NULL),
            (17, N'BPA_Error_Extended',            N'varchar(max) NULL',                                      N'varchar',          -1,  0, NULL),
            (18, N'BPA_Description',               N'varchar(100) NULL',                                      N'varchar',          100, 0, NULL),
            (19, N'BPA_Failcount',                 N'int NULL DEFAULT (0)',                                   N'int',              4,   0, N'(0)'),
            (20, N'BPA_Orig_Entryid',              N'uniqueidentifier NULL',                                  N'uniqueidentifier', 16,  0, NULL),
            (21, N'BPA_TaskInstanceID',            N'int NULL',                                               N'int',              4,   0, NULL),
            (22, N'BPA_TaskID',                    N'int NULL',                                               N'int',              4,   0, NULL);

        INSERT #Work (SchemaName, TableName, ParentWorkID)
        VALUES (@SchemaName, @TableName, NULL);

        INSERT #Instance (WorkID, ElementID, ParentEntryID)
        SELECT 1, ElementID, NULL
        FROM #Element
        WHERE ElementPath = @SelectedRecordPath;

        DECLARE
            @WorkID int,
            @ParentWorkID int,
            @QualifiedTable nvarchar(517),
            @QualifiedParent nvarchar(517),
            @ObjectID int,
            @ParentObjectID int,
            @Sql nvarchar(max),
            @ColumnName sysname,
            @SourceName nvarchar(4000),
            @SourceKind char(1),
            @ReferenceColumnName sysname,
            @CompanyColumnName sysname,
            @ChildName nvarchar(4000),
            @ChildTableName sysname,
            @ChildWorkID int,
            @ConstraintName sysname,
            @BpaColumnName sysname,
            @BpaColumnDefinition nvarchar(max),
            @BpaDefaultExpression nvarchar(4000),
            @BpaColumnList nvarchar(max);

        SELECT @BpaColumnList =
            STRING_AGG(
                CONVERT(nvarchar(max), N'                    ' + QUOTENAME(ColumnName) + N' ' + ColumnDefinition),
                N',' + CHAR(13) + CHAR(10)
            ) WITHIN GROUP (ORDER BY SortOrder)
        FROM #BpaColumn;

        WHILE EXISTS (SELECT 1 FROM #Work WHERE IsProcessed = 0)
        BEGIN
            SELECT TOP (1)
                @WorkID = WorkID,
                @SchemaName = SchemaName,
                @TableName = TableName,
                @ParentWorkID = ParentWorkID
            FROM #Work
            WHERE IsProcessed = 0
            ORDER BY WorkID;

            SET @QualifiedTable = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
            SET @ObjectID = OBJECT_ID(@QualifiedTable, N'U');

            IF @ObjectID IS NULL
            BEGIN
                SET @Sql = N'CREATE TABLE ' + @QualifiedTable + N'
                (
' + @BpaColumnList + N',
                    CONSTRAINT ' + QUOTENAME(N'PK_' + LEFT(CONVERT(varchar(64), HASHBYTES('SHA2_256', @QualifiedTable), 2), 32)) +
                    N' PRIMARY KEY (BPA_EntryID)
                );';
                EXEC sys.sp_executesql @Sql;
                SET @ObjectID = OBJECT_ID(@QualifiedTable, N'U');
            END;

            DECLARE BpaColumnCursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT ColumnName, ColumnDefinition
                FROM #BpaColumn
                ORDER BY SortOrder;

            OPEN BpaColumnCursor;
            FETCH NEXT FROM BpaColumnCursor INTO @BpaColumnName, @BpaColumnDefinition;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF COL_LENGTH(@QualifiedTable, @BpaColumnName) IS NULL
                BEGIN
                    SET @Sql = N'ALTER TABLE ' + @QualifiedTable + N' ADD ' +
                               QUOTENAME(@BpaColumnName) + N' ' + @BpaColumnDefinition + N';';
                    EXEC sys.sp_executesql @Sql;
                END;

                FETCH NEXT FROM BpaColumnCursor INTO @BpaColumnName, @BpaColumnDefinition;
            END;

            CLOSE BpaColumnCursor;
            DEALLOCATE BpaColumnCursor;

            IF EXISTS
            (
                SELECT 1
                FROM #BpaColumn AS bc
                LEFT JOIN sys.columns AS c
                  ON c.object_id = @ObjectID
                 AND c.name = bc.ColumnName
                WHERE c.column_id IS NULL
                   OR c.system_type_id <> TYPE_ID(bc.TypeName)
                   OR c.max_length <> bc.MaxLength
                   OR (bc.IsRequired = 1 AND c.is_nullable = 1)
                   OR c.is_identity = 1
            )
                THROW 50004, 'An existing BPA metadata column has an incompatible SQL Server type.', 1;

            DECLARE BpaDefaultCursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT ColumnName, DefaultExpression
                FROM #BpaColumn
                WHERE DefaultExpression IS NOT NULL
                ORDER BY SortOrder;

            OPEN BpaDefaultCursor;
            FETCH NEXT FROM BpaDefaultCursor INTO @BpaColumnName, @BpaDefaultExpression;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF NOT EXISTS
                (
                    SELECT 1
                    FROM sys.default_constraints AS dc
                    JOIN sys.columns AS c
                      ON c.object_id = dc.parent_object_id
                     AND c.column_id = dc.parent_column_id
                    WHERE dc.parent_object_id = @ObjectID
                      AND c.name = @BpaColumnName
                )
                BEGIN
                    SET @ConstraintName = N'DF_' + LEFT(CONVERT(varchar(64), HASHBYTES('SHA2_256', @QualifiedTable + N'_' + @BpaColumnName), 2), 32);
                    SET @Sql = N'ALTER TABLE ' + @QualifiedTable + N' ADD CONSTRAINT ' +
                               QUOTENAME(@ConstraintName) + N' DEFAULT ' + @BpaDefaultExpression +
                               N' FOR ' + QUOTENAME(@BpaColumnName) + N';';
                    EXEC sys.sp_executesql @Sql;
                END;

                FETCH NEXT FROM BpaDefaultCursor INTO @BpaColumnName, @BpaDefaultExpression;
            END;

            CLOSE BpaDefaultCursor;
            DEALLOCATE BpaDefaultCursor;

            /* A referenced BPA_EntryID must be unique even on a pre-existing table. */
            IF NOT EXISTS
            (
                SELECT 1
                FROM sys.indexes AS ix
                JOIN sys.index_columns AS ic
                  ON ic.object_id = ix.object_id AND ic.index_id = ix.index_id
                JOIN sys.columns AS c
                  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                WHERE ix.object_id = @ObjectID
                  AND ix.is_unique = 1
                GROUP BY ix.object_id, ix.index_id
                HAVING COUNT(*) = 1 AND MAX(c.name) = N'BPA_EntryID'
            )
            BEGIN
                SET @ConstraintName = N'UX_' + LEFT(CONVERT(varchar(64), HASHBYTES('SHA2_256', @QualifiedTable + N'_Entry'), 2), 32);
                SET @Sql = N'CREATE UNIQUE INDEX ' + QUOTENAME(@ConstraintName) +
                           N' ON ' + @QualifiedTable + N' (BPA_EntryID);';
                EXEC sys.sp_executesql @Sql;
            END;

            IF @ParentWorkID IS NOT NULL
            BEGIN
                SELECT @QualifiedParent = QUOTENAME(SchemaName) + N'.' + QUOTENAME(TableName)
                FROM #Work WHERE WorkID = @ParentWorkID;

                SET @ParentObjectID = OBJECT_ID(@QualifiedParent, N'U');

                IF NOT EXISTS
                (
                    SELECT 1
                    FROM sys.foreign_key_columns AS fkc
                    JOIN sys.columns AS cc
                      ON cc.object_id = fkc.parent_object_id AND cc.column_id = fkc.parent_column_id
                    JOIN sys.columns AS pc
                      ON pc.object_id = fkc.referenced_object_id AND pc.column_id = fkc.referenced_column_id
                    WHERE fkc.parent_object_id = @ObjectID
                      AND fkc.referenced_object_id = @ParentObjectID
                      AND cc.name = N'BPA_ParentID'
                      AND pc.name = N'BPA_EntryID'
                )
                BEGIN
                    SET @ConstraintName = N'FK_' + LEFT(CONVERT(varchar(64), HASHBYTES('SHA2_256', @QualifiedTable + N'_' + @QualifiedParent), 2), 32);
                    SET @Sql = N'ALTER TABLE ' + @QualifiedTable + N' WITH CHECK ADD CONSTRAINT ' +
                               QUOTENAME(@ConstraintName) + N' FOREIGN KEY (BPA_ParentID) REFERENCES ' +
                               @QualifiedParent + N' (BPA_EntryID);';
                    EXEC sys.sp_executesql @Sql;
                END;
            END;

            /*
               Insert this invocation's row instances and retain XML-node-to-ID mapping.
               The control-field parameters (@BPA_Origin, @BPA_Direction, @BPA_Company,
               @BPA_Reference_Description) are only written onto the root/header table's
               rows (ParentWorkID IS NULL). Child tables keep these columns NULL; join
               back to the root table through BPA_ParentID to resolve them if needed.
               BPA_Reference and BPA_Company are filled in separately below, from
               @BPA_ReferenceField and @BPA_CompanyField, once this table's own columns
               have been populated.
            */
            IF @ParentWorkID IS NULL
            BEGIN
                SET @Sql = N'MERGE ' + @QualifiedTable + N' AS target
                    USING
                    (
                        SELECT ElementID, ParentEntryID
                        FROM #Instance
                        WHERE WorkID = @pWorkID
                    ) AS source
                    ON 1 = 0
                    WHEN NOT MATCHED THEN
                        INSERT (BPA_ParentID, BPA_Origin, BPA_Direction, BPA_Company, BPA_Reference_Description)
                        VALUES (source.ParentEntryID, @pOrigin, @pDirection, @pCompany, @pReferenceDescription)
                    OUTPUT @pWorkID, source.ElementID, inserted.BPA_EntryID
                        INTO #RowMap (WorkID, ElementID, EntryID);';
            END
            ELSE
            BEGIN
                SET @Sql = N'MERGE ' + @QualifiedTable + N' AS target
                    USING
                    (
                        SELECT ElementID, ParentEntryID
                        FROM #Instance
                        WHERE WorkID = @pWorkID
                    ) AS source
                    ON 1 = 0
                    WHEN NOT MATCHED THEN
                        INSERT (BPA_ParentID) VALUES (source.ParentEntryID)
                    OUTPUT @pWorkID, source.ElementID, inserted.BPA_EntryID
                        INTO #RowMap (WorkID, ElementID, EntryID);';
            END;
            EXEC sys.sp_executesql
                @Sql,
                N'@pWorkID int, @pOrigin nvarchar(50), @pDirection nvarchar(50), @pCompany nvarchar(50), @pReferenceDescription nvarchar(100)',
                @pWorkID = @WorkID,
                @pOrigin = @BPA_Origin,
                @pDirection = @BPA_Direction,
                @pCompany = @BPA_Company,
                @pReferenceDescription = @BPA_Reference_Description;

            CREATE TABLE #Column
            (
                ColumnName sysname NOT NULL PRIMARY KEY,
                SourceKind char(1) NOT NULL,
                SourceName nvarchar(4000) NULL
            );

            IF EXISTS
            (
                SELECT 1
                FROM #Instance AS i
                JOIN #Attribute AS a ON a.ParentElementID = i.ElementID
                WHERE i.WorkID = @WorkID
                  AND LEN(a.LocalName) + 1 > 128
            )
                THROW 50008, 'An XML attribute name exceeds SQL Server''s 128-character identifier limit.', 1;

            IF EXISTS
            (
                SELECT 1
                FROM #Instance AS i
                JOIN #Element AS e ON e.ParentElementID = i.ElementID
                WHERE i.WorkID = @WorkID
                  AND LEN(e.LocalName) +
                      CASE
                          WHEN e.LocalName = N'BPA_Value'
                            OR EXISTS (SELECT 1 FROM #BpaColumn AS bc WHERE bc.ColumnName = e.LocalName)
                          THEN 4 ELSE 0
                      END > 128
            )
                THROW 50009, 'An XML element name exceeds SQL Server''s 128-character identifier limit.', 1;

            /* Attributes of every occurrence become columns, not only those on the first row. */
            INSERT #Column (ColumnName, SourceKind, SourceName)
            SELECT CONVERT(sysname, N'@' + a.LocalName), 'A', a.LocalName
            FROM #Instance AS i
            JOIN #Attribute AS a ON a.ParentElementID = i.ElementID
            WHERE i.WorkID = @WorkID
            GROUP BY a.LocalName;

            /*
               A leaf is scalar only when it occurs at most once per parent and
               no occurrence has attributes or element children.
            */
            INSERT #Column (ColumnName, SourceKind, SourceName)
            SELECT
                CONVERT(sysname,
                    CASE WHEN e.LocalName = N'BPA_Value'
                           OR EXISTS (SELECT 1 FROM #BpaColumn AS bc WHERE bc.ColumnName = e.LocalName)
                         THEN N'XML_' + e.LocalName ELSE e.LocalName END),
                'E',
                e.LocalName
            FROM #Instance AS i
            JOIN #Element AS e ON e.ParentElementID = i.ElementID
            WHERE i.WorkID = @WorkID
            GROUP BY e.LocalName
            HAVING NOT EXISTS
                   (
                       SELECT 1
                       FROM #Instance AS pi
                       JOIN #Element AS ce ON ce.ParentElementID = pi.ElementID
                       WHERE pi.WorkID = @WorkID
                         AND ce.LocalName = e.LocalName
                         AND
                         (
                             EXISTS (SELECT 1 FROM #Element AS ge WHERE ge.ParentElementID = ce.ElementID)
                             OR EXISTS (SELECT 1 FROM #Attribute AS ca WHERE ca.ParentElementID = ce.ElementID)
                         )
                   )
               AND 1 >=
                   (
                       SELECT MAX(x.ItemCount)
                       FROM
                       (
                           SELECT COUNT(*) AS ItemCount
                           FROM #Element AS se
                           JOIN #Instance AS si ON si.ElementID = se.ParentElementID
                           WHERE si.WorkID = @WorkID
                             AND se.LocalName = e.LocalName
                           GROUP BY si.ElementID
                       ) AS x
                   );

            /* Preserve a row element's own text for leaf rows and mixed-content XML. */
            IF EXISTS
            (
                SELECT 1
                FROM #Instance AS i
                WHERE i.WorkID = @WorkID
                  AND
                  (
                      NOT EXISTS (SELECT 1 FROM #Element AS e WHERE e.ParentElementID = i.ElementID)
                      OR EXISTS
                         (
                             SELECT 1 FROM #Text AS tx
                             WHERE tx.ParentElementID = i.ElementID
                               AND NULLIF(LTRIM(RTRIM(tx.NodeValue)), N'') IS NOT NULL
                         )
                  )
            )
                INSERT #Column (ColumnName, SourceKind, SourceName)
                VALUES (N'BPA_Value', 'V', NULL);

            DECLARE ColumnCursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT ColumnName, SourceKind, SourceName FROM #Column ORDER BY ColumnName;

            OPEN ColumnCursor;
            FETCH NEXT FROM ColumnCursor INTO @ColumnName, @SourceKind, @SourceName;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @ColumnName IS NULL OR LEN(@ColumnName) = 0
                    THROW 50006, 'An XML field name cannot be represented as a SQL Server column name.', 1;

                IF COL_LENGTH(@QualifiedTable, @ColumnName) IS NULL
                BEGIN
                    SET @Sql = N'ALTER TABLE ' + @QualifiedTable + N' ADD ' +
                               QUOTENAME(@ColumnName) + N' nvarchar(max) NULL;';
                    EXEC sys.sp_executesql @Sql;
                END
                ELSE IF NOT EXISTS
                (
                    SELECT 1
                    FROM sys.columns
                    WHERE object_id = @ObjectID
                      AND name = @ColumnName
                      AND system_type_id = TYPE_ID(N'nvarchar')
                      AND max_length = -1
                )
                BEGIN
                    SET @Sql = N'ALTER TABLE ' + @QualifiedTable + N' ALTER COLUMN ' +
                               QUOTENAME(@ColumnName) + N' nvarchar(max) NULL;';
                    EXEC sys.sp_executesql @Sql;
                END;

                IF @SourceKind = 'A'
                BEGIN
                    SET @Sql = N'UPDATE target
                        SET ' + QUOTENAME(@ColumnName) + N' = a.NodeValue
                        FROM ' + @QualifiedTable + N' AS target
                        JOIN #RowMap AS rm
                          ON rm.WorkID = @pWorkID AND rm.EntryID = target.BPA_EntryID
                        LEFT JOIN #Attribute AS a
                          ON a.ParentElementID = rm.ElementID AND a.LocalName = @pSourceName;';
                END
                ELSE IF @SourceKind = 'E'
                BEGIN
                    SET @Sql = N'UPDATE target
                        SET ' + QUOTENAME(@ColumnName) + N' = valueData.NodeValue
                        FROM ' + @QualifiedTable + N' AS target
                        JOIN #RowMap AS rm
                          ON rm.WorkID = @pWorkID AND rm.EntryID = target.BPA_EntryID
                        OUTER APPLY
                        (
                            SELECT CASE WHEN COUNT(child.ElementID) = 0 THEN NULL
                                        ELSE COALESCE(STRING_AGG(CONVERT(nvarchar(max), tx.NodeValue), N'''')
                                             WITHIN GROUP (ORDER BY tx.TextID), N'''') END AS NodeValue
                            FROM #Element AS child
                            LEFT JOIN #Text AS tx ON tx.ParentElementID = child.ElementID
                            WHERE child.ParentElementID = rm.ElementID
                              AND child.LocalName = @pSourceName
                        ) AS valueData;';
                END
                ELSE
                BEGIN
                    SET @Sql = N'UPDATE target
                        SET ' + QUOTENAME(@ColumnName) + N' = valueData.NodeValue
                        FROM ' + @QualifiedTable + N' AS target
                        JOIN #RowMap AS rm
                          ON rm.WorkID = @pWorkID AND rm.EntryID = target.BPA_EntryID
                        OUTER APPLY
                        (
                            SELECT COALESCE(STRING_AGG(CONVERT(nvarchar(max), tx.NodeValue), N'''')
                                     WITHIN GROUP (ORDER BY tx.TextID), N'''') AS NodeValue
                            FROM #Text AS tx
                            WHERE tx.ParentElementID = rm.ElementID
                        ) AS valueData;';
                END;

                EXEC sys.sp_executesql
                    @Sql,
                    N'@pWorkID int, @pSourceName nvarchar(4000)',
                    @pWorkID = @WorkID,
                    @pSourceName = @SourceName;

                FETCH NEXT FROM ColumnCursor INTO @ColumnName, @SourceKind, @SourceName;
            END;

            CLOSE ColumnCursor;
            DEALLOCATE ColumnCursor;
            DROP TABLE #Column;

            /*
               Copy the root record's own primary-key field into BPA_Reference.
               Unlike @BPA_Origin/@BPA_Direction/@BPA_Company/@BPA_Reference_Description,
               the primary key is different for every row, so it cannot be supplied as
               one scalar parameter. @BPA_ReferenceField instead names the element (e.g.
               'id') or attribute (e.g. '@id') that already became a column above, on the
               root table only, and that column's value is copied across for the rows
               this call just inserted.
            */
            IF @ParentWorkID IS NULL AND NULLIF(LTRIM(RTRIM(@BPA_ReferenceField)), N'') IS NOT NULL
            BEGIN
                SET @ReferenceColumnName = LTRIM(RTRIM(@BPA_ReferenceField));

                IF LEFT(@ReferenceColumnName, 1) <> N'@'
                   AND (@ReferenceColumnName = N'BPA_Value'
                        OR EXISTS (SELECT 1 FROM #BpaColumn WHERE ColumnName = @ReferenceColumnName))
                    SET @ReferenceColumnName = N'XML_' + @ReferenceColumnName;

                IF COL_LENGTH(@QualifiedTable, @ReferenceColumnName) IS NULL
                    THROW 50012, 'BPA_ReferenceField does not match a field on the selected record.', 1;

                SET @Sql = N'UPDATE target
                    SET target.BPA_Reference = target.' + QUOTENAME(@ReferenceColumnName) + N'
                    FROM ' + @QualifiedTable + N' AS target
                    JOIN #RowMap AS rm
                      ON rm.WorkID = @pWorkID AND rm.EntryID = target.BPA_EntryID;';
                EXEC sys.sp_executesql @Sql, N'@pWorkID int', @pWorkID = @WorkID;
            END;

            /*
               Copy the root record's company field (default 'Subsidiary_ID') into
               BPA_Company, the same way as BPA_Reference above. Rows with no value
               for that field keep the constant @BPA_Company written at insert time.
               A selected record without that field is not an error: the import then
               simply keeps @BPA_Company for every row.
            */
            IF @ParentWorkID IS NULL AND NULLIF(LTRIM(RTRIM(@BPA_CompanyField)), N'') IS NOT NULL
            BEGIN
                SET @CompanyColumnName = LTRIM(RTRIM(@BPA_CompanyField));

                IF LEFT(@CompanyColumnName, 1) <> N'@'
                   AND (@CompanyColumnName = N'BPA_Value'
                        OR EXISTS (SELECT 1 FROM #BpaColumn WHERE ColumnName = @CompanyColumnName))
                    SET @CompanyColumnName = N'XML_' + @CompanyColumnName;

                IF COL_LENGTH(@QualifiedTable, @CompanyColumnName) IS NOT NULL
                BEGIN
                    SET @Sql = N'UPDATE target
                        SET target.BPA_Company = COALESCE(NULLIF(LTRIM(RTRIM(target.' + QUOTENAME(@CompanyColumnName) + N')), N''''), target.BPA_Company)
                        FROM ' + @QualifiedTable + N' AS target
                        JOIN #RowMap AS rm
                          ON rm.WorkID = @pWorkID AND rm.EntryID = target.BPA_EntryID;';
                    EXEC sys.sp_executesql @Sql, N'@pWorkID int', @pWorkID = @WorkID;
                END;
            END;

            /* Queue each structural/repeated child group as one child table. */
            DECLARE ChildCursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT e.LocalName
                FROM #Instance AS i
                JOIN #Element AS e ON e.ParentElementID = i.ElementID
                WHERE i.WorkID = @WorkID
                GROUP BY e.LocalName
                HAVING EXISTS
                       (
                           SELECT 1
                           FROM #Instance AS pi
                           JOIN #Element AS ce ON ce.ParentElementID = pi.ElementID
                           WHERE pi.WorkID = @WorkID
                             AND ce.LocalName = e.LocalName
                             AND
                             (
                                 EXISTS (SELECT 1 FROM #Element AS ge WHERE ge.ParentElementID = ce.ElementID)
                                 OR EXISTS (SELECT 1 FROM #Attribute AS ca WHERE ca.ParentElementID = ce.ElementID)
                             )
                       )
                    OR 1 <
                       (
                           SELECT MAX(x.ItemCount)
                           FROM
                           (
                               SELECT COUNT(*) AS ItemCount
                               FROM #Element AS se
                               JOIN #Instance AS si ON si.ElementID = se.ParentElementID
                               WHERE si.WorkID = @WorkID
                                 AND se.LocalName = e.LocalName
                               GROUP BY si.ElementID
                           ) AS x
                       )
                ORDER BY e.LocalName;

            OPEN ChildCursor;
            FETCH NEXT FROM ChildCursor INTO @ChildName;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF LEN(@TableName) + 1 + LEN(@ChildName) > 128
                    THROW 50007, 'A generated child table name exceeds SQL Server''s 128-character identifier limit.', 1;

                SET @ChildTableName = CONVERT(sysname, @TableName + N'_' + @ChildName);

                INSERT #Work (SchemaName, TableName, ParentWorkID)
                VALUES (@SchemaName, @ChildTableName, @WorkID);

                SET @ChildWorkID = CONVERT(int, SCOPE_IDENTITY());

                INSERT #Instance (WorkID, ElementID, ParentEntryID)
                SELECT @ChildWorkID, child.ElementID, parentMap.EntryID
                FROM #Instance AS parentInstance
                JOIN #RowMap AS parentMap
                  ON parentMap.WorkID = @WorkID
                 AND parentMap.ElementID = parentInstance.ElementID
                JOIN #Element AS child
                  ON child.ParentElementID = parentInstance.ElementID
                 AND child.LocalName = @ChildName
                WHERE parentInstance.WorkID = @WorkID;

                FETCH NEXT FROM ChildCursor INTO @ChildName;
            END;

            CLOSE ChildCursor;
            DEALLOCATE ChildCursor;

            UPDATE #Work SET IsProcessed = 1 WHERE WorkID = @WorkID;
        END;

        EXEC sys.sp_xml_removedocument @DocumentHandle;
        SET @DocumentHandle = NULL;

        IF @StartedTransaction = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @DocumentHandle IS NOT NULL
            EXEC sys.sp_xml_removedocument @DocumentHandle;

        IF XACT_STATE() <> 0
        BEGIN
            IF @StartedTransaction = 1 OR XACT_STATE() = -1
                ROLLBACK TRANSACTION;
            ELSE
                ROLLBACK TRANSACTION BPA_ImportXml_Savepoint;
        END;

        THROW;
    END CATCH;
END;

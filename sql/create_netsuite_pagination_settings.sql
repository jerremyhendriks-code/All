/*
    Create tb_Netsuite_PaginationSettings: one row per NetSuite record type that is
    pulled in pages, holding the page size and where the current / last sync got to.
    Seeds rows for vendorBill and invoice.

    - page_size is capped at 1000, the maximum NetSuite returns per page.
    - current_offset is the offset of the next page to fetch; reset it to 0 when a
      sync finishes (has_more = 0).
    - last_modified_from is the incremental watermark: only records modified on or
      after it are requested. NULL means a full load.
    - Safe to re-run: the table is only created if missing, and seed rows are only
      inserted if their record_type isn't there yet (existing settings are kept).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.tb_Netsuite_PaginationSettings', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.tb_Netsuite_PaginationSettings (
        id                     int IDENTITY(1, 1) NOT NULL,
        record_type            nvarchar(50)       NOT NULL,
        is_enabled             bit                NOT NULL
            CONSTRAINT DF_tb_Netsuite_PaginationSettings_is_enabled     DEFAULT (1),
        page_size              int                NOT NULL
            CONSTRAINT DF_tb_Netsuite_PaginationSettings_page_size      DEFAULT (1000),
        current_offset         int                NOT NULL
            CONSTRAINT DF_tb_Netsuite_PaginationSettings_current_offset DEFAULT (0),
        total_results          int                NULL,
        has_more               bit                NOT NULL
            CONSTRAINT DF_tb_Netsuite_PaginationSettings_has_more       DEFAULT (0),
        last_modified_from     datetime2(0)       NULL,
        last_run_started_at    datetime2(0)       NULL,
        last_run_completed_at  datetime2(0)       NULL,
        created_at             datetime2(0)       NOT NULL
            CONSTRAINT DF_tb_Netsuite_PaginationSettings_created_at     DEFAULT (SYSUTCDATETIME()),
        updated_at             datetime2(0)       NOT NULL
            CONSTRAINT DF_tb_Netsuite_PaginationSettings_updated_at     DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_tb_Netsuite_PaginationSettings
            PRIMARY KEY CLUSTERED (id),
        CONSTRAINT UQ_tb_Netsuite_PaginationSettings_record_type
            UNIQUE (record_type),
        CONSTRAINT CK_tb_Netsuite_PaginationSettings_page_size
            CHECK (page_size BETWEEN 1 AND 1000),
        CONSTRAINT CK_tb_Netsuite_PaginationSettings_current_offset
            CHECK (current_offset >= 0),
        CONSTRAINT CK_tb_Netsuite_PaginationSettings_total_results
            CHECK (total_results IS NULL OR total_results >= 0)
    );

    PRINT N'Created dbo.[tb_Netsuite_PaginationSettings]';
END
ELSE
    PRINT N'Skipped dbo.[tb_Netsuite_PaginationSettings] (already exists)';

-- Seed settings for the paginated record types
INSERT INTO dbo.tb_Netsuite_PaginationSettings (record_type, page_size)
SELECT s.record_type, s.page_size
FROM (VALUES
        (N'vendorBill', 1000),
        (N'invoice',    1000)
     ) s (record_type, page_size)
WHERE NOT EXISTS (SELECT 1
                  FROM dbo.tb_Netsuite_PaginationSettings p
                  WHERE p.record_type = s.record_type);

PRINT N'Seeded ' + CAST(@@ROWCOUNT AS nvarchar(10)) + N' row(s)';

COMMIT TRANSACTION;

-- Verify
SELECT id, record_type, is_enabled, page_size, current_offset, total_results, has_more,
       last_modified_from, last_run_started_at, last_run_completed_at, created_at, updated_at
FROM dbo.tb_Netsuite_PaginationSettings
ORDER BY record_type;

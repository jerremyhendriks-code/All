/*
    Adds dbo.tb_Companies.DateFilter: the "modified since" filter of an object.

    - NULL means: no filter yet, do a full load.
    - It stays the same for all pages of a run (only sp_Companies_Update
      changes it, at the end of a completed run: latest fetched
      lastmodifieddate minus an overlap).
    - Read it for the SuiteQL {{since}} placeholder, already formatted:

        SELECT Incremental_Filter = CONVERT(char(19), ISNULL(DateFilter, '19000101'), 120),
               Offset             = ISNULL(Offset, 0)
        FROM dbo.tb_Companies
        WHERE BPA_Origin = N'NetSuite_vendorBill' AND BPA_Company IS NULL;

      ('1900-01-01 00:00:00' when NULL, so the first run loads everything.)

    Safe to run more than once.
*/
IF COL_LENGTH(N'dbo.tb_Companies', N'DateFilter') IS NULL
    ALTER TABLE dbo.tb_Companies ADD DateFilter datetime NULL;
GO

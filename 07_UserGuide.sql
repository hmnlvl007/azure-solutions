-- ═══════════════════════════════════════════════════════════════════════
-- USER GUIDE: How to Upload Zip Codes (Self-Service)
--
-- You no longer need a DBA. Follow these steps.
--
-- HOW IT WORKS:
--   Every time you upload a new Excel file, the main ZipCodes table
--   is completely cleared out and replaced with the new data from
--   your file. A full snapshot of the previous data is saved
--   automatically so you can undo the upload if needed.
--
-- SUMMARY:
--   1. Clear the staging table
--   2. Load your Excel into the staging table
--   3. Preview the comparison (see what's different)
--   4. Apply → main table is wiped and reloaded from your file
--   5. (Optional) Rollback if something is wrong
-- ═══════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────
-- STEP 0: Clear the staging table before loading
-- ─────────────────────────────────────────────────────────────────────
-- ALWAYS do this first so leftover data from a prior upload doesn't
-- mix with your new file.

TRUNCATE TABLE dbo.ZipCodes_Staging;


-- ─────────────────────────────────────────────────────────────────────
-- STEP 1: Load your Excel file into the STAGING table
--
-- Choose ONE of the options below (A is easiest).
-- ─────────────────────────────────────────────────────────────────────

-- OPTION A: SSMS Import Wizard (Easiest — point and click)
--
-- 1. Open SSMS → connect to your server
-- 2. Right-click your database → Tasks → Import Data...
-- 3. Data Source: select "Microsoft Excel"
--    → Browse to your .xlsx file
-- 4. Destination: "SQL Server Native Client"
--    → Server name: your server
--    → Database: your database
-- 5. Select your Excel worksheet
-- 6. Destination table: dbo.ZipCodes_Staging   ← IMPORTANT: staging!
--    (Do NOT select dbo.ZipCodes — always load into staging first)
-- 7. Click Next → Finish → data loads into staging

-- OPTION B: From Excel itself
--
-- In Excel → Data tab → Get Data → From Database → From SQL Server
-- Connect to your server/database, then export your data.
-- Or simply copy rows in Excel, then in SSMS right-click
-- dbo.ZipCodes_Staging → Edit Top 200 Rows → paste.

-- OPTION C: Using OPENROWSET (if enabled on your server)
/*
INSERT INTO dbo.ZipCodes_Staging (ZipCode, City, State, County, TimeZone, AreaCode)
SELECT * FROM OPENROWSET(
    'Microsoft.ACE.OLEDB.12.0',
    'Excel 12.0;Database=C:\Uploads\ZipCodes.xlsx;HDR=YES',
    'SELECT * FROM [Sheet1$]'
);
*/


-- ─────────────────────────────────────────────────────────────────────
-- STEP 2: Preview the comparison (does NOT change the main table)
-- ─────────────────────────────────────────────────────────────────────
-- This compares your new staging data against the current main table
-- and shows you a side-by-side report of differences:
--   • NEW zip codes that will appear after the reload
--   • REMOVED zip codes that exist now but are not in your file
--   • MODIFIED zip codes where fields like City/State/County changed
--   • UNCHANGED rows (matching in both)
-- It also gives you a Batch ID for the next step.

EXEC dbo.usp_ZipCode_ProcessUpload @UploadedBy = 'YourName';

-- Review the output carefully before proceeding.


-- ─────────────────────────────────────────────────────────────────────
-- STEP 3: Apply — Replace the main table with your new data
-- ─────────────────────────────────────────────────────────────────────
-- ⚠ This will:
--   1. Save a snapshot of ALL current rows (for rollback)
--   2. DELETE everything from the main ZipCodes table
--   3. INSERT all rows from your staged Excel data
--   4. Clear the staging table
--
-- Replace 1 with the Batch ID shown in Step 2:

EXEC dbo.usp_ZipCode_ApplyUpload @BatchId = 1;


-- ─────────────────────────────────────────────────────────────────────
-- STEP 4 (if needed): Undo — Restore the previous data
-- ─────────────────────────────────────────────────────────────────────
-- Made a mistake? This will:
--   1. DELETE everything from the main ZipCodes table
--   2. Restore all the rows that were in the table BEFORE your upload
--
-- Replace 1 with the Batch ID you want to undo:

EXEC dbo.usp_ZipCode_RollbackUpload @BatchId = 1;


-- ─────────────────────────────────────────────────────────────────────
-- BONUS: View upload history and past batch details
-- ─────────────────────────────────────────────────────────────────────

-- See the last 20 uploads (who uploaded, when, how many rows, status):
EXEC dbo.usp_ZipCode_ViewHistory;

-- See the detailed snapshot for a specific batch:
EXEC dbo.usp_ZipCode_ViewBatchDetails @BatchId = 1;


-- ─────────────────────────────────────────────────────────────────────
-- QUICK REFERENCE (copy-paste these 3 commands each time)
-- ─────────────────────────────────────────────────────────────────────
/*
-- 1. Clear staging
TRUNCATE TABLE dbo.ZipCodes_Staging;

-- 2. Load your Excel via Import Wizard into dbo.ZipCodes_Staging

-- 3. Preview
EXEC dbo.usp_ZipCode_ProcessUpload @UploadedBy = 'YourName';

-- 4. Apply (use the Batch ID from step 3)
EXEC dbo.usp_ZipCode_ApplyUpload @BatchId = ???;
*/

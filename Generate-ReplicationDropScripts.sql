-- ============================================================
-- Generate (or execute) sp_dropsubscription + sp_droparticle
-- from replication metadata for a list of articles/tables
-- ============================================================
-- Run on the PUBLISHER that can also reach the distribution DB.
--
-- WHAT IT DOES
--   1) Takes a list of article names.
--   2) Resolves ALL publications each article belongs to (via distributor).
--   3) Resolves exact subscriber/destination_db pairs from MSsubscriptions.
--   4) Emits in correct execution order:
--        a) sp_dropsubscription per concrete subscriber/destination_db
--        b) sp_dropsubscription @subscriber=N'all', @destination_db=N'all' (cleanup)
--        c) sp_droparticle
--
-- OUTPUT
--   - Result set 1: coverage summary (article -> publications)
--   - Result set 2: generated commands in execution order
--
-- Set @ExecuteGenerated = 1 to execute immediately instead of just generating.
-- ============================================================

SET NOCOUNT ON;

/* ------------------------------------------------------------
   CONFIGURATION
   ------------------------------------------------------------ */
DECLARE @DistributionDB SYSNAME = N'distribution';
DECLARE @ExecuteGenerated BIT = 0;      -- 0 = generate only, 1 = execute generated commands
DECLARE @ForceInvalidateSnapshot BIT = 1; -- passed to sp_droparticle

/* ------------------------------------------------------------
   INPUT: article/table list
   ------------------------------------------------------------ */
DECLARE @InputArticles TABLE
(
    ArticleName SYSNAME NOT NULL PRIMARY KEY
);

INSERT INTO @InputArticles (ArticleName)
VALUES
    (N'YourArticle1'),
    (N'YourArticle2');

IF NOT EXISTS (SELECT 1 FROM @InputArticles)
BEGIN
    RAISERROR('No article names provided in @InputArticles.', 16, 1);
    RETURN;
END;

/* ------------------------------------------------------------
   STAGE 1: Resolve all publication/article mappings
   ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#InputBridge') IS NOT NULL DROP TABLE #InputBridge;
CREATE TABLE #InputBridge
(
    ArticleName SYSNAME NOT NULL PRIMARY KEY
);

INSERT INTO #InputBridge (ArticleName)
SELECT ArticleName
FROM @InputArticles;

IF OBJECT_ID('tempdb..#ResolvedArticles') IS NOT NULL DROP TABLE #ResolvedArticles;
CREATE TABLE #ResolvedArticles
(
    publisher_db   SYSNAME NOT NULL,
    publication    SYSNAME NOT NULL,
    publication_id INT     NOT NULL,
    article        SYSNAME NOT NULL,
    article_id     INT     NOT NULL
);

DECLARE @SqlResolveArticles NVARCHAR(MAX) = N'
SELECT
    p.publisher_db,
    p.publication,
    p.publication_id,
    a.article,
    a.article_id
FROM ' + QUOTENAME(@DistributionDB) + N'.dbo.MSarticles a
JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSpublications p
  ON p.publication_id = a.publication_id
JOIN #InputBridge i
  ON i.ArticleName = a.article;';

INSERT INTO #ResolvedArticles
(
    publisher_db,
    publication,
    publication_id,
    article,
    article_id
)
EXEC sys.sp_executesql @SqlResolveArticles;

IF NOT EXISTS (SELECT 1 FROM #ResolvedArticles)
BEGIN
    RAISERROR('No matching replication articles found for input list.', 16, 1);
    RETURN;
END;

/* Warn for input not found */
IF EXISTS
(
    SELECT 1
    FROM @InputArticles i
    LEFT JOIN #ResolvedArticles r
      ON r.article = i.ArticleName
    WHERE r.article IS NULL
)
BEGIN
    SELECT
        i.ArticleName AS MissingArticle
    FROM @InputArticles i
    LEFT JOIN #ResolvedArticles r
      ON r.article = i.ArticleName
    WHERE r.article IS NULL
    ORDER BY i.ArticleName;
END;

/* ------------------------------------------------------------
   STAGE 2: Build ordered drop commands
   ------------------------------------------------------------ --
   NOTE: sp_dropsubscription @subscriber=N'all', @destination_db=N'all'
   is the correct approach - it drops all subscriptions for the article
   in that publication regardless of subscriber. Resolving individual
   subscribers from MSsubscriptions is avoided because that table contains
   rows from all publications sharing the same article_id, which produces
   false matches across unrelated publications.
   ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#Output') IS NOT NULL DROP TABLE #Output;
CREATE TABLE #Output
(
    Seq             INT IDENTITY(1,1) PRIMARY KEY,
    CmdType         VARCHAR(30)   NOT NULL,
    publisher_db    SYSNAME       NULL,
    publication     SYSNAME       NULL,
    article         SYSNAME       NULL,
    subscriber_name SYSNAME       NULL,
    destination_db  SYSNAME       NULL,
    Cmd             NVARCHAR(MAX) NOT NULL
);

INSERT INTO #Output (CmdType, Cmd)
VALUES
(
    'HEADER',
    N'-- Generated: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 126)
    + NCHAR(13)+NCHAR(10) + N'-- Distribution DB: ' + QUOTENAME(@DistributionDB)
    + NCHAR(13)+NCHAR(10) + N'-- Order is important: dropsubscription before droparticle.'
);

/* Drop all subscriptions for each article/publication */
INSERT INTO #Output
(
    CmdType,
    publisher_db,
    publication,
    article,
    Cmd
)
SELECT
    'DROP_SUBSCRIPTION_ALL',
    ra.publisher_db,
    ra.publication,
    ra.article,
    N'USE ' + QUOTENAME(ra.publisher_db) + N';' + NCHAR(13)+NCHAR(10)
    + N'EXEC sp_dropsubscription' + NCHAR(13)+NCHAR(10)
    + N'    @publication = N''' + REPLACE(ra.publication, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @article = N''' + REPLACE(ra.article, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @subscriber = N''all'',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_db = N''all'';'
FROM #ResolvedArticles ra
GROUP BY
    ra.publisher_db,
    ra.publication,
    ra.article
ORDER BY
    ra.publisher_db,
    ra.publication,
    ra.article;

/* 3c) Drop article */
INSERT INTO #Output
(
    CmdType,
    publisher_db,
    publication,
    article,
    Cmd
)
SELECT
    'DROP_ARTICLE',
    ra.publisher_db,
    ra.publication,
    ra.article,
    N'USE ' + QUOTENAME(ra.publisher_db) + N';' + NCHAR(13)+NCHAR(10)
    + N'EXEC sp_droparticle' + NCHAR(13)+NCHAR(10)
    + N'    @publication = N''' + REPLACE(ra.publication, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @article = N''' + REPLACE(ra.article, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @force_invalidate_snapshot = ' + CAST(@ForceInvalidateSnapshot AS NVARCHAR(1)) + N';'
FROM #ResolvedArticles ra
GROUP BY
    ra.publisher_db,
    ra.publication,
    ra.article
ORDER BY
    ra.publisher_db,
    ra.publication,
    ra.article;

/* ------------------------------------------------------------
   STAGE 4: Show coverage and generated commands
   ------------------------------------------------------------ */
SELECT
    ra.article,
    COUNT(DISTINCT ra.publication_id) AS publication_count,
    STRING_AGG(CONVERT(NVARCHAR(400), ra.publisher_db + N'|' + ra.publication), N'; ')
        WITHIN GROUP (ORDER BY ra.publisher_db, ra.publication) AS publications
FROM #ResolvedArticles ra
GROUP BY ra.article
ORDER BY ra.article;

SELECT
    Seq,
    CmdType,
    publisher_db,
    publication,
    article,
    subscriber_name,
    destination_db,
    Cmd
FROM #Output
ORDER BY Seq;

/* ------------------------------------------------------------
   STAGE 5: Optional execution
   ------------------------------------------------------------ */
IF @ExecuteGenerated = 1
BEGIN
    DECLARE @Seq INT, @Cmd NVARCHAR(MAX);

    DECLARE cur_exec CURSOR LOCAL FAST_FORWARD FOR
        SELECT Seq, Cmd
        FROM #Output
        WHERE CmdType <> 'HEADER'
        ORDER BY Seq;

    OPEN cur_exec;
    FETCH NEXT FROM cur_exec INTO @Seq, @Cmd;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT CONCAT('-- Executing Seq ', @Seq);
        EXEC sys.sp_executesql @Cmd;
        FETCH NEXT FROM cur_exec INTO @Seq, @Cmd;
    END;

    CLOSE cur_exec;
    DEALLOCATE cur_exec;

    PRINT 'Execution completed.';
END
ELSE
BEGIN
    PRINT 'Generation completed. Review Cmd output before execution.';
END;

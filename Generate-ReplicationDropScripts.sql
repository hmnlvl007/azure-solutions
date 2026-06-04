-- ============================================================
-- Generate (or execute) sp_dropsubscription + sp_droparticle
-- from replication metadata for a list of articles/tables
-- ============================================================
-- Run on the Publisher (or any server that can read distribution DB).
--
-- WHAT IT DOES
--   1) Takes a list of article names (typically table names).
--   2) Resolves ALL publications each article belongs to.
--   3) Resolves exact subscription endpoints for each article/publication.
--   4) Produces correctly parameterized statements in this order:
--        a) sp_dropsubscription (all concrete subscribers first)
--        b) sp_dropsubscription @subscriber='all', @destination_db='all' (safety cleanup)
--        c) sp_droparticle
--
-- OUTPUT
--   - Result set 1: coverage summary (article -> publication list)
--   - Result set 2: generated statements in execution order
--
-- OPTIONAL
--   Set @ExecuteGenerated = 1 to execute generated statements in order.
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
   STAGE 2: Resolve subscription endpoints per resolved article
   ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#ResolvedSubs') IS NOT NULL DROP TABLE #ResolvedSubs;
CREATE TABLE #ResolvedSubs
(
    publisher_db    SYSNAME NOT NULL,
    publication     SYSNAME NOT NULL,
    publication_id  INT     NOT NULL,
    article         SYSNAME NOT NULL,
    article_id      INT     NOT NULL,
    subscriber_name SYSNAME NULL,
    destination_db  SYSNAME NULL,
    subscription_id INT     NULL,
    subscription_type INT   NULL,
    subscription_status INT NULL
);

DECLARE @SqlResolveSubs NVARCHAR(MAX) = N'
SELECT
    p.publisher_db,
    p.publication,
    p.publication_id,
    a.article,
    a.article_id,
    rs.srvname AS subscriber_name,
    s.subscriber_db AS destination_db,
    s.subscription_id,
    s.subscription_type,
    s.status AS subscription_status
FROM ' + QUOTENAME(@DistributionDB) + N'.dbo.MSsubscriptions s
JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSarticles a
  ON a.article_id = s.article_id
JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSpublications p
  ON p.publication_id = a.publication_id
LEFT JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSreplservers rs
  ON rs.srvid = s.subscriber_id
JOIN #ResolvedArticles ra
  ON ra.publication_id = p.publication_id
 AND ra.article_id = a.article_id;';

INSERT INTO #ResolvedSubs
(
    publisher_db,
    publication,
    publication_id,
    article,
    article_id,
    subscriber_name,
    destination_db,
    subscription_id,
    subscription_type,
    subscription_status
)
EXEC sys.sp_executesql @SqlResolveSubs;

/* ------------------------------------------------------------
   STAGE 3: Build ordered drop commands
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

/* 3a) Exact dropsubscription per subscriber/destination */
INSERT INTO #Output
(
    CmdType,
    publisher_db,
    publication,
    article,
    subscriber_name,
    destination_db,
    Cmd
)
SELECT
    'DROP_SUBSCRIPTION_EXACT',
    rs.publisher_db,
    rs.publication,
    rs.article,
    rs.subscriber_name,
    rs.destination_db,
    N'USE ' + QUOTENAME(rs.publisher_db) + N';' + NCHAR(13)+NCHAR(10)
    + N'EXEC sp_dropsubscription' + NCHAR(13)+NCHAR(10)
    + N'    @publication = N''' + REPLACE(rs.publication, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @article = N''' + REPLACE(rs.article, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @subscriber = N''' + REPLACE(rs.subscriber_name, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_db = N''' + REPLACE(rs.destination_db, N'''', N'''''') + N''';'
FROM #ResolvedSubs rs
WHERE rs.subscriber_name IS NOT NULL
  AND rs.destination_db  IS NOT NULL
GROUP BY
    rs.publisher_db,
    rs.publication,
    rs.article,
    rs.subscriber_name,
    rs.destination_db
ORDER BY
    rs.publisher_db,
    rs.publication,
    rs.article,
    rs.subscriber_name,
    rs.destination_db;

/* 3b) Safety cleanup for any remaining/anonymous subscriptions */
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

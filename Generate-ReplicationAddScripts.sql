-- ============================================================
-- Generate sp_addarticle + sp_addsubscription from replication metadata
-- ============================================================
-- Run on Publisher (or any server with read access to distribution DB).
--
-- WHAT THIS DOES
--   - Takes a list of article (table) names.
--   - Finds every publication each article belongs to.
--   - Generates:
--       1) sp_addarticle scripts (publisher DB context)
--       2) sp_addsubscription scripts for all matching subscriptions
--
-- OUTPUT
--   - Result set 1: coverage summary (article -> publications found)
--   - Result set 2: generated statements (ordered execution)
--
-- NOTES
--   - Review generated script before execution.
--   - This is a script generator; it does not execute addarticle/addsubscription.
-- ============================================================

SET NOCOUNT ON;

/* ------------------------------------------------------------
   CONFIG
   ------------------------------------------------------------ */
DECLARE @DistributionDB SYSNAME = N'distribution';
DECLARE @IncludeNoSyncOption BIT = 1;   -- include @sync_type = N'none' for addsubscription output

/* ------------------------------------------------------------
   INPUT ARTICLES (TABLE NAMES / ARTICLE NAMES)
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
    RAISERROR('No rows provided in @InputArticles.', 16, 1);
    RETURN;
END;

/* ------------------------------------------------------------
   Stage 1: Resolve every publication an input article is in
   ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#InputBridge') IS NOT NULL DROP TABLE #InputBridge;
CREATE TABLE #InputBridge (ArticleName SYSNAME NOT NULL PRIMARY KEY);

INSERT INTO #InputBridge (ArticleName)
SELECT ArticleName FROM @InputArticles;

IF OBJECT_ID('tempdb..#ResolvedArticles') IS NOT NULL DROP TABLE #ResolvedArticles;
CREATE TABLE #ResolvedArticles
(
    publisher_db       SYSNAME       NOT NULL,
    publication        SYSNAME       NOT NULL,
    publication_id     INT           NOT NULL,
    article_id         INT           NOT NULL,
    article            SYSNAME       NOT NULL,
    source_owner       SYSNAME       NULL,
    source_object      SYSNAME       NULL,
    destination_owner  SYSNAME       NULL,
    destination_object SYSNAME       NULL,
    pre_creation_cmd   TINYINT       NULL,
    schema_option      BINARY(8)     NULL,
    ins_cmd            NVARCHAR(255) NULL,
    upd_cmd            NVARCHAR(255) NULL,
    del_cmd            NVARCHAR(255) NULL,
    article_type       INT           NULL
);

DECLARE @SqlArticles NVARCHAR(MAX) = N'
SELECT
    p.publisher_db,
    p.publication,
    p.publication_id,
    a.article_id,
    a.article,
    a.source_owner,
    a.source_object,
    a.destination_owner,
    a.destination_object,
    a.pre_creation_cmd,
    a.schema_option,
    a.ins_cmd,
    a.upd_cmd,
    a.del_cmd,
    a.type AS article_type
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
    article_id,
    article,
    source_owner,
    source_object,
    destination_owner,
    destination_object,
    pre_creation_cmd,
    schema_option,
    ins_cmd,
    upd_cmd,
    del_cmd,
    article_type
)
EXEC sys.sp_executesql @SqlArticles;

IF NOT EXISTS (SELECT 1 FROM #ResolvedArticles)
BEGIN
    RAISERROR('No matching articles found in replication metadata.', 16, 1);
    RETURN;
END;

/* Warn on not found input articles */
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
   Stage 2: Resolve subscriptions for all resolved article/publication pairs
   ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#ResolvedSubscriptions') IS NOT NULL DROP TABLE #ResolvedSubscriptions;
CREATE TABLE #ResolvedSubscriptions
(
    publisher_db       SYSNAME NOT NULL,
    publication        SYSNAME NOT NULL,
    publication_id     INT     NOT NULL,
    article            SYSNAME NOT NULL,
    article_id         INT     NOT NULL,
    subscriber_name    SYSNAME NULL,
    destination_db     SYSNAME NULL,
    subscription_type  INT     NULL,
    sync_type          INT     NULL,
    update_mode        INT     NULL
);

DECLARE @SqlSubs NVARCHAR(MAX) = N'
SELECT
    p.publisher_db,
    p.publication,
    p.publication_id,
    a.article,
    a.article_id,
    rs.srvname AS subscriber_name,
    s.subscriber_db AS destination_db,
    s.subscription_type,
    s.sync_type,
    s.update_mode
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

INSERT INTO #ResolvedSubscriptions
(
    publisher_db,
    publication,
    publication_id,
    article,
    article_id,
    subscriber_name,
    destination_db,
    subscription_type,
    sync_type,
    update_mode
)
EXEC sys.sp_executesql @SqlSubs;

/* ------------------------------------------------------------
   Stage 3: Build output statements in execution order
   ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#Output') IS NOT NULL DROP TABLE #Output;
CREATE TABLE #Output
(
    Seq              INT IDENTITY(1,1) PRIMARY KEY,
    ScriptType       VARCHAR(20)   NOT NULL,
    publisher_db     SYSNAME       NULL,
    publication      SYSNAME       NULL,
    article          SYSNAME       NULL,
    subscriber_name  SYSNAME       NULL,
    destination_db   SYSNAME       NULL,
    Cmd              NVARCHAR(MAX) NOT NULL
);

/* Header row */
INSERT INTO #Output (ScriptType, Cmd)
VALUES
(
    'HEADER',
    N'-- Generated: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 126)
    + NCHAR(13)+NCHAR(10) + N'-- Distribution DB: ' + QUOTENAME(@DistributionDB)
    + NCHAR(13)+NCHAR(10) + N'-- Review before running in target environment.'
);

/* Addarticle */
INSERT INTO #Output
(
    ScriptType,
    publisher_db,
    publication,
    article,
    Cmd
)
SELECT
    'ADDARTICLE',
    ra.publisher_db,
    ra.publication,
    ra.article,
    N'USE ' + QUOTENAME(ra.publisher_db) + N';' + NCHAR(13)+NCHAR(10)
    + N'EXEC sp_addarticle' + NCHAR(13)+NCHAR(10)
    + N'    @publication = N''' + REPLACE(ra.publication, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @article = N''' + REPLACE(ra.article, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @source_owner = N''' + REPLACE(ISNULL(ra.source_owner, N'dbo'), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @source_object = N''' + REPLACE(ISNULL(ra.source_object, ra.article), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_owner = N''' + REPLACE(ISNULL(ra.destination_owner, N'dbo'), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_table = N''' + REPLACE(ISNULL(ra.destination_object, ra.article), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @pre_creation_cmd = N''' +
        CASE ISNULL(ra.pre_creation_cmd, 0)
            WHEN 0 THEN N'none'
            WHEN 1 THEN N'drop'
            WHEN 2 THEN N'delete'
            WHEN 3 THEN N'truncate'
            ELSE N'none'
        END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @schema_option = 0x' + CONVERT(VARCHAR(16), CONVERT(BINARY(8), ISNULL(ra.schema_option, 0x0000000000000000)), 2) + N',' + NCHAR(13)+NCHAR(10)
    + N'    @ins_cmd = N''' + REPLACE(ISNULL(ra.ins_cmd, N'CALL sp_MSins_' + ra.article), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @upd_cmd = N''' + REPLACE(ISNULL(ra.upd_cmd, N'SCALL sp_MSupd_' + ra.article), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @del_cmd = N''' + REPLACE(ISNULL(ra.del_cmd, N'SCALL sp_MSdel_' + ra.article), N'''', N'''''') + N''';'
FROM #ResolvedArticles ra
GROUP BY
    ra.publisher_db, ra.publication, ra.article,
    ra.source_owner, ra.source_object, ra.destination_owner, ra.destination_object,
    ra.pre_creation_cmd, ra.schema_option, ra.ins_cmd, ra.upd_cmd, ra.del_cmd
ORDER BY ra.publisher_db, ra.publication, ra.article;

/* Addsubscription */
INSERT INTO #Output
(
    ScriptType,
    publisher_db,
    publication,
    article,
    subscriber_name,
    destination_db,
    Cmd
)
SELECT
    'ADDSUBSCRIPTION',
    rs.publisher_db,
    rs.publication,
    rs.article,
    rs.subscriber_name,
    rs.destination_db,
    N'USE ' + QUOTENAME(rs.publisher_db) + N';' + NCHAR(13)+NCHAR(10)
    + N'EXEC sp_addsubscription' + NCHAR(13)+NCHAR(10)
    + N'    @publication = N''' + REPLACE(rs.publication, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @article = N''' + REPLACE(rs.article, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @subscriber = N''' + REPLACE(rs.subscriber_name, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_db = N''' + REPLACE(rs.destination_db, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @subscription_type = N''' +
        CASE ISNULL(rs.subscription_type, 0)
            WHEN 0 THEN N'push'
            WHEN 1 THEN N'pull'
            WHEN 2 THEN N'anonymous'
            ELSE N'push'
        END + N''''
    + CASE WHEN @IncludeNoSyncOption = 1 THEN
        N',' + NCHAR(13)+NCHAR(10) + N'    @sync_type = N''none'''
      ELSE N''
      END
    + N';'
FROM #ResolvedSubscriptions rs
WHERE rs.subscriber_name IS NOT NULL
  AND rs.destination_db  IS NOT NULL
GROUP BY
    rs.publisher_db, rs.publication, rs.article,
    rs.subscriber_name, rs.destination_db,
    rs.subscription_type
ORDER BY
    rs.publisher_db, rs.publication, rs.article,
    rs.subscriber_name, rs.destination_db;

/* ------------------------------------------------------------
   Stage 4: Results
   ------------------------------------------------------------ */

-- Coverage summary: proves all publications per input article are captured.
SELECT
    ra.article,
    COUNT(DISTINCT ra.publication_id) AS publication_count,
    STRING_AGG(CONVERT(NVARCHAR(400), ra.publisher_db + N'|' + ra.publication), N'; ')
        WITHIN GROUP (ORDER BY ra.publisher_db, ra.publication) AS publications
FROM #ResolvedArticles ra
GROUP BY ra.article
ORDER BY ra.article;

-- Generated scripts: execute in Seq order.
SELECT
    Seq,
    ScriptType,
    publisher_db,
    publication,
    article,
    subscriber_name,
    destination_db,
    Cmd
FROM #Output
ORDER BY Seq;

PRINT 'Done. Review output, then run Cmd rows in Seq order.';

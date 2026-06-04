-- ============================================================
-- Generate sp_addarticle + sp_addsubscription from replication metadata
-- ============================================================
-- Run on the PUBLISHER that can also reach the distribution DB
-- (standard topology: publisher is configured to access distributor).
--
-- WHAT THIS DOES
--   1) Resolves every publication each input article belongs to
--      by querying the distribution database.
--   2) Fetches full article parameters from sysarticles on the publisher DB
--      (type, status, pre_creation_cmd, schema_option, ins_cmd, upd_cmd,
--       del_cmd, creation_script, description, identityrangemanagementoption,
--       vertical_partition).
--   3) Resolves all subscriptions from MSsubscriptions.
--   4) Emits correctly parameterized sp_addarticle + sp_addsubscription
--      matching SSMS-generated script format.
--
-- RUN ON: Publisher (has access to both publisher DBs and distribution DB)
-- ============================================================

SET NOCOUNT ON;

/* ------------------------------------------------------------
   CONFIG
   ------------------------------------------------------------ */
DECLARE @DistributionDB SYSNAME = N'distribution';

/* ------------------------------------------------------------
   INPUT ARTICLES
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
   STAGE 1: Resolve publication/article mappings from distributor
   ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#InputBridge')     IS NOT NULL DROP TABLE #InputBridge;
IF OBJECT_ID('tempdb..#ResolvedArticles') IS NOT NULL DROP TABLE #ResolvedArticles;
IF OBJECT_ID('tempdb..#ArticleDetail')   IS NOT NULL DROP TABLE #ArticleDetail;
IF OBJECT_ID('tempdb..#ResolvedSubs')    IS NOT NULL DROP TABLE #ResolvedSubs;
IF OBJECT_ID('tempdb..#Output')          IS NOT NULL DROP TABLE #Output;

CREATE TABLE #InputBridge (ArticleName SYSNAME NOT NULL PRIMARY KEY);
INSERT INTO #InputBridge (ArticleName) SELECT ArticleName FROM @InputArticles;

-- Basic mapping from distributor: publisher_db, publication, article identifiers
CREATE TABLE #ResolvedArticles
(
    publisher_db       SYSNAME NOT NULL,
    publication        SYSNAME NOT NULL,
    publication_id     INT     NOT NULL,
    article_id         INT     NOT NULL,
    article            SYSNAME NOT NULL,
    source_owner       SYSNAME NULL,
    source_object      SYSNAME NULL,
    destination_owner  SYSNAME NULL,  -- from MSarticles.destination_owner
    destination_object SYSNAME NULL   -- from MSarticles.destination_object
);

DECLARE @Sql1 NVARCHAR(MAX) = N'
SELECT
    p.publisher_db,
    p.publication,
    p.publication_id,
    a.article_id,
    a.article,
    a.source_owner,
    a.source_object,
    a.destination_owner,
    a.destination_object
FROM ' + QUOTENAME(@DistributionDB) + N'.dbo.MSarticles a
JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSpublications p
  ON p.publication_id = a.publication_id
JOIN #InputBridge i
  ON i.ArticleName = a.article;';

INSERT INTO #ResolvedArticles
    (publisher_db, publication, publication_id, article_id, article,
     source_owner, source_object, destination_owner, destination_object)
EXEC sys.sp_executesql @Sql1;

IF NOT EXISTS (SELECT 1 FROM #ResolvedArticles)
BEGIN
    RAISERROR('No matching articles found in distribution metadata.', 16, 1);
    RETURN;
END;

-- Warn on missing articles
IF EXISTS
(
    SELECT 1 FROM @InputArticles i
    LEFT JOIN #ResolvedArticles r ON r.article = i.ArticleName
    WHERE r.article IS NULL
)
BEGIN
    SELECT i.ArticleName AS MissingArticle
    FROM @InputArticles i
    LEFT JOIN #ResolvedArticles r ON r.article = i.ArticleName
    WHERE r.article IS NULL
    ORDER BY i.ArticleName;
END;

/* ------------------------------------------------------------
   STAGE 2: Fetch full article parameters from sysarticles
             on each publisher DB (cursor per unique publisher_db)
   ------------------------------------------------------------ */
CREATE TABLE #ArticleDetail
(
    publisher_db                    SYSNAME       NOT NULL,
    publication                     SYSNAME       NOT NULL,
    article                         SYSNAME       NOT NULL,
    article_type                    TINYINT       NULL,  -- sysarticles.type
    article_status                  TINYINT       NULL,  -- sysarticles.status
    description                     NVARCHAR(255) NULL,
    creation_script                 NVARCHAR(255) NULL,
    pre_creation_cmd                TINYINT       NULL,
    schema_option                   BINARY(8)     NULL,
    ins_cmd                         NVARCHAR(255) NULL,
    upd_cmd                         NVARCHAR(255) NULL,
    del_cmd                         NVARCHAR(255) NULL,
    dest_object                     SYSNAME       NULL,  -- sysarticles.dest_object
    dest_owner                      SYSNAME       NULL,  -- sysarticles.dest_owner
    vertical_partition              BIT           NULL,
    identityrangemanagementoption   INT           NULL
);

DECLARE @pub_db SYSNAME;

DECLARE cur_pubdb CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT publisher_db FROM #ResolvedArticles;

OPEN cur_pubdb;
FETCH NEXT FROM cur_pubdb INTO @pub_db;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @Sql2 NVARCHAR(MAX) = N'
    SELECT
        ra.publisher_db,
        ra.publication,
        ra.article,
        sa.type              AS article_type,
        sa.status            AS article_status,
        sa.description,
        sa.creation_script,
        sa.pre_creation_cmd,
        sa.schema_option,
        sa.ins_cmd,
        sa.upd_cmd,
        sa.del_cmd,
        sa.dest_object,
        sa.dest_owner,
        sa.vertical_partition,
        sa.identityrangemanagementoption
    FROM ' + QUOTENAME(@pub_db) + N'.dbo.sysarticles sa
    JOIN ' + QUOTENAME(@pub_db) + N'.dbo.syspublications sp
      ON sp.pubid = sa.pubid
    JOIN #ResolvedArticles ra
      ON ra.article = sa.name
     AND ra.publication = sp.name
     AND ra.publisher_db = N''' + REPLACE(@pub_db, N'''', N'''''') + N''';';

    INSERT INTO #ArticleDetail
    (
        publisher_db, publication, article,
        article_type, article_status, description, creation_script,
        pre_creation_cmd, schema_option, ins_cmd, upd_cmd, del_cmd,
        dest_object, dest_owner, vertical_partition, identityrangemanagementoption
    )
    EXEC sys.sp_executesql @Sql2;

    FETCH NEXT FROM cur_pubdb INTO @pub_db;
END;

CLOSE cur_pubdb;
DEALLOCATE cur_pubdb;

/* ------------------------------------------------------------
   STAGE 3: Resolve subscriptions from distributor
   ------------------------------------------------------------ */
CREATE TABLE #ResolvedSubs
(
    publisher_db      SYSNAME NOT NULL,
    publication       SYSNAME NOT NULL,
    article           SYSNAME NOT NULL,
    subscriber_name   SYSNAME NULL,
    destination_db    SYSNAME NULL,
    subscription_type INT     NULL,  -- 0=push, 1=pull, 2=anonymous
    sync_type         INT     NULL,  -- 1=automatic, 2=replication support only, 3=init with backup, 4=none
    update_mode       INT     NULL,  -- 0=read only, 1=sync tran, 2=queued tran
    subscriber_type   INT     NULL   -- 0=MSSQL, 1=ODBC, 3=OLE-DB
);

DECLARE @Sql3 NVARCHAR(MAX) = N'
SELECT
    p.publisher_db,
    p.publication,
    a.article,
    srv.srvname  AS subscriber_name,
    s.subscriber_db AS destination_db,
    s.subscription_type,
    s.sync_type,
    s.update_mode,
    s.subscriber_type
FROM ' + QUOTENAME(@DistributionDB) + N'.dbo.MSsubscriptions s
JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSarticles a
  ON a.article_id = s.article_id
JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSpublications p
  ON p.publication_id = a.publication_id
LEFT JOIN ' + QUOTENAME(@DistributionDB) + N'.dbo.MSreplservers srv
  ON srv.srvid = s.subscriber_id
JOIN #ResolvedArticles ra
  ON ra.publication_id = p.publication_id
 AND ra.article_id     = a.article_id
WHERE srv.srvname IS NOT NULL
  AND s.subscriber_db IS NOT NULL;';

INSERT INTO #ResolvedSubs
    (publisher_db, publication, article, subscriber_name, destination_db,
     subscription_type, sync_type, update_mode, subscriber_type)
EXEC sys.sp_executesql @Sql3;

/* ------------------------------------------------------------
   STAGE 4: Build output
   ------------------------------------------------------------ */
CREATE TABLE #Output
(
    Seq             INT IDENTITY(1,1) PRIMARY KEY,
    ScriptType      VARCHAR(20)   NOT NULL,
    publisher_db    SYSNAME       NULL,
    publication     SYSNAME       NULL,
    article         SYSNAME       NULL,
    subscriber_name SYSNAME       NULL,
    destination_db  SYSNAME       NULL,
    Cmd             NVARCHAR(MAX) NOT NULL
);

INSERT INTO #Output (ScriptType, Cmd)
VALUES
(
    'HEADER',
    N'-- Generated: ' + CONVERT(NVARCHAR(30), SYSDATETIME(), 126)
    + NCHAR(13)+NCHAR(10) + N'-- Distribution DB: ' + QUOTENAME(@DistributionDB)
    + NCHAR(13)+NCHAR(10) + N'-- Review before running in target environment.'
);

/* sp_addarticle - all parameters sourced from sysarticles */
INSERT INTO #Output (ScriptType, publisher_db, publication, article, Cmd)
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
    + N'    @type = N''' +
        CASE ISNULL(ad.article_type, 1)
            WHEN 1  THEN N'logbased'
            WHEN 3  THEN N'logbased manualboth'
            WHEN 5  THEN N'indexed view logbased'
            WHEN 7  THEN N'indexed view logbased manualboth'
            WHEN 8  THEN N'serializable'
            ELSE N'logbased'
        END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @description = N''' + REPLACE(ISNULL(ad.description, N''), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @creation_script = N''' + REPLACE(ISNULL(ad.creation_script, N''), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @pre_creation_cmd = N''' +
        CASE ISNULL(ad.pre_creation_cmd, 1)
            WHEN 0 THEN N'none'
            WHEN 1 THEN N'drop'
            WHEN 2 THEN N'delete'
            WHEN 3 THEN N'truncate'
            ELSE N'drop'
        END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @schema_option = 0x' + CONVERT(VARCHAR(16), CONVERT(BINARY(8), ISNULL(ad.schema_option, 0x00000000000000000)), 2) + N',' + NCHAR(13)+NCHAR(10)
    + N'    @identityrangemanagementoption = N''' +
        CASE ISNULL(ad.identityrangemanagementoption, 0)
            WHEN 0 THEN N'none'
            WHEN 1 THEN N'manual'
            WHEN 2 THEN N'auto'
            ELSE N'none'
        END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_table = N''' + REPLACE(ISNULL(ad.dest_object, ISNULL(ra.destination_object, ra.article)), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_owner = N''' + REPLACE(ISNULL(ad.dest_owner, ISNULL(ra.destination_owner, N'dbo')), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @status = ' + CAST(ISNULL(ad.article_status, 24) AS NVARCHAR(10)) + N',' + NCHAR(13)+NCHAR(10)
    + N'    @vertical_partition = N''' + CASE ISNULL(ad.vertical_partition, 0) WHEN 1 THEN N'true' ELSE N'false' END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @ins_cmd = N''' + REPLACE(ISNULL(ad.ins_cmd, N'CALL sp_MSins_' + ra.article), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @upd_cmd = N''' + REPLACE(ISNULL(ad.upd_cmd, N'SCALL sp_MSupd_' + ra.article), N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @del_cmd = N''' + REPLACE(ISNULL(ad.del_cmd, N'XCALL sp_MSdel_' + ra.article), N'''', N'''''') + N''';'
FROM #ResolvedArticles ra
LEFT JOIN #ArticleDetail ad
  ON ad.publisher_db = ra.publisher_db
 AND ad.publication  = ra.publication
 AND ad.article      = ra.article
ORDER BY ra.publisher_db, ra.publication, ra.article;

/* sp_addsubscription - all parameters from MSsubscriptions */
INSERT INTO #Output (ScriptType, publisher_db, publication, article, subscriber_name, destination_db, Cmd)
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
    + N'    @subscriber = N''' + REPLACE(rs.subscriber_name, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @destination_db = N''' + REPLACE(rs.destination_db, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @subscription_type = N''' +
        CASE ISNULL(rs.subscription_type, 0)
            WHEN 0 THEN N'Push'
            WHEN 1 THEN N'Pull'
            WHEN 2 THEN N'anonymous'
            ELSE N'Push'
        END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @sync_type = N''' +
        CASE ISNULL(rs.sync_type, 2)
            WHEN 1 THEN N'automatic'
            WHEN 2 THEN N'replication support only'
            WHEN 3 THEN N'initialize with backup'
            WHEN 4 THEN N'none'
            ELSE N'replication support only'
        END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @article = N''' + REPLACE(rs.article, N'''', N'''''') + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @update_mode = N''' +
        CASE ISNULL(rs.update_mode, 0)
            WHEN 0 THEN N'read only'
            WHEN 1 THEN N'sync tran'
            WHEN 2 THEN N'queued tran'
            WHEN 3 THEN N'failover'
            WHEN 4 THEN N'queued failover'
            ELSE N'read only'
        END + N''',' + NCHAR(13)+NCHAR(10)
    + N'    @subscriber_type = ' + CAST(ISNULL(rs.subscriber_type, 0) AS NVARCHAR(1)) + N';'
FROM #ResolvedSubs rs
GROUP BY
    rs.publisher_db, rs.publication, rs.article,
    rs.subscriber_name, rs.destination_db,
    rs.subscription_type, rs.sync_type, rs.update_mode, rs.subscriber_type
ORDER BY
    rs.publisher_db, rs.publication, rs.article,
    rs.subscriber_name, rs.destination_db;

/* ------------------------------------------------------------
   STAGE 5: Results
   ------------------------------------------------------------ */

-- Coverage summary
SELECT
    ra.article,
    COUNT(DISTINCT ra.publication_id) AS publication_count,
    STRING_AGG(CONVERT(NVARCHAR(400), ra.publisher_db + N'|' + ra.publication), N'; ')
        WITHIN GROUP (ORDER BY ra.publisher_db, ra.publication) AS publications
FROM #ResolvedArticles ra
GROUP BY ra.article
ORDER BY ra.article;

-- Generated scripts in execution order
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

PRINT 'Done. Review Cmd column output before executing in target environment.';

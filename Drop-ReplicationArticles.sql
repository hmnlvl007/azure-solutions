-- ============================================================
-- Drop Replication Subscriptions and Articles
-- ============================================================
-- Run this script on the PUBLISHER server (which must have
-- access to the distribution database -- local or remote).
--
-- HOW IT WORKS:
--   1. Supply only the article names in @InputArticles.
--   2. The script queries MSarticles + MSpublications in the
--      distribution database to automatically resolve the
--      correct publisher database and publication name.
--   3. sp_dropsubscription and sp_droparticle are executed
--      inside the correct publisher database via dynamic USE.
-- ============================================================

SET NOCOUNT ON;

-- -------------------------------------------------------
-- CONFIGURATION
-- Change @DistributionDB if your distribution database is
-- not named 'distribution'.
-- -------------------------------------------------------
DECLARE @DistributionDB SYSNAME = N'distribution';

-- -------------------------------------------------------
-- INPUT: Provide only the article names here
-- -------------------------------------------------------
DECLARE @InputArticles TABLE (ArticleName SYSNAME NOT NULL);

INSERT INTO @InputArticles (ArticleName)
VALUES
    (N'YourArticle1'),
    (N'YourArticle2'),
    (N'AnotherArticle1');
-- Add more article names above as needed


-- -------------------------------------------------------
-- AUTO-DISCOVERY: Build IN-list and query distributor
-- metadata to resolve DatabaseName + PublicationName
-- -------------------------------------------------------
DECLARE @Resolved TABLE (
    DatabaseName    SYSNAME NOT NULL,
    PublicationName SYSNAME NOT NULL,
    ArticleName     SYSNAME NOT NULL
);

DECLARE
    @InList       NVARCHAR(MAX) = N'',
    @CurArticle   SYSNAME,
    @DiscoverSQL  NVARCHAR(MAX);

-- Build a quoted IN-list from @InputArticles
DECLARE input_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT ArticleName FROM @InputArticles;
OPEN input_cursor;
FETCH NEXT FROM input_cursor INTO @CurArticle;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @InList = @InList
               + CASE WHEN @InList = N'' THEN N'' ELSE N',' END
               + N'N''' + REPLACE(@CurArticle, N'''', N'''''') + N'''';
    FETCH NEXT FROM input_cursor INTO @CurArticle;
END;
CLOSE input_cursor;
DEALLOCATE input_cursor;

IF @InList = N''
BEGIN
    RAISERROR('No article names provided in @InputArticles. Exiting.', 16, 1);
    RETURN;
END;

-- Query distribution database for matching articles
SET @DiscoverSQL = CONCAT(
    N'SELECT
        p.publisher_db  AS DatabaseName,
        p.publication   AS PublicationName,
        a.article       AS ArticleName
    FROM ', QUOTENAME(@DistributionDB), N'.dbo.MSarticles     a
    JOIN ', QUOTENAME(@DistributionDB), N'.dbo.MSpublications  p
        ON a.publication_id = p.publication_id
    WHERE a.article IN (', @InList, N');'
);

PRINT '-- Discovery query:';
PRINT @DiscoverSQL;

INSERT INTO @Resolved (DatabaseName, PublicationName, ArticleName)
EXEC sp_executesql @DiscoverSQL;

-- -------------------------------------------------------
-- WARN about any articles not found in distribution DB
-- -------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM @InputArticles i
    LEFT JOIN @Resolved r ON r.ArticleName = i.ArticleName
    WHERE r.ArticleName IS NULL
)
BEGIN
    PRINT '';
    PRINT '-- WARNING: The following articles were NOT found in the distribution database and will be skipped:';
    SELECT i.ArticleName AS [Article Not Found - Skipped]
    FROM @InputArticles i
    LEFT JOIN @Resolved r ON r.ArticleName = i.ArticleName
    WHERE r.ArticleName IS NULL;
END;

-- -------------------------------------------------------
-- EXECUTION: Loop and drop subscriptions + articles
-- -------------------------------------------------------
DECLARE
    @DatabaseName    SYSNAME,
    @PublicationName SYSNAME,
    @ArticleName     SYSNAME,
    @SQL             NVARCHAR(MAX);

DECLARE article_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, PublicationName, ArticleName
    FROM   @Resolved
    ORDER  BY DatabaseName, PublicationName, ArticleName;

OPEN article_cursor;
FETCH NEXT FROM article_cursor INTO @DatabaseName, @PublicationName, @ArticleName;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT CONCAT(
        CHAR(13), CHAR(10),
        '-- Processing: [', @DatabaseName, '] | Publication: ', @PublicationName,
        ' | Article: ', @ArticleName
    );

    -- ---------------------------------------------------
    -- sp_dropsubscription
    -- ---------------------------------------------------
    SET @SQL = CONCAT(
        N'USE ', QUOTENAME(@DatabaseName), N';', CHAR(13), CHAR(10),
        N'EXEC sp_dropsubscription',                                                   CHAR(13), CHAR(10),
        N'    @publication    = N''', REPLACE(@PublicationName, N'''', N''''''), N''',', CHAR(13), CHAR(10),
        N'    @article        = N''', REPLACE(@ArticleName,     N'''', N''''''), N''',', CHAR(13), CHAR(10),
        N'    @subscriber     = N''all'',',                                            CHAR(13), CHAR(10),
        N'    @destination_db = N''all'';'
    );

    PRINT '-- sp_dropsubscription:';
    PRINT @SQL;
    EXEC sp_executesql @SQL;

    -- ---------------------------------------------------
    -- sp_droparticle
    -- ---------------------------------------------------
    SET @SQL = CONCAT(
        N'USE ', QUOTENAME(@DatabaseName), N';', CHAR(13), CHAR(10),
        N'EXEC sp_droparticle',                                                            CHAR(13), CHAR(10),
        N'    @publication              = N''', REPLACE(@PublicationName, N'''', N''''''), N''',', CHAR(13), CHAR(10),
        N'    @article                  = N''', REPLACE(@ArticleName,     N'''', N''''''), N''',', CHAR(13), CHAR(10),
        N'    @force_invalidate_snapshot = 1;'
    );

    PRINT '-- sp_droparticle:';
    PRINT @SQL;
    EXEC sp_executesql @SQL;

    FETCH NEXT FROM article_cursor INTO @DatabaseName, @PublicationName, @ArticleName;
END;

CLOSE article_cursor;
DEALLOCATE article_cursor;

PRINT CHAR(13) + CHAR(10) + '-- Done. All resolved articles processed.';

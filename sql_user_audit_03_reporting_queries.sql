/*
==============================================================================
SQL Server User Activity Audit - Reporting Queries
==============================================================================
Purpose:  Common queries for analyzing user activity captured in 
          DBA.dbo.UserActivityHistory table.

Target:   SQL Server 2019 Enterprise Edition
==============================================================================
*/

USE DBA;
GO

-- =============================================================================
-- QUERY 1: Recent login activity (last 24 hours)
-- =============================================================================
SELECT
    event_time_utc,
  (event_time_utc AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS event_time_pacific,
    server_principal_name,
    database_name,
    client_hostname,
    client_app_name,
    client_ip_address,
    is_success,
    event_name
FROM dbo.UserActivityHistory
WHERE event_name IN ('login', 'errorlog_written')
  AND event_time_utc >= DATEADD(HOUR, -24, GETUTCDATE())
ORDER BY event_time_utc DESC;
GO

-- =============================================================================
-- QUERY 2: Failed login attempts (security monitoring)
-- =============================================================================
SELECT
    event_time_utc,
  (event_time_utc AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS event_time_pacific,
    server_principal_name,
    client_hostname,
    client_ip_address,
    client_app_name,
    COUNT(*) OVER (PARTITION BY server_principal_name, client_ip_address) AS failed_attempts
FROM dbo.UserActivityHistory
WHERE event_name = 'errorlog_written'
  AND is_success = 0
  AND event_time_utc >= DATEADD(DAY, -7, GETUTCDATE())
ORDER BY event_time_utc DESC;
GO

-- =============================================================================
-- QUERY 3: Login summary by user (last 7 days)
-- =============================================================================
SELECT
    server_principal_name,
    COUNT(*) AS total_logins,
    COUNT(DISTINCT client_hostname) AS distinct_hosts,
    COUNT(DISTINCT client_ip_address) AS distinct_ips,
    MIN(event_time_utc) AS first_login,
    MAX(event_time_utc) AS last_login
FROM dbo.UserActivityHistory
WHERE event_name = 'login'
  AND event_time_utc >= DATEADD(DAY, -7, GETUTCDATE())
GROUP BY server_principal_name
ORDER BY total_logins DESC;
GO

-- =============================================================================
-- QUERY 4: Activity by database (last 7 days)
-- =============================================================================
SELECT
    database_name,
    COUNT(*) AS total_events,
    COUNT(DISTINCT server_principal_name) AS distinct_users,
    MIN(event_time_utc) AS first_activity,
    MAX(event_time_utc) AS last_activity
FROM dbo.UserActivityHistory
WHERE database_name IS NOT NULL
  AND event_time_utc >= DATEADD(DAY, -7, GETUTCDATE())
GROUP BY database_name
ORDER BY total_events DESC;
GO

-- =============================================================================
-- QUERY 5: Unusual activity - logins from new hosts/IPs
-- =============================================================================
WITH HistoricalHosts AS
(
    SELECT DISTINCT
        server_principal_name,
        client_hostname,
        client_ip_address
    FROM dbo.UserActivityHistory
    WHERE event_time_utc < DATEADD(DAY, -7, GETUTCDATE())
)
SELECT
    h.event_time_utc,
  (h.event_time_utc AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS event_time_pacific,
    h.server_principal_name,
    h.client_hostname,
    h.client_ip_address,
    h.client_app_name,
    'NEW HOST/IP FOR USER' AS alert_reason
FROM dbo.UserActivityHistory h
WHERE h.event_name = 'login'
  AND h.event_time_utc >= DATEADD(DAY, -7, GETUTCDATE())
  AND NOT EXISTS
  (
      SELECT 1
      FROM HistoricalHosts hh
      WHERE hh.server_principal_name = h.server_principal_name
        AND (hh.client_hostname = h.client_hostname OR hh.client_ip_address = h.client_ip_address)
  )
ORDER BY h.event_time_utc DESC;
GO

-- =============================================================================
-- QUERY 6: Session duration analysis (login to logout)
-- =============================================================================
WITH LoginLogout AS
(
    SELECT
        session_id,
        server_principal_name,
        client_hostname,
        event_name,
        event_time_utc,
        LEAD(event_time_utc) OVER (PARTITION BY session_id ORDER BY event_time_utc) AS next_event_time,
        LEAD(event_name) OVER (PARTITION BY session_id ORDER BY event_time_utc) AS next_event_name
    FROM dbo.UserActivityHistory
    WHERE event_name IN ('login', 'logout')
      AND session_id IS NOT NULL
      AND event_time_utc >= DATEADD(DAY, -7, GETUTCDATE())
)
SELECT
    session_id,
    server_principal_name,
    client_hostname,
    event_time_utc AS login_time,
  (event_time_utc AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS login_time_pacific,
    next_event_time AS logout_time,
  (next_event_time AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS logout_time_pacific,
    DATEDIFF(SECOND, event_time_utc, next_event_time) AS duration_seconds
FROM LoginLogout
WHERE event_name = 'login'
  AND next_event_name = 'logout'
ORDER BY duration_seconds DESC;
GO

-- =============================================================================
-- QUERY 7: Audit data volume and retention check
-- =============================================================================
SELECT
    CAST(event_time_utc AS date) AS audit_date,
    COUNT(*) AS event_count,
    COUNT(DISTINCT server_principal_name) AS distinct_users,
    COUNT(DISTINCT database_name) AS distinct_databases,
    SUM(DATALENGTH(statement_text)) / 1024.0 / 1024.0 AS statement_text_mb
FROM dbo.UserActivityHistory
GROUP BY CAST(event_time_utc AS date)
ORDER BY audit_date DESC;
GO

-- =============================================================================
-- QUERY 8: Top active users by event count
-- =============================================================================
SELECT TOP 20
    server_principal_name,
    event_name,
    COUNT(*) AS event_count,
    MAX(event_time_utc) AS last_event_time
FROM dbo.UserActivityHistory
WHERE event_time_utc >= DATEADD(DAY, -7, GETUTCDATE())
GROUP BY server_principal_name, event_name
ORDER BY event_count DESC;
GO

-- =============================================================================
-- QUERY 9: Application usage analysis
-- =============================================================================
SELECT
    client_app_name,
    COUNT(*) AS connection_count,
    COUNT(DISTINCT server_principal_name) AS distinct_users,
    MIN(event_time_utc) AS first_seen,
    MAX(event_time_utc) AS last_seen
FROM dbo.UserActivityHistory
WHERE event_name = 'login'
  AND event_time_utc >= DATEADD(DAY, -7, GETUTCDATE())
GROUP BY client_app_name
ORDER BY connection_count DESC;
GO

-- =============================================================================
-- MAINTENANCE: Purge old audit data (run periodically)
-- Adjust retention period per your compliance requirements
-- =============================================================================
/*
DECLARE @RetentionDays int = 90;
DECLARE @RowsDeleted int;

DELETE FROM dbo.UserActivityHistory
WHERE event_time_utc < DATEADD(DAY, -@RetentionDays, GETUTCDATE());

SET @RowsDeleted = @@ROWCOUNT;
PRINT 'Purged ' + CAST(@RowsDeleted AS varchar(10)) + ' rows older than ' + CAST(@RetentionDays AS varchar(10)) + ' days.';
*/
GO

-- ============================================================
-- Find publications where the next apply was 4+ hours after
-- the previous apply, and that previous apply was at or before 5 PM
-- Run on the DISTRIBUTION database
-- ============================================================
USE distribution;
GO

WITH ApplyHistory AS (
    SELECT
        srv_pub.name                          AS publisher,
        h.publisher_database_id,
        da.publisher_db,
        da.publication,
        da.subscriber_db,
        srv_sub.name                          AS subscriber,
        da.article,
        h.time                                AS apply_time,
        LEAD(h.time) OVER (
            PARTITION BY da.publisher_db, da.publication, srv_sub.name, da.subscriber_db
            ORDER BY h.time
        )                                     AS next_apply_time
    FROM dbo.MSdistribution_history      h
    JOIN dbo.MSdistribution_agents       da  ON h.agent_id = da.id
    JOIN sys.servers                     srv_pub ON srv_pub.server_id = da.publisher_id
    JOIN sys.servers                     srv_sub ON srv_sub.server_id = da.subscriber_id
    WHERE h.runstatus = 4          -- 4 = Idle (successful apply completed)
       OR h.runstatus = 3          -- 3 = In progress (had applied transactions)
)
SELECT
    publisher,
    publisher_db,
    publication,
    subscriber,
    subscriber_db,
    apply_time                                AS previous_apply_time,
    next_apply_time,
    DATEDIFF(MINUTE, apply_time, next_apply_time) AS gap_minutes,
    CONVERT(VARCHAR(5), DATEADD(MINUTE, DATEDIFF(MINUTE, apply_time, next_apply_time), 0), 108) AS gap_hh_mm
FROM ApplyHistory
WHERE next_apply_time IS NOT NULL
  AND CAST(apply_time AS TIME) <= '17:00:00'              -- previous apply at or before 5 PM
  AND DATEDIFF(MINUTE, apply_time, next_apply_time) >= 240 -- gap of 4+ hours
ORDER BY publisher_db, publication, subscriber, apply_time;
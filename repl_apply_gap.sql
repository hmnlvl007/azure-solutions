USE distribution;
GO

WITH AllApplies AS (
    SELECT
        srv_pub.name                          AS publisher,
        da.publisher_db,
        da.publication,
        da.subscriber_db,
        srv_sub.name                          AS subscriber,
        da.name                               AS agent_name,
        h.time                                AS apply_time,
        CAST(h.time AS DATE)                  AS apply_date
    FROM dbo.MSdistribution_history      h
    JOIN dbo.MSdistribution_agents       da  ON h.agent_id = da.id
    JOIN sys.servers                     srv_pub ON srv_pub.server_id = da.publisher_id
    JOIN sys.servers                     srv_sub ON srv_sub.server_id = da.subscriber_id
    WHERE h.runstatus IN (3, 4)
),
-- Last apply at or before 5 PM each day per publication/subscriber
LastBefore5PM AS (
    SELECT
        publisher,
        publisher_db,
        publication,
        subscriber,
        subscriber_db,
        agent_name,
        apply_date,
        MAX(apply_time) AS last_apply_before_5pm
    FROM AllApplies
    WHERE CAST(apply_time AS TIME) <= '17:00:00'
    GROUP BY publisher, publisher_db, publication, subscriber, subscriber_db, agent_name, apply_date
),
-- First apply AFTER that last-before-5PM apply
NextApply AS (
    SELECT
        lb.*,
        (   SELECT MIN(a.apply_time)
            FROM AllApplies a
            WHERE a.publisher_db  = lb.publisher_db
              AND a.publication   = lb.publication
              AND a.subscriber    = lb.subscriber
              AND a.subscriber_db = lb.subscriber_db
              AND a.apply_time    > lb.last_apply_before_5pm
        ) AS next_apply_time
    FROM LastBefore5PM lb
)
SELECT
    publisher,
    publisher_db,
    publication,
    subscriber,
    subscriber_db,
    agent_name,
    apply_date,
    last_apply_before_5pm                   AS previous_apply_time,
    next_apply_time,
    DATEDIFF(MINUTE, last_apply_before_5pm, next_apply_time) AS gap_minutes,
    CONVERT(VARCHAR(5), DATEADD(MINUTE, DATEDIFF(MINUTE, last_apply_before_5pm, next_apply_time), 0), 108) AS gap_hh_mm
FROM NextApply
WHERE next_apply_time IS NOT NULL
  AND DATEDIFF(MINUTE, last_apply_before_5pm, next_apply_time) >= 240
ORDER BY publisher_db, publication, subscriber, apply_date;
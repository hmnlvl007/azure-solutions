USE distribution;
GO

/* 1) Current distributor backlog */
SELECT
    COUNT_BIG(*) AS pending_commands
FROM dbo.MSrepl_commands;

SELECT
    COUNT_BIG(*) AS pending_transactions,
    MIN(entry_time) AS oldest_entry_time,
    DATEDIFF(minute, MIN(entry_time), GETDATE()) AS oldest_minutes
FROM dbo.MSrepl_transactions;


/* 2) Top 10 heaviest distribution agents in the last hour */
;WITH last_hour AS
(
    SELECT
        a.id,
        a.name,
        a.publication,
        a.subscriber_db,
        SUM(CAST(h.delivered_commands AS BIGINT)) AS commands_last_hour,
        SUM(CAST(h.delivered_transactions AS BIGINT)) AS transactions_last_hour,
        COUNT(*) AS history_rows_last_hour,
        MAX(h.time) AS last_hist_time
    FROM dbo.MSdistribution_agents a
    JOIN dbo.MSdistribution_history h
        ON a.id = h.agent_id
    WHERE h.time > DATEADD(hour, -1, GETDATE())
    GROUP BY
        a.id,
        a.name,
        a.publication,
        a.subscriber_db
),
latest_hist AS
(
    SELECT
        h.agent_id,
        h.time,
        h.delivery_latency,
        ROW_NUMBER() OVER
        (
            PARTITION BY h.agent_id
            ORDER BY h.time DESC
        ) AS rn
    FROM dbo.MSdistribution_history h
)
SELECT TOP (10)
    l.id AS agent_id,
    l.name AS distribution_agent,
    l.publication,
    l.subscriber_db,
    l.commands_last_hour,
    l.transactions_last_hour,
    l.history_rows_last_hour,
    lh.delivery_latency,
    l.last_hist_time
FROM last_hour l
LEFT JOIN latest_hist lh
    ON l.id = lh.agent_id
   AND lh.rn = 1
ORDER BY
    l.commands_last_hour DESC,
    lh.delivery_latency DESC;


/* 3) How many REPL-Distribution jobs are running right now */
SELECT
    COUNT(*) AS running_distribution_jobs
FROM msdb.dbo.sysjobactivity ja
JOIN msdb.dbo.sysjobs j
    ON ja.job_id = j.job_id
JOIN msdb.dbo.syscategories c
    ON j.category_id = c.category_id
WHERE c.name = 'REPL-Distribution'
  AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL;


/* 4) Which distribution jobs are running right now */
SELECT
    a.name AS distribution_agent,
    a.publication,
    a.subscriber_db,
    j.name AS job_name,
    ja.start_execution_date
FROM dbo.MSdistribution_agents a
JOIN msdb.dbo.sysjobs j
    ON a.job_id = j.job_id
JOIN msdb.dbo.sysjobactivity ja
    ON j.job_id = ja.job_id
JOIN msdb.dbo.syscategories c
    ON j.category_id = c.category_id
WHERE c.name = 'REPL-Distribution'
  AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
ORDER BY ja.start_execution_date;


/* 5) Last 50 retries/failures for distribution jobs */
SELECT TOP (50)
    j.name AS job_name,
    h.run_status,
    h.run_date,
    h.run_time,
    h.run_duration,
    h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j
    ON h.job_id = j.job_id
JOIN msdb.dbo.syscategories c
    ON j.category_id = c.category_id
WHERE c.name = 'REPL-Distribution'
  AND h.step_id > 0
  AND h.run_status IN (0,2)   -- 0 failed, 2 retry
ORDER BY h.instance_id DESC;
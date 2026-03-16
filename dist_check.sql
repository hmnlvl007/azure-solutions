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
    FROM distribution.dbo.MSdistribution_agents a
    JOIN distribution.dbo.MSdistribution_history h
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
    FROM distribution.dbo.MSdistribution_history h
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
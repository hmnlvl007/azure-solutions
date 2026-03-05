# SQL Server User Activity Audit

Production-ready solution for tracking user login and database activity across SQL Server 2019 Enterprise Edition instances using Extended Events.

## Overview

This audit solution captures:
- **User logins** (successful and failed)
- **User logouts**
- **Client connection details** (hostname, IP, application)
- **Optional: SQL statement activity** (when enabled with filters)

Data is stored in a centralized `DBA.dbo.UserActivityHistory` table for historical reporting and compliance.

## Performance Impact

- **Overhead**: <1% CPU when configured for login/logout only
- **Storage**: ~100-500 MB/day for typical medium-sized instance (depends on connection volume)
- **Retention**: Default 30 rollover files × 100 MB = ~3 GB on-disk XE history

## Deployment Steps

### 1. Prerequisites
- SQL Server 2019 Enterprise Edition on Windows Server 2019
- `sysadmin` or `ALTER ANY EVENT SESSION` permission
- SQL Server Agent enabled
- Local disk path `D:\SQLXE` available (or adjust path in scripts)

### 2. Deploy Infrastructure
Run `sql_user_audit_01_setup_infrastructure.sql` to:
- Create `DBA` database
- Create `UserActivityHistory` table with indexes
- Create and start `UserActivityAudit` Extended Events session

### 3. Deploy Ingestion Job
Run `sql_user_audit_02_agent_job_ingest.sql` to:
- Create SQL Agent job `DBA - Ingest User Activity Audit`
- Schedule runs every 15 minutes to load XE files into table

### 4. Verify Deployment
```sql
-- Check XE session status
SELECT name, startup_state 
FROM sys.server_event_sessions 
WHERE name = 'UserActivityAudit';

SELECT name 
FROM sys.dm_xe_sessions 
WHERE name = 'UserActivityAudit'; -- Should return 1 row if running

-- Check ingestion job
SELECT name, enabled, date_created 
FROM msdb.dbo.sysjobs 
WHERE name = 'DBA - Ingest User Activity Audit';

-- Check data ingestion
SELECT COUNT(*), MAX(event_time_utc) AS latest_event 
FROM DBA.dbo.UserActivityHistory;
```

### 5. Run Reports
Use queries in `sql_user_audit_03_reporting_queries.sql` for common analysis:
- Recent login activity
- Failed login attempts (security monitoring)
- Login summary by user
- Activity by database
- Unusual activity detection
- Session duration analysis
- Audit data volume/retention check
- Top active users
- Application usage analysis

## Configuration Options

### Enable Statement-Level Capture
Edit `sql_user_audit_01_setup_infrastructure.sql` and uncomment the `sql_batch_completed` and `rpc_completed` events.

**WARNING**: Statement capture can generate significant volume. Always use filters:
```sql
WHERE (
    -- Scope to specific critical databases only
    [sqlserver].[database_name] IN (N'ProductionDB1', N'ProductionDB2')
    -- Exclude system accounts
    AND [sqlserver].[is_system] = 0
    -- Optional: exclude SELECT to capture only writes
    AND [sqlserver].[batch_text] NOT LIKE N'%SELECT%'
)
```

### Adjust Retention
- **XE files**: Edit `max_rollover_files` in setup script (default: 30 files)
- **Table data**: Uncomment maintenance query in reporting script and schedule via Agent job

### Change Ingestion Frequency
Edit job schedule in `sql_user_audit_02_agent_job_ingest.sql`:
- Default: Every 15 minutes
- For real-time needs: Every 1-5 minutes
- For low-priority: Every 30-60 minutes

## Multi-Instance Deployment

To standardize this across multiple SQL Server instances:

1. **Manual deployment**: Run scripts on each instance using SSMS or `sqlcmd`
2. **Ansible playbook** (recommended for your environment):
   ```yaml
   - name: Deploy SQL user audit
     win_shell: |
       sqlcmd -S localhost -E -i "{{ item }}"
     loop:
       - C:\SQLServerInfra\scripts\sql_user_audit_01_setup_infrastructure.sql
       - C:\SQLServerInfra\scripts\sql_user_audit_02_agent_job_ingest.sql
   ```
3. **Central management**: Use registered servers or CMS to deploy to instance groups

## Troubleshooting

### XE session not capturing events
```sql
-- Check session is running
SELECT * FROM sys.dm_xe_sessions WHERE name = 'UserActivityAudit';

-- If stopped, start it
ALTER EVENT SESSION UserActivityAudit ON SERVER STATE = START;
```

### No data in history table
```sql
-- Check XE files exist
EXEC xp_cmdshell 'dir D:\SQLXE\*.xel';

-- Manually trigger ingestion job
EXEC msdb.dbo.sp_start_job @job_name = 'DBA - Ingest User Activity Audit';

-- Check job history for errors
SELECT TOP 10 * FROM msdb.dbo.sysjobhistory 
WHERE job_id = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = 'DBA - Ingest User Activity Audit')
ORDER BY run_date DESC, run_time DESC;
```

### High disk usage from XE files
- Reduce `max_file_size` or `max_rollover_files` in setup script
- Add more aggressive filters to reduce event volume
- Disable statement capture if enabled

## Security Considerations

- **Permissions**: Audit data contains usernames, IPs, and potentially sensitive SQL text
- **Access control**: Grant `SELECT` on `DBA.dbo.UserActivityHistory` only to authorized DBAs/security team
- **Retention**: Align with your compliance requirements (SOX, HIPAA, PCI-DSS, etc.)
- **Encryption**: Consider TDE on `DBA` database if audit data is highly sensitive

## Comparison to Alternatives

| Solution | Overhead | Retention | Setup Complexity | Cost |
|----------|----------|-----------|------------------|------|
| **Extended Events (this)** | <1% | Unlimited (table) | Low | Free |
| SQL Server Audit | <2% | Limited (file) | Low | Free (Enterprise only) |
| Default Trace | ~1% | Rolling 5 files | None (built-in) | Free but limited |
| SolarWinds/SQL Sentry | 2-5% | Per license | Medium | $$$ |
| Splunk/SIEM | Varies | Unlimited | High | $$$$ |

## Support

For questions or issues:
- Contact: DBA Team
- Repository: `c:\SQLServerInfra\scripts\`
- Last updated: 2026-03-05



# SQL Server Infrastructure & Automation Repository

**Organization:** [Your Organization]  
**Team:** DBA & Infrastructure Engineering  
**Last Updated:** March 5, 2026

---

## Purpose

This repository contains production-ready Infrastructure-as-Code (IaC), automation scripts, templates, and operational guidance for **standardizing, provisioning, and managing SQL Server instances** across enterprise datacenters. 

**Primary Goals:**
- Reduce manual effort and human error in SQL Server deployment and configuration
- Enforce consistent baselines across all instances (Windows Server 2019, SQL Server 2019 Enterprise)
- Provide auditability and compliance tracking for user activity and system changes
- Enable rapid incident-driven rebuilds and planned rollouts under change control
- Maintain long-term, reusable automation artifacts suitable for operational handoffs

---

## Repository Structure

```
SQLServerInfra/
├── README.md                                    # This file
├── installSQLServer2019EE.yml                   # Root Ansible playbook (planned deliverable)
│
├── playbooks/
│   └── installsqlserver2019ee.yml              # Main installation playbook for SQL Server 2019 EE
│
├── templates/
│   └── sql2019Conf.ini.j2                      # Template for SQL Server 2019 configuration file
│
├── group_vars/
│   └── runtimevars.example.yml                 # Example runtime variables for playbook execution
│
├── scripts/
│   ├── sql_user_audit_01_setup_infrastructure.sql   # Create DBA DB, audit table, XE session
│   ├── sql_user_audit_02_agent_job_ingest.sql       # SQL Agent job for ingesting XE data
│   ├── sql_user_audit_03_reporting_queries.sql      # Reporting queries for audit analysis
│   ├── sql_user_audit_README.md                     # Detailed user audit solution documentation
│   ├── sql2019Conf.ini                              # Example configuration file (reference)
│   ├── runtime-vars.example.yml                     # Legacy example (see group_vars/)
│   └── findings_resolution.md                       # Findings and resolution notes
│
└── inventories/                                 # Ansible inventory files (TBD)
```

---

## Key Solutions & Artifacts

### 1. SQL Server 2019 Enterprise Installation Playbook
**Location:** `playbooks/installsqlserver2019ee.yml`

Silent, idempotent installation of SQL Server 2019 Enterprise Edition on Windows Server 2019 Datacenter with:
- Infrastructure validation (OS, RAM, disk, media availability)
- Configuration file templating with runtime variables
- Service account setup and permissions
- Firewall rule creation (when enabled)
- Instant File Initialization (IFI) privilege grant
- Comprehensive logging and rollback support

**Target:** Windows Server 2019 Datacenter, x64, ≥6 GB RAM  
**Execution:** Manual (ad-hoc) or CI/CD pipeline  
**Status:** In development

---

### 2. SQL Server User Activity Audit Solution
**Location:** `scripts/sql_user_audit_*.sql`

Production-ready solution for capturing and reporting **user login activity** across SQL Server 2019 instances using SQL Server Extended Events (XE).

**Components:**
1. **Setup** (`sql_user_audit_01_setup_infrastructure.sql`)
   - Creates `DBA` administrative database
   - Creates `dbo.useractivityhist` table for historical audit data
   - Creates `UserActivityAudit` Extended Events session
   - Configurable event filters (login, logout)

2. **Ingestion Job** (`sql_user_audit_02_agent_job_ingest.sql`)
   - SQL Agent job runs every 15 minutes
   - Extracts data from XE `.xel` files
   - Inserts deduplicated rows into audit history table
   - Idempotent design prevents duplicates

3. **Reporting Queries** (`sql_user_audit_03_reporting_queries.sql`)
   - 10+ pre-built queries for compliance/security analysis
   - Recent login activity, session duration, application usage
   - Unique logins per database with latest activity
   - Data purge maintenance script

**Key Features:**
- Minimal overhead (<1% CPU) when configured for login/logout only
- UTC storage with Pacific time output conversions
- Supports multiple SQL Server instances (data stays local per instance)
- No external tools required (native SQL Server features only)
- Configurable service account exclusions (system, SQL service accounts, etc.)

**Documentation:** See [scripts/sql_user_audit_README.md](scripts/sql_user_audit_README.md)

---

## Getting Started

### Prerequisites
- **Infrastructure**
  - Windows Server 2019 Datacenter (x64)
  - Minimum 6 GB RAM
  - SQL Server 2019 Enterprise Edition media accessible
  - Pre-provisioned disks and mount points
  - Active Directory service accounts (provided by AD team)

- **Automation**
  - Ansible ≥2.9 (for playbook execution)
  - VS Code (recommended) or other YAML editor
  - Git client for repository clone/sync

- **Database Access**
  - Sysadmin or elevated permissions on target SQL Server instances
  - SQL Server Agent enabled

### Quick Start: User Audit Solution

1. **Clone the repository**
   ```powershell
   git clone https://dev.azure.com/[org]/[project]/_git/SQLServerInfra
   cd SQLServerInfra/scripts
   ```

2. **Deploy infrastructure** (run in SSMS as sysadmin)
   ```sql
   :r sql_user_audit_01_setup_infrastructure.sql
   ```

3. **Create ingestion job** (run in SSMS as sysadmin)
   ```sql
   :r sql_user_audit_02_agent_job_ingest.sql
   ```

4. **Wait 15 minutes** for first data ingestion, then run reports
   ```sql
   :r sql_user_audit_03_reporting_queries.sql
   -- Run individual queries as needed
   ```

5. **(Optional) Exclude service accounts**
   - Edit `sql_user_audit_01_setup_infrastructure.sql`
   - Add account names to the WHERE clause filters
   - Redeploy the XE session

---

## Deployment Models

### Manual / Ad-Hoc
- DBA opens SSMS, runs scripts directly
- Suitable for one-off builds, urgent incident recovery
- Execution command: `:r [script].sql` in SSMS

### CI/CD Pipeline
- Integrate playbook into Azure Pipelines or Jenkins
- Parameterize runtime variables from secure pipeline variables
- Automated validation and post-deployment testing
- Enables drift detection and compliant re-deployments

### Ansible/IaC (Planned)
- Use Ansible playbook for repeatable, version-controlled deployments
- Target: Deploy to 1–N Windows servers in batch operations
- Planned for multi-instance standardization

---

## Configuration & Customization

### Audit Solution: Exclude Service Accounts
Edit `sql_user_audit_01_setup_infrastructure.sql`, lines ~120–127:

```sql
WHERE (
    [sqlserver].[server_principal_name] <> N'NT AUTHORITY\SYSTEM'
    AND [sqlserver].[server_principal_name] NOT LIKE N'NT SERVICE\%'
    AND [sqlserver].[server_principal_name] <> N'YourDomain\ServiceAccount'  -- Add exclusions here
    AND [sqlserver].[is_system] = 0
)
```

### Audit Solution: Change Ingestion Frequency
Edit `sql_user_audit_02_agent_job_ingest.sql`, line ~190:

```sql
@freq_subday_interval = 15,  -- Change 15 to 5, 10, 30, 60, etc. (minutes)
```

### Audit Solution: Adjust Retention
In `sql_user_audit_03_reporting_queries.sql`, maintenance section (bottom):

```sql
DECLARE @RetentionDays int = 90;  -- Change 90 to your retention period
```

---

## Support & Contacts

| Role | Contact | Responsibilities |
|------|---------|-----------------|
| **DBA Lead** | [Name/Email] | Infrastructure oversight, playbook reviews, incident triage |
| **Infrastructure Engineer** | [Name/Email] | Ansible playbook maintenance, CI/CD integration, deployment testing |
| **SQL Server Architect** | [Name/Email] | Performance tuning, audit retention policy, compliance alignment |
| **Security/Compliance** | [Name/Email] | Audit log validation, retention requirements, access control review |

---

## Compliance & Security

- **Audit Data Scope:** 
  - Captures who logged in, when, from where
  - Optional: SQL statement capture (when enabled per database)
  - Does NOT capture passwords or sensitive query text by default

- **Data Retention:**
  - Default: 30 rollover XE files (~3 GB), unlimited SQL table retention
  - Configurable: Adjust per SOX, HIPAA, PCI-DSS, or internal policy
  - Maintenance: Run purge query monthly or per compliance schedule

- **Access Control:**
  - Grant `SELECT` on `DBA.dbo.useractivityhist` only to authorized DBAs/security team
  - Restrict write/delete on audit table to prevent tampering

- **Encryption:**
  - Recommend Transparent Data Encryption (TDE) on `DBA` database if audit data is highly sensitive

---

## Troubleshooting

### XE Session Not Capturing Events
```sql
-- Verify session is running
SELECT name, create_time FROM sys.dm_xe_sessions WHERE name = 'UserActivityAudit';

-- If stopped, start it
ALTER EVENT SESSION UserActivityAudit ON SERVER STATE = START;
```

### No Data in Audit Table
```sql
-- Check XE files exist
EXEC xp_cmdshell 'dir D:/SQLXE/*.xel';

-- Manually trigger ingestion job
EXEC msdb.dbo.sp_start_job @job_name = 'DBA - Ingest User Activity Audit';

-- Check job history for errors
SELECT TOP 10 * FROM msdb.dbo.sysjobhistory 
WHERE job_id = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = 'DBA - Ingest User Activity Audit')
ORDER BY run_date DESC, run_time DESC;
```

### High Disk Usage from XE Files
- Reduce `max_file_size` or `max_rollover_files` in setup script
- Add database/user filters to reduce event volume
- Disable statement capture if enabled

---

## Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-03-05 | Initial repo creation; User Audit solution (v1.0) | DBA Team |
| TBD | SQL Server 2019 installation playbook (v1.0) | Infrastructure Team |

---

## References

- [Microsoft SQL Server 2019 Installation Documentation](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server?view=sql-server-ver19)
- [SQL Server Extended Events](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events?view=sql-server-ver19)
- [Ansible for Windows](https://docs.ansible.com/ansible/latest/user_guide/windows.html)
- [Azure DevOps Repos Best Practices](https://docs.microsoft.com/en-us/azure/devops/repos/best-practices)

---

## License
[Your Organization License / Internal Use Only]

---

**Questions?** Contact the DBA team on [Teams channel / email distribution list].

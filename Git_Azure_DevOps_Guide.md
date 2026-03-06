# DBA Team Git & Azure DevOps Guide

**Version:** 1.0  
**Last Updated:** March 6, 2026  
**Audience:** DBA Team Members (SQL Server Administrators, Infrastructure Engineers)

---

## Table of Contents
1. [Why Azure DevOps for the DBA Team?](#why-azure-devops-for-the-dba-team)
2. [Prerequisites](#prerequisites)
3. [Setting Up Git in Visual Studio Code](#setting-up-git-in-visual-studio-code)
4. [Cloning the Repository](#cloning-the-repository)
5. [Working with Branches](#working-with-branches)
   - [Creating a New Branch](#creating-a-new-branch)
   - [Checking Out a Branch](#checking-out-a-branch)
6. [Making Changes and Committing](#making-changes-and-committing)
7. [Pushing Your Branch to Azure DevOps](#pushing-your-branch-to-azure-devops)
8. [Creating a Pull Request](#creating-a-pull-request)
9. [Code Review and Merging](#code-review-and-merging)
10. [Best Practices](#best-practices)
11. [Common Issues and Solutions](#common-issues-and-solutions)

---

## Why Azure DevOps for the DBA Team?

### The Problem: Traditional DBA Workflows

**Before Azure DevOps:**
- SQL scripts stored on individual workstations, shared drives, or personal folders
- No version history: "Which script broke production last week?"
- No collaboration: Multiple DBAs editing the same script with no merge capability
- No code review: Scripts deployed directly to production without peer validation
- No audit trail: Who changed what, when, and why?
- No rollback: Deleted or overwritten scripts are lost forever
- No standardization: Everyone has different versions of "the same" script

**The Cost:**
- Outages caused by untested scripts
- Rework when scripts are lost or overwritten
- Compliance failures (SOX, HIPAA, PCI-DSS require change tracking)
- Knowledge silos when DBAs leave the organization

---

### The Solution: Version Control + CI/CD

**With Azure DevOps (Git):**
- **Version Control**: Every change is tracked, timestamped, and attributed to a person
- **Collaboration**: Multiple DBAs can work on scripts simultaneously without conflicts
- **Code Review**: Pull Requests ensure peer review before production deployment
- **Audit Trail**: Full compliance history for regulators and change control boards
- **Rollback**: Restore any previous version of any script instantly
- **Standardization**: Single source of truth for all infrastructure automation
- **Integration**: Automate deployments with CI/CD pipelines (future state)

**Why Azure DevOps On-Premises?**
- **Security**: Your organization runs Azure DevOps Server locally for data sovereignty
- **Compliance**: All code and history stay within your network perimeter
- **Performance**: No latency to cloud services; fast clone/push operations
- **Integration**: Works with existing Active Directory, Windows authentication, and on-prem SQL Servers

---

### Real-World Benefits for DBAs

| Without Git | With Git + Azure DevOps |
|-------------|-------------------------|
| "Where's the latest version of the restore script?" | Clone the repo; always current |
| "Who broke the user audit script?" | `git log` shows who, when, why |
| "We need to roll back yesterday's change!" | `git revert` in 30 seconds |
| "I accidentally deleted my script!" | `git checkout` restores instantly |
| "Two DBAs edited the same file!" | Git auto-merges or flags conflicts |
| "Did we review this before production?" | Pull Request history proves it |
| "Compliance wants our change log!" | Export Git history as audit report |

---

## Prerequisites

Before you begin, ensure you have:

### 1. Software Installed
- [x] **Visual Studio Code** (VS Code) - [Download here](https://code.visualstudio.com/)
- [x] **Git for Windows** - [Download here](https://git-scm.com/download/win)
  - During installation, select **"Use Git from the Windows Command Prompt"**
  - Accept default options for line endings and credential manager

### 2. Access Permissions
- [x] **Azure DevOps Account**: Request access from your IT team
- [x] **Repository Permissions**: Ensure you have **Contributor** role on `SQLServerInfra` repo
- [x] **Network Access**: Confirm you can reach the on-prem Azure DevOps URL (e.g., `http://azuredevops.yourcompany.local`)

### 3. Credentials
- [x] Your **Active Directory username and password** (for Azure DevOps authentication)
- [x] Or **Personal Access Token (PAT)** if required by your organization

---

## Setting Up Git in Visual Studio Code

### Step 1: Install Git for Windows

1. Download Git for Windows from [https://git-scm.com/download/win](https://git-scm.com/download/win)
2. Run the installer:
   - **Editor**: Select "Use Visual Studio Code as Git's default editor"
   - **PATH**: Select "Git from the command line and also from 3rd-party software"
   - **Line endings**: "Checkout Windows-style, commit Unix-style line endings"
   - **Credential helper**: "Git Credential Manager"
   - Accept all other defaults
3. Click **Install** and wait for completion

### Step 2: Verify Git Installation

1. Open **PowerShell** or **Command Prompt**
2. Run:
   ```bash
   git --version
   ```
3. You should see output like: `git version 2.43.0.windows.1`

### Step 3: Configure Git Identity

Git tracks who makes each commit. Set your name and email:

```bash
git config --global user.name "Your Name"
git config --global user.email "yourname@yourcompany.com"
```

**Example:**
```bash
git config --global user.name "John Smith"
git config --global user.email "jsmith@yourcompany.com"
```

Verify your configuration:
```bash
git config --global --list
```

### Step 4: Install VS Code Git Extension (Optional but Recommended)

VS Code has built-in Git support, but these extensions enhance the experience:

1. Open **VS Code**
2. Click the **Extensions** icon (or press `Ctrl+Shift+X`)
3. Search for and install:
   - **GitLens** (by GitKraken) - Shows blame, history, and more
   - **Git Graph** (by mhutchie) - Visual branch history

### Step 5: Configure VS Code to Use Git

1. Open VS Code
2. Press `Ctrl+Shift+P` to open the Command Palette
3. Type `Git: Show Output` and verify Git is detected
4. You should see: `Using git 2.43.0 from C:\Program Files\Git\cmd\git.exe`

---

## Cloning the Repository

**Cloning** downloads the entire repository (all files, branches, history) to your local machine.

### Step 1: Get the Repository URL

1. Open your web browser
2. Navigate to your on-prem Azure DevOps instance:
   ```
   http://azuredevops.yourcompany.local/YourOrg/YourProject/_git/SQLServerInfra
   ```
3. Click **Clone** (top-right)
4. Copy the **HTTPS URL**, for example:
   ```
   http://azuredevops.yourcompany.local/YourOrg/YourProject/_git/SQLServerInfra
   ```

### Step 2: Clone Using VS Code

1. Open **VS Code**
2. Press `Ctrl+Shift+P` (Command Palette)
3. Type `Git: Clone` and press Enter
4. Paste the repository URL and press Enter
5. Choose a local folder (e.g., `C:\Git\SQLServerInfra`)
6. VS Code will clone the repository and prompt: **"Would you like to open the cloned repository?"**
7. Click **Open**

**Alternative: Clone Using PowerShell**

```powershell
cd C:\Git
git clone http://azuredevops.yourcompany.local/YourOrg/YourProject/_git/SQLServerInfra
cd SQLServerInfra
code .   # Opens VS Code in this folder
```

### Step 3: Authenticate (If Prompted)

- If using **Windows Authentication**: Enter your AD username/password
- If using **Personal Access Token (PAT)**:
  - Username: (leave blank or type `pat`)
  - Password: paste your PAT token

Git Credential Manager will save your credentials for future use.

---

## Working with Branches

### What is a Branch?

A **branch** is an independent line of development. Think of it as a "workspace" where you make changes without affecting the main codebase.

**Why Use Branches?**
- **Isolation**: Your changes don't break `main` until they're reviewed and tested
- **Collaboration**: Multiple DBAs can work on different features simultaneously
- **Safety**: `main` branch is always deployable; experimental work happens in feature branches
- **Traceability**: Each branch represents a specific feature, bug fix, or task

**Branch Naming Conventions (Recommended):**
```
feature/short-description     # New feature or enhancement
bugfix/issue-description      # Bug fix
hotfix/urgent-fix            # Emergency production fix
docs/documentation-update     # Documentation only
```

**Examples:**
- `feature/add-backup-automation`
- `bugfix/fix-audit-query-timeout`
- `hotfix/restore-script-null-check`
- `docs/update-readme`

---

### Creating a New Branch

**Always create a branch from an up-to-date `main` branch.**

#### Option 1: Using VS Code UI

1. Open the repository in VS Code
2. Click the **branch name** in the bottom-left status bar (e.g., `main`)
3. Select **"Create new branch..."**
4. Enter your branch name (e.g., `feature/add-login-audit-filters`)
5. VS Code creates the branch and switches to it automatically

#### Option 2: Using VS Code Command Palette

1. Press `Ctrl+Shift+P`
2. Type `Git: Create Branch`
3. Enter your branch name
4. Press Enter

#### Option 3: Using PowerShell / Terminal

1. Open the **integrated terminal** in VS Code: `Ctrl+` ` (backtick)
2. Run:
   ```bash
   git checkout -b feature/add-login-audit-filters
   ```
   - `checkout -b` creates a new branch and switches to it

**Verify your current branch:**
```bash
git branch
```
You should see:
```
  main
* feature/add-login-audit-filters   # Asterisk shows current branch
```

---

### Checking Out a Branch

**Checking out** switches your workspace to a different branch.

#### Scenario 1: Switch to an Existing Local Branch

**Using VS Code:**
1. Click the branch name in the bottom-left
2. Select the branch you want (e.g., `feature/add-login-audit-filters`)

**Using Terminal:**
```bash
git checkout feature/add-login-audit-filters
```

#### Scenario 2: Check Out a Remote Branch (Created by a Colleague)

Your colleague created a branch on Azure DevOps, and you want to work on it locally.

1. **Fetch the latest branches** from Azure DevOps:
   ```bash
   git fetch origin
   ```

2. **Check out the remote branch**:
   ```bash
   git checkout feature/colleague-branch-name
   ```
   Git automatically creates a local branch tracking the remote branch.

**Verify:**
```bash
git branch -vv   # Shows local branches and their remote tracking branches
```

#### Scenario 3: Switch Back to Main

Always pull the latest changes before switching:

```bash
git checkout main
git pull origin main
```

---

## Making Changes and Committing

### Step 1: Make Your Changes

1. Open files in VS Code (e.g., `scripts/sql_user_audit_01_setup_infrastructure.sql`)
2. Edit the file (add a feature, fix a bug, update documentation)
3. Save the file (`Ctrl+S`)

**Example:** Add a new service account exclusion filter in line 125 of the audit script.

### Step 2: Review Your Changes

**In VS Code Source Control Panel:**
1. Click the **Source Control** icon (or press `Ctrl+Shift+G`)
2. You'll see a list of **modified files** under "Changes"
3. Click a file to see a **diff view** (red = removed, green = added)

**Using Terminal:**
```bash
git status          # Shows which files changed
git diff            # Shows line-by-line changes
```

### Step 3: Stage Your Changes

**Staging** tells Git which changes you want to include in the next commit.

**Using VS Code:**
1. In the Source Control panel, hover over a changed file
2. Click the **+** icon to stage it (or click **+** next to "Changes" to stage all)

**Using Terminal:**
```bash
git add scripts/sql_user_audit_01_setup_infrastructure.sql   # Stage one file
git add .                                                    # Stage all changes
```

### Step 4: Commit Your Changes

A **commit** is a snapshot of your staged changes with a descriptive message.

**Using VS Code:**
1. In the Source Control panel, type a commit message in the text box:
   ```
   Add exclusion for HP\svcsqlcentry service account
   
   - Filters out HP\svcsqlcentry from login and logout XE events
   - Reduces audit noise from automated monitoring
   ```
2. Press `Ctrl+Enter` or click the **checkmark** icon to commit

**Using Terminal:**
```bash
git commit -m "Add exclusion for HP\svcsqlcentry service account"
```

**Best Practice: Write Good Commit Messages**
- **First line**: Short summary (50 chars max)
- **Blank line**
- **Body**: Detailed explanation of what changed and why (optional)

**Good Examples:**
```
Fix null reference error in audit ingestion job

- Added NULL check for object_name column
- Updated staging table schema to allow NULL values
- Prevents job failure when login events don't have object metadata
```

```
Update README with branch strategy documentation
```

**Bad Examples:**
```
fix          # Too vague
asdf         # Not descriptive
updated file # What changed? Why?
```

### Step 5: Verify Your Commit

```bash
git log --oneline -5   # Shows last 5 commits
```

You should see your commit at the top:
```
a1b2c3d (HEAD -> feature/add-login-audit-filters) Add exclusion for HP\svcsqlcentry service account
e4f5g6h Update README with setup instructions
...
```

---

## Pushing Your Branch to Azure DevOps

**Pushing** uploads your local commits to the remote repository (Azure DevOps) so others can see them.

### Step 1: Push Your Branch

**First Time Pushing a New Branch:**

**Using VS Code:**
1. In the Source Control panel, click the **...** menu (top-right)
2. Select **Push**
3. VS Code will prompt: **"The branch 'feature/xyz' has no upstream branch. Would you like to publish it?"**
4. Click **Publish Branch**

**Using Terminal:**
```bash
git push -u origin feature/add-login-audit-filters
```
- `-u` sets the upstream tracking branch (only needed the first time)

**Subsequent Pushes:**
```bash
git push   # No arguments needed; Git knows where to push
```

### Step 2: Verify on Azure DevOps

1. Open your browser
2. Navigate to Azure DevOps: `http://azuredevops.yourcompany.local/YourOrg/YourProject/_git/SQLServerInfra`
3. Click **Branches**
4. You should see your branch listed (e.g., `feature/add-login-audit-filters`)

---

## Creating a Pull Request

A **Pull Request (PR)** is a request to merge your branch into `main` (or another target branch). PRs enable:
- **Code Review**: Peers review your changes before they go to production
- **Discussion**: Team can comment, suggest improvements, or request changes
- **Approval Workflow**: Requires 1+ approvals before merging
- **CI/CD Triggers**: Automated tests run on PRs (future state)

### Step 1: Create the Pull Request

1. Open Azure DevOps in your browser
2. Navigate to **Repos > Pull Requests**
3. Click **New Pull Request**
4. Configure the PR:
   - **Source branch**: `feature/add-login-audit-filters` (your branch)
   - **Target branch**: `main` (usually the default)
   - **Title**: Short summary (auto-filled from your last commit message)
   - **Description**: Explain what changed and why (use the template if available)

**Example PR Description:**
```markdown
## Summary
Adds service account exclusion filter to the User Activity Audit XE session.

## Changes
- Updated `sql_user_audit_01_setup_infrastructure.sql` to exclude `HP\svcsqlcentry`
- Prevents automated monitoring activity from cluttering audit logs

## Testing
- Deployed to DEV SQL instance
- Verified XE session filters out the service account
- Confirmed existing user logins still captured correctly

## Related Work Items
- Closes #1234 (Reduce audit noise from service accounts)
```

5. **Assign Reviewers**:
   - Select 1-2 senior DBAs or the DBA lead
   - Azure DevOps may require approval from specific people based on branch policies

6. Click **Create**

### Step 2: Link Work Items (Optional but Recommended)

If your organization uses **Azure Boards** for task tracking:
1. In the PR, click **Add link**
2. Select the related Work Item (e.g., "Task #1234: Configure audit filters")
3. This links the code change to the business requirement

---

## Code Review and Merging

### What Happens Next?

1. **Reviewers are Notified**: They receive an email or Teams notification
2. **Review Process**:
   - Reviewers examine your code line-by-line
   - They may leave comments, ask questions, or request changes
   - You can respond to comments and push additional commits to address feedback
3. **Approval**:
   - Once reviewers approve, the PR status changes to "Approved"
4. **Merge**:
   - The DBA lead or senior engineer merges your branch into `main`
   - Your changes are now part of the official codebase

### Responding to Feedback

If a reviewer requests changes:

1. **Make the changes locally** (in your feature branch)
2. **Commit the changes**:
   ```bash
   git add .
   git commit -m "Address review feedback: add comments to exclusion filter"
   ```
3. **Push the new commit**:
   ```bash
   git push
   ```
4. The PR **automatically updates** with your new commit
5. Reviewers are notified and can re-review

### After Your PR is Merged

1. **Delete Your Local Branch** (cleanup):
   ```bash
   git checkout main
   git pull origin main
   git branch -d feature/add-login-audit-filters
   ```

2. **Delete the Remote Branch** (if not auto-deleted):
   - Azure DevOps usually auto-deletes after merge (configurable)
   - Or manually: `git push origin --delete feature/add-login-audit-filters`

---

## Best Practices

### 1. Always Work in a Branch (Never Commit Directly to Main)

**Why?** Direct commits to `main` bypass code review and can break production.

**Enforce This:**
- Ask your Azure DevOps admin to set a **branch policy** requiring PRs for `main`

---

### 2. Keep Your Branch Up-to-Date

Before merging, ensure your branch has the latest changes from `main`:

```bash
git checkout main
git pull origin main
git checkout feature/your-branch
git merge main   # Merges main into your branch
```

Or use **rebase** (advanced):
```bash
git checkout feature/your-branch
git rebase main
```

If there are conflicts, Git will prompt you to resolve them.

---

### 3. Commit Often, Push Regularly

- **Commit** after each logical change (don't wait until the end of the day)
- **Push** at least once per day (backs up your work to Azure DevOps)
- Small, frequent commits are easier to review and revert if needed

---

### 4. Write Descriptive Commit Messages

- Explain **what** changed and **why**
- Future you (and your teammates) will thank you

---

### 5. Pull Before You Push

Always fetch the latest changes before pushing:

```bash
git pull origin feature/your-branch
git push
```

This prevents conflicts and ensures you don't overwrite someone else's work.

---

### 6. Use .gitignore to Exclude Unnecessary Files

The repository should already have a `.gitignore` file. If not, create one:

```
# Ignore local secrets
*.local.yml
*.secret.yml

# Ignore SQL Server backup files
*.bak
*.trn

# Ignore VS Code workspace settings (optional)
.vscode/

# Ignore Windows temp files
Thumbs.db
Desktop.ini
```

Never commit:
- Passwords or credentials
- Large binary files (backups, .bak files)
- Personal workspace settings

---

### 7. Tag Releases

When deploying to production, create a Git tag for traceability:

```bash
git tag -a v1.0-user-audit -m "User Audit Solution v1.0 - Production Release"
git push origin v1.0-user-audit
```

---

## Common Issues and Solutions

### Issue 1: "Authentication Failed"

**Symptoms:** Git prompts for username/password repeatedly, or says "Authentication failed"

**Solutions:**
1. **Windows Credential Manager**:
   - Open **Control Panel > Credential Manager > Windows Credentials**
   - Remove old Azure DevOps credentials
   - Retry `git push`; Git Credential Manager will prompt for fresh credentials

2. **Use Personal Access Token (PAT)**:
   - Generate a PAT in Azure DevOps: **User Settings > Personal Access Tokens**
   - Use PAT as the password when prompted

3. **Check Network Access**:
   - Verify you can reach the Azure DevOps URL in a browser
   - If on VPN, ensure you're connected

---

### Issue 2: "Merge Conflict"

**Symptoms:** Git says "CONFLICT (content): Merge conflict in [file]"

**Cause:** You and another DBA both edited the same lines in the same file.

**Solution:**
1. Open the conflicted file in VS Code
2. VS Code highlights conflicts with markers:
   ```sql
   <<<<<<< HEAD (your changes)
   AND [sqlserver].[server_principal_name] <> N'HP\svcsqlcentry'
   =======
   AND [sqlserver].[server_principal_name] <> N'HP\othersvc'
   >>>>>>> main (incoming changes)
   ```
3. **Decide which change to keep** (or keep both):
   - Click **Accept Current Change** (yours)
   - Click **Accept Incoming Change** (theirs)
   - Click **Accept Both Changes**
   - Or manually edit the file

4. **Remove the conflict markers** (<<<, ===, >>>)
5. **Stage and commit the resolved file**:
   ```bash
   git add scripts/sql_user_audit_01_setup_infrastructure.sql
   git commit -m "Resolve merge conflict in audit filters"
   git push
   ```

---

### Issue 3: "Your Branch is Behind 'origin/main'"

**Symptoms:** VS Code shows "↓5" (5 commits behind)

**Solution:** Pull the latest changes from `main`:
```bash
git checkout main
git pull origin main
```

Then merge `main` into your feature branch:
```bash
git checkout feature/your-branch
git merge main
```

---

### Issue 4: "I Committed to the Wrong Branch"

**Scenario:** You accidentally committed to `main` instead of your feature branch.

**Solution (if you haven't pushed yet):**

1. **Create a new branch from current state**:
   ```bash
   git branch feature/my-fix   # Creates branch but doesn't switch
   ```

2. **Reset `main` to undo the commit**:
   ```bash
   git checkout main
   git reset --hard origin/main   # Resets main to match remote
   ```

3. **Switch to your feature branch**:
   ```bash
   git checkout feature/my-fix   # Your commit is now here
   ```

**If you already pushed to `main`:** Contact the DBA lead immediately for help.

---

### Issue 5: "I Want to Undo My Last Commit"

**Scenario:** You committed something by mistake.

**Solution (if you haven't pushed):**

```bash
git reset --soft HEAD~1   # Undo commit but keep changes staged
# Or
git reset --hard HEAD~1   # Undo commit and discard changes (dangerous!)
```

**If you already pushed:**

```bash
git revert HEAD   # Creates a new commit that undoes the last commit
git push
```

---

### Issue 6: "I Accidentally Deleted a File Locally"

**Solution:** Restore from Git:
```bash
git checkout HEAD -- scripts/deleted_file.sql
```

Or use VS Code:
1. Source Control panel > click the file
2. Click the **Discard Changes** icon (circular arrow)

---

## Quick Reference Cheat Sheet

### Common Git Commands

| Command | Description |
|---------|-------------|
| `git clone <url>` | Download repository from Azure DevOps |
| `git status` | Show changed files |
| `git branch` | List local branches |
| `git checkout -b feature/name` | Create and switch to new branch |
| `git checkout main` | Switch to main branch |
| `git pull origin main` | Download latest changes from main |
| `git add .` | Stage all changes |
| `git commit -m "message"` | Commit staged changes |
| `git push` | Upload commits to Azure DevOps |
| `git push -u origin feature/name` | Push new branch (first time) |
| `git log --oneline` | Show commit history |
| `git diff` | Show uncommitted changes |
| `git merge main` | Merge main into current branch |
| `git branch -d feature/name` | Delete local branch (after merge) |

---

## Next Steps

1. **Complete the setup** by cloning the `SQLServerInfra` repository
2. **Practice** by creating a test branch and making a small change (e.g., update README)
3. **Submit your first PR** (even if trivial) to get comfortable with the process
4. **Join the team** code review rotation
5. **Read the main README.md** for details on the User Audit solution and playbooks

---

## Support & Training

- **Questions?** Ask in the DBA Teams channel or email the DBA lead
- **Training Sessions:** Monthly Git/Azure DevOps office hours (check team calendar)
- **Resources:**
  - [Git Official Documentation](https://git-scm.com/doc)
  - [VS Code Git Integration](https://code.visualstudio.com/docs/sourcecontrol/overview)
  - [Azure DevOps On-Premises Docs](https://docs.microsoft.com/en-us/azure/devops/server/)

---

**Welcome to modern DBA workflows!** 🚀

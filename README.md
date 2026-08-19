# GitLab → GitHub Migration

## 1. Executive Summary – Objective
This document provides detailed procedures to migrate source code repositories from **GitLab Server** to **GitHub**.

### GitHub Actions (GHA) Pipeline Migration
- Execute the migration using the provided GitHub Actions workflow (Use GitHub-hosted runner (`ubuntu-latest`) or a self-hosted runner running Ubuntu).
- The pipeline process consists of:
  - Validate runner prerequisites and required tools
  - Validate required variables, secrets, and inventory files
  - Perform migration readiness checks
  - Generate migration archives
  - Upload migration archives to the configured storage
  - Start repository migrations
  - Monitor migration progress
  - Run post-migration validation
  - Generate migration logs, reports, and summary artifacts

## 2. Requirements

### 2.1 Software Requirements

The following package dependencies are automatically installed when the GitHub Actions runner user has sudo access.

| Requirement | Description |
|------------|-------------|
| curl | Used by migration scripts and API operations.
| jq | Used for JSON processing within migration scripts. |
| git | Required for repository operations and cloning. |
| Docker | Required for building and running the `gl-exporter` container used for migration archive generation. | 
| Node.js | Required Node.js v20 or later for JavaScript-based migration utilities. |
| npm | Required npm v10 or later for package dependency management. |
| GitHub CLI (`gh`) | Required for inventory generation, migration operations, monitoring, and mannequin management. |

> **Note:**
  - If the GitHub Actions runner user does not have sudo access, the workflow cannot install missing dependencies automatically and will fail with the required remediation actions.
  - If Docker is installed but the runner user does not have permission to execute Docker commands, the runner user must be added to the Docker group.

### 2.2 GitHub CLI extensions

The following GitHub CLI extensions are automatically installed by the workflow:

- gh-gitlab-stats: Generates GitLab inventory reports.
- gh-migration-monitor: Monitors migration status.
- gh-ado2gh:
  - Migration status checks
  - Mannequin CSV generation
  - Mannequin reclamation
  - Migration monitoring

### 2.3 Required Token Scopes

#### GitLab API Token

- Must be generated using an administrator account.
- Requires **full API access**.
- Used for:
  - Inventory generation using `gh-gitlab-stats`
  - Migration archive generation using `gl-exporter`

#### GitHub Personal Access Token (PAT)

Required scopes:

- `repo`
- `admin:org`
- `workflow`
- `user`

### 2.4 Intermediate Storage for Migration Archives

Migration archives are temporarily stored before migration into GitHub.

Supported storage options:

| Storage Type | Supported Capacity |
|-------------|-------------------|
| GitHub Storage | Up to 30 GB |
| Azure Storage | Up to 40 GB |
| AWS S3 Bucket | Up to 40 GB |

Additional requirements:

- Azure CLI is required when using Azure Storage.
- AWS CLI is required when using AWS S3 Bucket Storage.

### 2.5 GitHub Object Storage Feature Flag

The GitHub Object Storage feature flag must be enabled for:

- The GitHub enterprise/account handle.
- All target GitHub organizations.

### 2.6 Network Configuration

The customer is responsible for configuring any required IP allow lists according to their implementation.

Reference documentation:

```text
https://docs.github.com/en/enterprise-cloud/latest/migrations/ado/managing-access-for-a-migration-from-azure-devops#configuring-ip-allow-lists-for-migrations
```

## 5. Pre-Migration

### 5.1 Generate Inventory CSV
Before starting a migration, generate an inventory file using the GitHub CLI extension `gitlab-stats`:

```bash
gh gitlab-stats --hostname "gitlab.company.com" --token "glpat-xxxx" --namespace my-gitlab-group
```

This produces a CSV inventory of repositories.

### 5.2 Edit Inventory CSV
After generating the inventory file, update the CSV by adding the following columns:

- `github_org` : Target GitHub Org
- `github_repo` : Target Repo Name
- `gh_repo_visibility` : Supported values: `public, private, internal`

### Optional Export Filters in the Inventory CSV

The inventory CSV supports the following optional columns:

#### `include_in_export`
- Used to export only specific GitLab entities.
- Maps to the `gl-exporter --only` option.
- Can be left empty.

#### `exclude_from_export`
- Used to exclude specific GitLab entities from the export.
- Maps to the `gl-exporter --except` option.
- Can be left empty.

#### Supported Values
The following values are supported:

- merge_requests
- issues
- commit_comments
- hooks
- wiki

#### Multiple Values
Multiple values can be specified using the pipe (`|`) separator. Comma-separated values are not supported for `include_in_export` and `exclude_from_export` columns.

Example:

```csv
include_in_export
issues|merge_requests|commit_comments|hooks|wiki
```
*Note: include_in_export and exclude_from_export are mutually exclusive. If both columns are populated for a repository row, that repository will fail validation and be skipped. The script will continue processing all remaining repositories in the inventory file.*

| Fill in the target GitHub organization and repository name for each row. |

#### Example Inventory CSV

| Namespace | Project | Commit_Count | Branch_Count | Full_URL | github_org | github_repo | gh_repo_visibility | include_in_export | exclude_from_export |
| -------- | -------- | -------- | -------- | -------- | -------- | -------- |-------- | -------- | -------- |
| demo-group/sub-group | demo-project | 20 | 1 | `http://gitlab-server/demo-group/sub-group/demo-project` | ghorg | demoproject | private | merge_requests |
| demo-group-1/sub-group-1 | demo-project-1 | 20 | 1 | `http://gitlab-server/demo-group/sub-group/demo-project-1` | ghorg | demoproject1 | public | | commit_comments |

**Notes**
- The example shows only the minimum required columns.
- The actual inventory CSV may contain additional metadata columns generated by `gh gitlab-stats`.
- Columns `github_org`, `github_repo`, and `gh_repo_visibility` must be populated before running a migration.

### 5.3 Upload Inventory to GitHub Repository

Upload the updated inventory CSV to the GitHub repository so that the workflow can access it during execution.

## 7. GitHub Actions (GHA) Pipeline Migration

### 7.1 GitHub Environment Setup

The workflow uses GitHub Environments to store migration configuration, secrets, and approval controls.

#### CI/CD Environment

Create a GitHub Environment containing the variables and secrets required for migration.

Navigate to:

```text
GitHub Repository → Settings → Environments → <ENVIRONMENT_NAME>
```

Example:

```text
customer-prod-env
```

The environment name is provided as an input when executing the workflow.

The following workflow jobs use this environment:

- `getting-env-ready`
- `validate-prerequisites`
- `pre-migration-readiness-check`
- `generate-migration-archives`
- `upload-migration-archives`
- `start-repository-migration`
- `display-migration-summary`
- `monitor-repository-migrations`
- `post-migration-validation`

##### Environment Variables

| Name | Description |
|--------|-------------|
| `SOURCE_GL_SERVER_URL` | GitLab server URL |
| `GITLAB_USERNAME` | GitLab username |
| `GH_API_URL` | Optional. Required only when using GitHub Enterprise Cloud with Data Residency. Example: https://api.SUBDOMAIN.ghe.com |
| `STORAGE_TYPE` | Required for using AWS or AZURE storages. Allowed values: `AZURE`, or `AWS` |
| `AZ_CONTAINER` | Required when `STORAGE_TYPE=AZURE` |
| `AWS_BUCKET_NAME` | Required when `STORAGE_TYPE=AWS` |
| `AWS_REGION` | Required when `STORAGE_TYPE=AWS` |

##### Environment Secrets

| Name | Description |
|--------|-------------|
| `GITLAB_API_PRIVATE_TOKEN` | GitLab API token |
| `GH_PAT` | GitHub Personal Access Token |
| `AZURE_STORAGE_CONNECTION_STRING` | Required when `STORAGE_TYPE=AZURE` |
| `AWS_ACCESS_KEY_ID` | Required when `STORAGE_TYPE=AWS` |
| `AWS_SECRET_ACCESS_KEY` | Required when `STORAGE_TYPE=AWS` |

#### Approval Environment

Create a separate GitHub Environment for approval workflows.

Navigate to:

```text
GitHub Repository → Settings → Environments 
```
Create environment called `approvers-group`

This environment is used by workflow approval stages, including:

- Approval after readiness checks
- Approval before migration monitoring

Configure reviewers as required by your organization's approval process.

### 7.2 Pipeline Flow

The GitHub Actions workflow automates the migration process using the following stages:

#### 1. Getting Environment Ready

- Validates the runner operating system
- Validates required tools and dependencies
- Validates Docker access
- Installs missing dependencies (when permitted)
- Authenticates GitHub CLI
- Installs required GitHub CLI extensions

#### 2. Validate Prerequisites

- Validates required variables and secrets
- Validates storage configuration
- Validates workflow inputs
- Validates required scripts
- Validates inventory file configuration

#### 3. Pre-Migration Readiness Check

- Runs migration readiness checks
- Generates readiness reports
- Uploads readiness reports as workflow artifacts

#### 4. Approval Stage

- Uses the configured approval environment
- Allows readiness results to be reviewed before continuing

#### 5. Generate Migration Archives

- Builds the `gl-exporter` Docker image if required
- Generates migration archives
- Creates archive inventory files
- Uploads logs and outputs as workflow artifacts

#### 6. Upload Migration Archives

- Uploads archives to the configured storage platform
- Generates upload inventory files
- Uploads logs and outputs as workflow artifacts

#### 7. Start Repository Migrations

- Creates migration sources
- Starts GitLab-to-GitHub repository migrations
- Generates migration output files
- Uploads logs and outputs as workflow artifacts

#### 8. Display Migration Summary

- Aggregates migration results
- Displays migration statistics
- Generates a final migration summary report

#### 9. Approval Before Monitoring

- Uses the configured approval environment
- Allows migration results to be reviewed before monitoring begins

#### 10. Monitor Repository Migrations

- Authenticates GitHub CLI
- Installs or upgrades `gh-ado2gh`
- Determines the appropriate GitHub API endpoint
- Monitors repository migration status
- Generates migration status reports

#### 11. Post-Migration Validation

- Validates successfully migrated repositories
- Executes branch and commit validation checks
- Generates validation reports

#### 12. Artifact Preservation

The workflow uploads migration artifacts including:

- Readiness reports
- Archive generation outputs
- Archive upload outputs
- Migration outputs
- Migration summaries
- Migration status reports
- Validation reports
- Workflow logs

### 7.3 Executing the Pipeline

1. Open the GitHub repository.
2. Navigate to:

```text
Actions → GitLab to GitHub Migration Pipeline
```

3. Select **Run workflow**.
4. Provide the required inputs:

| Input | Description |
|---------|-------------|
| Environment Name | GitHub Environment containing migration variables and secrets |
| Inventory File | Inventory CSV generated using `gh gitlab-stats` |
| Runner Label | GitHub-hosted or self-hosted runner label |

5. Select **Run workflow** to start the migration.

### 7.4 Artifacts and Retention

The workflow uploads artifacts to support troubleshooting and migration validation.

Typical artifacts include:

- Readiness reports
- Archive generation outputs
- Archive upload outputs
- Migration output files
- Migration summaries
- Migration status reports
- Validation reports
- Workflow logs

Artifact retention is controlled through the workflow configuration.

## 8. User Identity Mapping (Mannequins)

During migration, GitLab users that cannot be automatically mapped to GitHub users are imported as **mannequins**. Mannequin reclamation allows these placeholder identities to be associated with real GitHub users after migration.

### 8.1 Generate Mannequin Mapping File

Generate a CSV file containing mannequin users for a GitHub organization.

#### GitHub Enterprise Cloud

```bash
gh ado2gh generate-mannequin-csv --github-org "{github-org}"
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh ado2gh generate-mannequin-csv \
  --github-org "{github-org}" \
  --target-api-url https://api.SUBDOMAIN.ghe.com
```

The command generates a `mannequins.csv` file containing the mannequin identities detected within the target GitHub organization.

### 8.2 Update Mannequin Mapping

Open `mannequins.csv` and populate the **target-user** column with valid GitHub usernames.

#### Example

| mannequin-user | mannequin-id | target-user |
|----------------|--------------|-------------|
| gluser1 | M_kgDODtfbRA | github-user1 |
| gluser2 | M_kgDODtfbRg | github-user2 |

**Notes**

- During migration, GitLab users that cannot be automatically matched to GitHub users are imported as mannequins.
- Update the `target-user` column with the appropriate GitHub username for each mannequin account.
- The referenced GitHub users must exist within the target GitHub organization.
- Mannequin reclamation updates migrated content such as commits, issues, comments, and pull requests to reference the mapped GitHub user.

### 8.3 Reclaim Mannequins

After updating the mapping file, execute the mannequin reclamation command.

#### GitHub Enterprise Cloud

```bash
gh ado2gh reclaim-mannequin \
  --github-org "{github-org}" \
  --csv mannequins.csv \
  --skip-invitation
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh ado2gh reclaim-mannequin \
  --github-org "{github-org}" \
  --csv mannequins.csv \
  --skip-invitation \
  --target-api-url https://api.SUBDOMAIN.ghe.com
```

## 9. Appendix

### 9.1 Install GitHub CLI

Install GitHub CLI by following the official installation documentation:

```text
https://github.com/cli/cli#installation
```

### 9.2 Install GitHub CLI Extensions

For GitHub Actions (GHA) Pipeline Migration, the workflow automatically installs or upgrades the required GitHub CLI extensions during the `getting-env-ready` stage.

To perform mannequin reclamation, generate inventory file or monitor migration manually, install the extensions.

Before installing extensions authenticate to GitHub using commands
GitHub Enterprise Cloud: ```gh auth login --hostname github.com```
GitHub Enterprise Cloud with Data Residency: ```gh auth login --hostname SUBDOMAIN.ghe.com```

#### gh-gitlab-stats: Used to generate GitLab inventory reports.

```bash
gh extension install https://github.com/mona-actions/gh-gitlab-stats
```

#### gh-migration-monitor: Used to monitor repository migration status.

```bash
gh extension install https://github.com/mona-actions/gh-migration-monitor
```

#### gh-ado2gh: Used for:

- Migration status checks
- Mannequin CSV generation
- Mannequin reclamation
- Repository migration monitoring

```bash
gh extension install https://github.com/github/gh-ado2gh
```

### 9.3 Build gl-exporter Docker Image

For GitHub Actions (GHA) Pipeline Migration, the workflow automatically builds the `gl-exporter` Docker image if it is not already available. If the local gl_exporter directory is not present, the workflow clones the gl-exporter source repository and builds the image automatically.

### 9.4 Check Migration Status by Migration ID

#### GitHub Enterprise Cloud

```bash
gh ado2gh wait-for-migration --migration-id <migration-id>
```

#### GitHub Enterprise Cloud with Data Residency

```bash
gh ado2gh wait-for-migration \
  --migration-id <migration-id> \
  --target-api-url https://api.SUBDOMAIN.ghe.com
```

### 9.5 Monitor Migrations Using gh-migration-monitor

#### GitHub Enterprise Cloud

```bash
gh migration-monitor --organization <github-org> --github-token <gh-pat>
```

#### GitHub Enterprise Cloud with Data Residency

```text
gh-migration-monitor is not supported for GitHub Enterprise Cloud with Data Residency.
```

# GitHub Actions Workflow Documentation

This document describes the GitHub Actions workflows for automating Konflux UI deployments and related tasks.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                  create-konflux-ui-pr.yml                    │
│                    (Main Orchestrator)                       │
│  ┌─────────────┐                                            │
│  │  create-pr  │ ─── Creates PR to infra-deployments        │
│  └──────┬──────┘                                            │
│         │                                                    │
│         ├───────────────────┬───────────────────┐           │
│         ▼                   ▼                   ▼           │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │notify-slack │    │close-jira   │    │notify-fail  │     │
│  │(pr_created) │    │   issues    │    │(on failure) │     │
│  └──────┬──────┘    └──────┬──────┘    └─────────────┘     │
│         │                  │                                │
│         ▼                  ▼                                │
│  ┌─────────────┐    ┌─────────────┐                        │
│  │slack-notif  │    │close-jira   │  (Reusable Workflows)  │
│  │   .yml      │    │-issues.yml  │                        │
│  └─────────────┘    └─────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

## Workflows

### 1. `create-konflux-ui-pr.yml` (Main Orchestrator)

The main workflow that coordinates PR creation, Slack notifications, and Jira issue closing.

**Triggers:**
- **Schedule:** Daily at midnight UTC (`0 0 * * *`)
- **Manual:** Via `workflow_dispatch`

**Manual Trigger Inputs:**

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `dry_run` | boolean | `false` | Preview mode - no PR or Jira changes |
| `skip_jira` | boolean | `false` | Skip Jira issue closing |
| `skip_slack` | boolean | `false` | Skip Slack notifications |

**Jobs:**
1. `create-pr` - Runs the PR creation script
2. `notify-pr-created` - Sends Slack notification for new PR
3. `close-jira-issues` - Closes Jira issues from changelog
4. `notify-jira-closed` - Sends Slack notification for Jira results
5. `notify-failure` - Sends Slack notification on failure
6. `summary` - Generates workflow summary

---

### 2. `slack-notification.yml` (Reusable)

Reusable workflow for sending Slack notifications.

**Trigger:** `workflow_call` only

**Inputs:**

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `notification_type` | string | ✅ | `pr_created`, `jira_closed`, `failure`, `custom` |
| `pr_url` | string | ❌ | PR URL (for `pr_created`) |
| `pr_title` | string | ❌ | PR title (for `pr_created`) |
| `sha_range` | string | ❌ | SHA range (e.g., `abc...def`) |
| `repository` | string | ❌ | Repository name |
| `issues_closed` | string | ❌ | Count of closed issues (for `jira_closed`) |
| `issues_failed` | string | ❌ | Count of failed issues (for `jira_closed`) |
| `custom_message` | string | ❌ | Message text (for `custom`) |
| `workflow_run_url` | string | ❌ | Workflow URL (for `failure`) |
| `mention_group` | string | ❌ | Slack group to mention (default: `@konflux-ui`) |

**Secrets:**

| Secret | Required | Description |
|--------|----------|-------------|
| `SLACK_WEBHOOK_URL` | ✅ | Slack Incoming Webhook URL |

**Example Usage:**

```yaml
jobs:
  notify:
    uses: ./.github/workflows/slack-notification.yml
    with:
      notification_type: pr_created
      pr_url: https://github.com/org/repo/pull/123
      pr_title: "chore: Update Konflux UI"
      repository: konflux-ci/konflux-ui
    secrets:
      SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

---

### 3. `close-jira-issues.yml` (Reusable)

Reusable workflow for closing Jira issues from a changelog.

**Triggers:**
- `workflow_call` - Called from other workflows
- `workflow_dispatch` - Manual trigger for independent use

**Inputs:**

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `changelog_file` | string | ❌ | Path to changelog file |
| `changelog_content` | string | ❌ | Changelog content as string |
| `version` | string | ❌ | Release version for Jira comments |
| `dry_run` | boolean | ❌ | Preview mode (default: `false`) |
| `rate_limit` | number | ❌ | Seconds between API calls (default: `1`) |

**Note:** Either `changelog_file` OR `changelog_content` must be provided.

**Secrets:**

| Secret | Required | Description |
|--------|----------|-------------|
| `JIRA_API_TOKEN` | ✅ | Jira API token for authentication |

**Outputs:**

| Output | Description |
|--------|-------------|
| `issues_closed` | Number of successfully closed issues |
| `issues_already_closed` | Number of already closed issues |
| `issues_skipped` | Number of skipped issues (not in Release Pending) |
| `issues_failed` | Number of issues that failed to close |

**Example Usage:**

```yaml
jobs:
  close-issues:
    uses: ./.github/workflows/close-jira-issues.yml
    with:
      changelog_file: changelog.md
      version: v1.2.3
      dry_run: false
    secrets:
      JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
```

---

## Required Secrets

Configure these secrets in your repository settings:

| Secret | Required | Description |
|--------|----------|-------------|
| `GH_PAT` | ✅ | GitHub Personal Access Token with `repo` scope |
| `JIRA_API_TOKEN` | ✅ | Jira API token (from Atlassian account settings) |
| `SLACK_WEBHOOK_URL` | ⚠️ | Slack Incoming Webhook URL (optional but recommended) |

### Creating a GitHub PAT

1. Go to GitHub → Settings → Developer settings → Personal access tokens
2. Generate new token (classic) with `repo` scope
3. Copy the token and add it as repository secret `GH_PAT`

### Creating a Jira API Token

1. Go to https://id.atlassian.com/manage-profile/security/api-tokens
2. Create API token
3. Copy the token and add it as repository secret `JIRA_API_TOKEN`

### Creating a Slack Webhook

1. Go to your Slack workspace → Apps → Incoming Webhooks
2. Create new webhook for desired channel
3. Copy the webhook URL and add it as repository secret `SLACK_WEBHOOK_URL`

---

## Required Repository Variables

Configure these variables in your repository settings (Settings → Secrets and variables → Actions → Variables):

| Variable | Default | Description |
|----------|---------|-------------|
| `UPSTREAM_REPO` | `redhat-appstudio/infra-deployments` | Upstream repository for PR |
| `FORK_REPO` | `sahil143/infra-deployments` | Fork repository to push branches |
| `KUI_REPO` | `konflux-ci/konflux-ui` | Konflux UI repository |
| `JIRA_URL` | `https://issues.redhat.com` | Jira server URL |

---

## Shell Scripts

### `dev/create-kui-pr.sh`

Creates the branch and prepares the PR content.

**Environment Variables:**
- `UPSTREAM_REPO` - Upstream repository
- `FORK_REPO` - Fork repository
- `KUI_REPO` - Konflux UI repository
- `DRY_RUN` - Set to `true` for dry run mode

**Outputs (GitHub Actions):**
- `base_sha` - Production SHA
- `target_sha` - Staging SHA
- `branch_name` - Created branch name
- `pr_title` - PR title
- `changelog_content` - Generated changelog

---

### `dev/generate-kui-changelog.sh`

Generates a changelog between two SHA commits.

**Usage:**
```bash
./generate-kui-changelog.sh -r <owner/repo> -b <base_sha> -t <target_sha> [-d <repo_dir>] -o <out_file>
```

**Arguments:**
- `-r` - Repository in `owner/repo` format
- `-b` - Base SHA (older commit)
- `-t` - Target SHA (newer commit)
- `-d` - (Optional) Existing git repository directory
- `-o` - Output file path

---

### `dev/close_issues.sh`

Closes Jira issues found in a changelog.

**Usage:**
```bash
./close_issues.sh [OPTIONS]
```

**Options:**
- `--changelog FILE` - Path to changelog file (default: `changelog.md`)
- `--dry-run` - Preview changes without closing issues
- `--version VERSION` - Release version for Jira comments
- `--jira-url URL` - Jira server URL
- `--rate-limit N` - Seconds between API calls (default: `1`)
- `--help` - Show help message

**Environment Variables:**
- `JIRA_API_TOKEN` - (Required) Jira API token
- `JIRA_URL` - Jira server URL (default: `https://issues.redhat.com`)

---

## Manual Trigger Examples

### Test PR Creation (Dry Run)

```bash
gh workflow run create-konflux-ui-pr.yml \
  --field dry_run=true
```

### Create PR Without Jira

```bash
gh workflow run create-konflux-ui-pr.yml \
  --field skip_jira=true
```

### Close Jira Issues Independently

```bash
gh workflow run close-jira-issues.yml \
  --field changelog_file=changelog.md \
  --field version=v1.2.3 \
  --field dry_run=true
```

---

## Security Features

All workflows and scripts implement these security measures:

1. **No token exposure** - Tokens passed via environment variables, not CLI arguments
2. **JSON injection prevention** - All JSON payloads built using `jq`
3. **Input validation** - All inputs validated before use
4. **Rate limiting** - API calls rate-limited to prevent abuse
5. **Configurable via secrets/variables** - No hardcoded credentials
6. **Timeout protection** - All HTTP calls have timeouts

---

## Troubleshooting

### PR Creation Fails

1. Check `GH_PAT` has `repo` scope
2. Verify fork repository exists and PAT has push access
3. Check if staging and production SHAs are different

### Jira Issues Not Closing

1. Verify `JIRA_API_TOKEN` is valid
2. Check issues are in "Release Pending" status
3. Run with `--dry-run` first to preview
4. Check Jira URL is correct

### Slack Notifications Not Sending

1. Verify `SLACK_WEBHOOK_URL` is set
2. Check webhook URL is valid and channel exists
3. Review workflow logs for HTTP error codes

### No Changes Detected

This is normal when staging and production point to the same SHA. The workflow exits gracefully without creating a PR.

#!/usr/bin/env bash
set -euo pipefail

# =========================
# create-kui-pr.sh
# =========================
# Creates a PR to update Konflux UI SHA in infra-deployments
# by comparing staging vs production kustomization files.
#
# Usage:
#   ./create-kui-pr.sh
#
# Environment variables (all have defaults):
#   UPSTREAM_REPO  - upstream repo (default: redhat-appstudio/infra-deployments)
#   FORK_REPO      - fork repo to push branches (default: sahil143/infra-deployments)
#   KUI_REPO       - konflux-ui repo (default: konflux-ci/konflux-ui)
#   PROD_FILE      - path to production kustomization.yaml
#   STG_FILE       - path to staging kustomization.yaml
#   BRANCH_NAME    - branch name for PR
#   PR_TITLE       - PR title
#   DRY_RUN        - set to "true" to skip push/PR creation

# =========================
# Config (override via env)
# =========================
UPSTREAM_REPO="${UPSTREAM_REPO:-redhat-appstudio/infra-deployments}"
FORK_REPO="${FORK_REPO:-sahil143/infra-deployments}"
KUI_REPO="${KUI_REPO:-konflux-ci/konflux-ui}"

# The kustomization files containing the SHA
PROD_FILE="${PROD_FILE:-components/konflux-ui/production/base/kustomization.yaml}"
STG_FILE="${STG_FILE:-components/konflux-ui/staging/base/kustomization.yaml}"

# Branch and title defaults
BRANCH_NAME="${BRANCH_NAME:-auto/changelog-$(date +%Y%m%d-%H%M%S)}"
PR_TITLE="${PR_TITLE:-chore: Konflux UI changes (staging vs production)}"

# Dry run mode
DRY_RUN="${DRY_RUN:-false}"

# =========================
# Helper Functions
# =========================

# Logging with timestamps
log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# Validate SHA format (40 hex characters)
validate_sha() {
  local sha="$1"
  local name="$2"
  if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
    log_error "Invalid SHA format for $name: '$sha'"
    log_error "Expected 40 hexadecimal characters"
    return 1
  fi
  return 0
}

# Extract SHA from kustomization file - searches for newTag with SHA
# More robust than hardcoded line numbers
extract_sha_from_kustomization() {
  local file="$1"
  local sha=""
  
  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    return 1
  fi
  
  # Look for newTag field containing a 40-char hex SHA
  # This is more robust than hardcoded line numbers
  sha=$(grep -E 'newTag:\s*[0-9a-fA-F]{40}' "$file" | \
        sed -nE 's/.*newTag:\s*([0-9a-fA-F]{40}).*/\1/p' | \
        head -n1)
  
  # Fallback: search for any 40-char hex string (likely a SHA)
  if [[ -z "$sha" ]]; then
    sha=$(grep -oE '[0-9a-fA-F]{40}' "$file" | head -n1)
  fi
  
  if [[ -z "$sha" ]]; then
    log_error "Could not extract SHA from $file"
    return 1
  fi
  
  echo "$sha"
}

# Update SHA in kustomization file
update_sha_in_kustomization() {
  local file="$1"
  local old_sha="$2"
  local new_sha="$3"
  
  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    return 1
  fi
  
  # Validate new SHA
  if ! validate_sha "$new_sha" "new_sha"; then
    return 1
  fi
  
  # Replace the SHA - handles both newTag: SHA and digest references
  sed -i.bak "s/${old_sha}/${new_sha}/g" "$file"
  rm -f "${file}.bak"
  
  # Verify the replacement
  if ! grep -q "$new_sha" "$file"; then
    log_error "Failed to update SHA in $file"
    return 1
  fi
  
  log_info "Updated SHA in $file: $old_sha → $new_sha"
  return 0
}

# Shorten SHA for display
short_sha() {
  local sha="$1"
  local len="${2:-12}"
  echo "${sha:0:$len}"
}

# =========================
# Dependency Checks
# =========================
log_info "Checking dependencies..."
for cmd in git gh sed awk grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Missing required dependency: $cmd"
    exit 1
  fi
done

# Check GitHub CLI authentication
if ! gh auth status >/dev/null 2>&1; then
  log_error "GitHub CLI not authenticated. Run 'gh auth login' first or set GH_TOKEN."
  exit 1
fi
log_info "GitHub CLI authenticated"

# =========================
# Workspace Setup
# =========================
ROOT="$(mktemp -d)"
cleanup() {
  log_info "Cleaning up temporary directory: $ROOT"
  rm -rf "$ROOT"
}
trap cleanup EXIT

log_info "Working directory: $ROOT"

# =========================
# 1) Clone and Extract SHAs
# =========================
log_info "Cloning upstream repository: $UPSTREAM_REPO"
if ! gh repo clone "$UPSTREAM_REPO" "$ROOT/infra-upstream" -- --depth=1 -q; then
  log_error "Failed to clone $UPSTREAM_REPO"
  exit 1
fi

PROD_PATH="$ROOT/infra-upstream/$PROD_FILE"
STG_PATH="$ROOT/infra-upstream/$STG_FILE"

# Extract SHAs using robust method
log_info "Extracting SHA from production: $PROD_FILE"
BASE_SHA=$(extract_sha_from_kustomization "$PROD_PATH") || exit 1

log_info "Extracting SHA from staging: $STG_FILE"
TARGET_SHA=$(extract_sha_from_kustomization "$STG_PATH") || exit 1

# Validate extracted SHAs
validate_sha "$BASE_SHA" "production SHA" || exit 1
validate_sha "$TARGET_SHA" "staging SHA" || exit 1

log_info "Production SHA: $BASE_SHA"
log_info "Staging SHA:    $TARGET_SHA"

# Check if SHAs are identical
if [[ "$BASE_SHA" == "$TARGET_SHA" ]]; then
  log_info "No changes detected: production and staging point to the same SHA."
  log_info "Skipping changelog and PR creation."
  exit 0
fi

# =========================
# 2) Generate Changelog
# =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG_GEN="${CHANGELOG_GEN:-$SCRIPT_DIR/generate-kui-changelog.sh}"

if [[ ! -x "$CHANGELOG_GEN" ]]; then
  log_error "Changelog generator script not found or not executable: $CHANGELOG_GEN"
  exit 1
fi

log_info "Cloning Konflux UI repository: $KUI_REPO"
if ! gh repo clone "$KUI_REPO" "$ROOT/konflux-ui" -- --depth=100 -q; then
  log_error "Failed to clone $KUI_REPO"
  exit 1
fi

OUT_CHANGELOG="$ROOT/changelog.md"
log_info "Generating changelog..."
if ! "$CHANGELOG_GEN" -r "$KUI_REPO" -b "$BASE_SHA" -t "$TARGET_SHA" -d "$ROOT/konflux-ui" -o "$OUT_CHANGELOG"; then
  log_error "Failed to generate changelog"
  exit 1
fi

if [[ ! -s "$OUT_CHANGELOG" ]]; then
  log_error "Changelog file is empty: $OUT_CHANGELOG"
  exit 1
fi

log_info "Generated changelog:"
cat "$OUT_CHANGELOG"

# =========================
# 3) Create Branch and Push
# =========================
log_info "Cloning upstream for modifications: $UPSTREAM_REPO"
if ! gh repo clone "$UPSTREAM_REPO" "$ROOT/infra-fork" -- --depth=1 -q; then
  log_error "Failed to clone repository for modifications"
  exit 1
fi

pushd "$ROOT/infra-fork" >/dev/null

# Setup remotes
log_info "Configuring git remotes..."
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "https://github.com/${UPSTREAM_REPO}.git"
else
  git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"
fi

if git remote get-url downstream >/dev/null 2>&1; then
  git remote set-url downstream "https://github.com/${FORK_REPO}.git"
else
  git remote add downstream "https://github.com/${FORK_REPO}.git"
fi

# Create branch
log_info "Creating branch: $BRANCH_NAME"
git checkout -b "$BRANCH_NAME"

# Update the production file
FORK_PROD_PATH="$PWD/$PROD_FILE"
if [[ ! -f "$FORK_PROD_PATH" ]]; then
  log_error "Production kustomization file not found: $FORK_PROD_PATH"
  exit 1
fi

log_info "Updating production kustomization.yaml..."
if ! update_sha_in_kustomization "$FORK_PROD_PATH" "$BASE_SHA" "$TARGET_SHA"; then
  log_error "Failed to update SHA in production file"
  exit 1
fi

# Check if there are actual changes
if git diff --quiet -- "$PROD_FILE"; then
  log_warn "No changes in $PROD_FILE after update; skipping commit, push, and PR."
  exit 0
fi

# Commit changes
SHORT_BASE="$(short_sha "$BASE_SHA")"
SHORT_TGT="$(short_sha "$TARGET_SHA")"
COMMIT_MSG="chore: bump konflux-ui (production) ${SHORT_BASE} => ${SHORT_TGT}"

git add "$PROD_FILE"
git commit -m "$COMMIT_MSG"

# Push or dry-run
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "[DRY RUN] Would push branch $BRANCH_NAME to $FORK_REPO"
  log_warn "[DRY RUN] Commit: $COMMIT_MSG"
else
  log_info "Pushing branch to fork: $FORK_REPO"
  if ! git push downstream "$BRANCH_NAME"; then
    log_error "Failed to push branch to $FORK_REPO"
    exit 1
  fi
fi

# =========================
# 4) Export GitHub Actions Outputs
# =========================
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  log_info "Writing GitHub Actions outputs..."
  
  # Use a unique delimiter to prevent content injection
  DELIMITER="CHANGELOG_EOF_$(date +%s)_$$_RANDOM${RANDOM}"
  
  {
    echo "base_sha=$BASE_SHA"
    echo "target_sha=$TARGET_SHA"
    echo "branch_name=$BRANCH_NAME"
    echo "pr_title=$PR_TITLE"
    echo "changelog_content<<${DELIMITER}"
    cat "$OUT_CHANGELOG"
    echo ""
    echo "${DELIMITER}"
  } >> "$GITHUB_OUTPUT"
fi

popd >/dev/null

# =========================
# Summary
# =========================
log_info "✅ Done: Branch pushed and ready for PR creation."
log_info "   Branch: $BRANCH_NAME"
log_info "   Range: ${KUI_REPO} $(short_sha "$BASE_SHA")...$(short_sha "$TARGET_SHA")"
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "   [DRY RUN] No actual push was performed"
fi

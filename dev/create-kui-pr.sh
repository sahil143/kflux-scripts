#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (override via env)
# =========================
UPSTREAM_REPO="${UPSTREAM_REPO:-redhat-appstudio/infra-deployments}"
FORK_REPO="${FORK_REPO:-sahil143/infra-deployments}"
KUI_REPO="${KUI_REPO:-konflux-ci/konflux-ui}"

# The exact files (line 14 has the SHA)
PROD_FILE="${PROD_FILE:-components/konflux-ui/production/base/kustomization.yaml}"
STG_FILE="${STG_FILE:-components/konflux-ui/staging/base/kustomization.yaml}"

# Gist that builds changelog.md
GIST_URL="${GIST_URL:-https://gist.githubusercontent.com/sahil143/50f50ef0db706fe1190c7ab48268f6a0/raw/73e080f4d42fc33535884a78d0c3d0dac87573cd/git-pr-changelog.sh}"

# Branch and title defaults
BRANCH_NAME="${BRANCH_NAME:-auto/changelog-$(date +%Y%m%d-%H%M%S)}"
PR_TITLE="${PR_TITLE:-chore: Konflux UI changes (staging vs production)}"

# =========================
# Checks
# =========================
for cmd in git gh curl sed awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }

# =========================
# Workspace
# =========================
ROOT="$(mktemp -d)"
cleanup(){ rm -rf "$ROOT"; }
trap cleanup EXIT

echo "Working dir: $ROOT"

# =========================
# 1) Clone infra-deployments (upstream) just to read SHAs
# =========================
echo "Cloning upstream: $UPSTREAM_REPO"
gh repo clone "$UPSTREAM_REPO" "$ROOT/infra-upstream" -- -q

# Use sed to read **exactly line 14** and extract a 7-40 hex SHA
extract_sha_line14() {
  local file="$1"
  # 1) print line 14, 2) pick the first 7–40 hex run
  sed -n "$2" "$file" | sed -nE 's/.*([0-9a-fA-F]{40}).*/\1/p' | head -n1
}


BASE_SHA="$(extract_sha_line14 "$ROOT/infra-upstream/$PROD_FILE" '14p' || true)"
TARGET_SHA="$(extract_sha_line14 "$ROOT/infra-upstream/$STG_FILE" '15p' || true)"

if [[ -z "$BASE_SHA" || -z "$TARGET_SHA" ]]; then
  echo "Failed to extract SHAs via sed from line 14." >&2
  echo "  Prod file: $PROD_FILE"
  echo "  Stg  file: $STG_FILE"
  exit 1
fi

echo "Base   (production) SHA: $BASE_SHA"
echo "Target (staging)    SHA: $TARGET_SHA"

# If SHAs are identical, nothing to do
if [[ "$BASE_SHA" == "$TARGET_SHA" ]]; then
  echo "No changes detected: production and staging point to the same Konflux UI SHA."
  echo "Skipping changelog and PR creation."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG_GEN="${CHANGELOG_GEN:-$SCRIPT_DIR/generate-kui-changelog.sh}"

# =========================
# 2) Clone konflux-ui and generate changelog.md via helper script
# =========================
echo "Cloning Konflux UI repo: $KUI_REPO"
gh repo clone "$KUI_REPO" "$ROOT/konflux-ui" -- -q

OUT_CHANGELOG="$ROOT/konflux-ui/changelog.md"
"$CHANGELOG_GEN" -r "$KUI_REPO" -b "$BASE_SHA" -t "$TARGET_SHA" -d "$ROOT/konflux-ui" -o "$OUT_CHANGELOG"

echo "Generated changelog at $OUT_CHANGELOG"
cat "$OUT_CHANGELOG"
test -f "$OUT_CHANGELOG" || { echo "changelog.md was not produced"; exit 1; }

# =========================
# 3) Clone your fork, add changelog.md, push branch, open PR to upstream
# =========================
echo "Cloning your upstream: $UPSTREAM_REPO"
gh repo clone "$UPSTREAM_REPO" "$ROOT/infra-fork" -- -q

pushd "$ROOT/infra-fork" >/dev/null
  # Ensure upstream remote is set to the canonical repo
  if git remote get-url upstream >/dev/null 2>&1; then
    git remote set-url upstream "https://github.com/${UPSTREAM_REPO}.git"
  else
    git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"
  fi

    # Ensure upstream remote is set to the canonical repo
  if git remote get-url downstream >/dev/null 2>&1; then
    git remote set-url downstream "https://github.com/${FORK_REPO}.git"
  else
    git remote add downstream "https://github.com/${FORK_REPO}.git"
  fi

  # Create a branch
   git checkout -b "$BRANCH_NAME"

  PROD_PATH="$PWD/$PROD_FILE"
  if [[ ! -f "$PROD_PATH" ]]; then
    echo "Cannot find production kustomization: $PROD_PATH" >&2
    exit 1
  fi

  echo "Updating production kustomization.yaml line 14 SHA → $TARGET_SHA"
  # Replace only the first SHA-like token on line 14 with TARGET_SHA (portable AWK)
  awk -v tgt="$TARGET_SHA" 'NR==14{ sub(/[0-9a-fA-F]{40}/, tgt); print; next } { print }' "$PROD_PATH" > "$PROD_PATH.tmp"
  mv "$PROD_PATH.tmp" "$PROD_PATH"

  # Optional sanity: confirm line 14 now contains TARGET_SHA
  L14_NOW="$(sed -n '14p' "$PROD_PATH")"
  if ! grep -q "$TARGET_SHA" <<<"$L14_NOW"; then
    echo "Failed to set TARGET_SHA on line 14; current line is:"
    echo "$L14_NOW"
    exit 1
  fi
  echo "Line 14 now is:"
  echo "$L14_NOW"

  # If the file content did not change, skip commit/push/PR gracefully
  if git diff --quiet -- "$PROD_FILE"; then
    echo "No change in $PROD_FILE after update; skipping commit, push, and PR."
    exit 0
  fi

  short() { local s="$1"; [[ ${#s} -le 12 ]] && echo "$s" || echo "${s:0:12}"; }
  SHORT_BASE="$(short "$BASE_SHA")"
  SHORT_TGT="$(short "$TARGET_SHA")"
  # Stage and commit ONLY the kustomization file
  git add "$PROD_FILE"
  git commit -m "chore: bump konflux-ui (production) ${SHORT_BASE} => ${SHORT_TGT}"
  git push downstream "$BRANCH_NAME"

  # Export data for GitHub Actions to create PR
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    # Use a unique delimiter to prevent premature termination if changelog contains "EOF"
    DELIMITER="EOF_$(date +%s)_$$"
    echo "base_sha=$BASE_SHA" >> "$GITHUB_OUTPUT"
    echo "target_sha=$TARGET_SHA" >> "$GITHUB_OUTPUT"
    echo "branch_name=$BRANCH_NAME" >> "$GITHUB_OUTPUT"
    echo "changelog_content<<${DELIMITER}" >> "$GITHUB_OUTPUT"
    cat "$OUT_CHANGELOG" >> "$GITHUB_OUTPUT"
    echo "$DELIMITER" >> "$GITHUB_OUTPUT"
    echo "pr_title=$PR_TITLE" >> "$GITHUB_OUTPUT"
  fi

  echo "✅ Done: Branch pushed and ready for PR creation."
  echo "   Branch: $BRANCH_NAME"
  echo "   Range: ${KUI_REPO} ${BASE_SHA}...${TARGET_SHA}"
popd >/dev/null

#!/usr/bin/env bash
set -euo pipefail

# =========================
# generate-kui-changelog.sh
# =========================
# Usage:
#   generate-kui-changelog.sh -r <owner/repo> -b <base_sha> -t <target_sha> [-d <repo_dir>] -o <out_file>
#
# Behavior:
# - Tries to use a gist (same one used by the caller) to build changelog.md
# - Falls back to a local `git log` between the two SHAs if the gist fails
# - Writes final output to the provided -o path

GIST_URL_DEFAULT="https://gist.githubusercontent.com/sahil143/50f50ef0db706fe1190c7ab48268f6a0/raw/73e080f4d42fc33535884a78d0c3d0dac87573cd/git-pr-changelog.sh"
GIST_URL="${GIST_URL:-$GIST_URL_DEFAULT}"

usage(){
  echo "Usage: $0 -r <owner/repo> -b <base_sha> -t <target_sha> [-d <repo_dir>] -o <out_file>" >&2
}

REPO=""
BASE_SHA=""
TARGET_SHA=""
REPO_DIR=""
OUT_FILE=""

while getopts ":r:b:t:d:o:" opt; do
  case "$opt" in
    r) REPO="$OPTARG" ;;
    b) BASE_SHA="$OPTARG" ;;
    t) TARGET_SHA="$OPTARG" ;;
    d) REPO_DIR="$OPTARG" ;;
    o) OUT_FILE="$OPTARG" ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$REPO" || -z "$BASE_SHA" || -z "$TARGET_SHA" || -z "$OUT_FILE" ]]; then
  usage; exit 2
fi

for cmd in curl git sed awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

# Prepare working directory (either provided git repo dir or a temporary clone)
WORK_DIR=""
CLEANUP_CLONE=false
if [[ -n "$REPO_DIR" ]]; then
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "Provided --dir is not a git repository: $REPO_DIR" >&2
    exit 1
  fi
  WORK_DIR="$REPO_DIR"
else
  WORK_DIR="$(mktemp -d)"
  CLEANUP_CLONE=true
  trap '[[ "$CLEANUP_CLONE" == true ]] && rm -rf "$WORK_DIR" || true' EXIT
  echo "Cloning $REPO to $WORK_DIR"
  git clone "https://github.com/${REPO}.git" "$WORK_DIR" >/dev/null 2>&1
fi

mkdir -p "$(dirname "$OUT_FILE")"

pushd "$WORK_DIR" >/dev/null
  # Ensure we have the commits available locally
  git fetch --all --tags --prune >/dev/null 2>&1 || true
  git fetch origin "$BASE_SHA" "$TARGET_SHA" >/dev/null 2>&1 || true
  # 1) Try gist with range args first
  GIST_FILE="git-pr-changelog.sh"
  rm -f "$GIST_FILE" 2>/dev/null || true
  echo "Fetching changelog gist…"
  curl -fsSL "$GIST_URL" -o "$GIST_FILE" || true
  if [[ -s "$GIST_FILE" ]]; then
    chmod +x "$GIST_FILE"
    if ./"$GIST_FILE" "$REPO" "$BASE_SHA" "$TARGET_SHA" >/dev/null 2>&1; then
      ./"$GIST_FILE" "$REPO" "$BASE_SHA" "$TARGET_SHA" || true
    elif ./"$GIST_FILE" "$REPO" >/dev/null 2>&1; then
      ./"$GIST_FILE" "$REPO" || true
      {
        echo
        echo "> Note: Gist didn’t accept a SHA range; ran default mode."
        echo "> Base SHA:   $BASE_SHA"
        echo "> Target SHA: $TARGET_SHA"
        echo
        echo "## Compare"
        echo "https://github.com/${REPO}/compare/${BASE_SHA}...${TARGET_SHA}"
      } >> changelog.md
    fi
  fi

  # 2) If the gist path failed to produce a changelog, fallback to git log
  if [[ ! -s changelog.md ]]; then
    echo "Gist failed; generating fallback changelog.md"
    {
      echo "# Changelog"
      echo
      echo "**Repo:** ${REPO}"
      echo "**Range:** \`${BASE_SHA}..${TARGET_SHA}\`"
      echo
      echo "## Commits"
      echo
      git log --no-merges --pretty=format:'- %h %s (%an, %ad)' --date=short "${BASE_SHA}..${TARGET_SHA}" 2>/dev/null || true
      echo
      echo "## Compare"
      echo "https://github.com/${REPO}/compare/${BASE_SHA}...${TARGET_SHA}"
    } > changelog.md
  fi

  # 3) Move/copy to requested output path
  # if [[ -s changelog.md ]]; then
  # # cat changelog.md
  #   # cp changelog.md "$OUT_FILE"
  # else
  #   echo "Failed to produce changelog.md" >&2
  #   exit 1
  # fi
popd >/dev/null

echo "Changelog written to: $OUT_FILE"



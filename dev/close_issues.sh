#!/usr/bin/env bash

# =========================
# close_issues.sh
# =========================
# Script to close released Jira issues found in changelog.md
#
# Only issues in "Release Pending" status will be automatically closed.
# Other issues will be listed with their ID, assignee, and status for manual review.
#
# Prerequisites:
#   - jq (for JSON parsing): brew install jq / apt-get install jq / yum install jq
#   - curl (usually pre-installed)
#   - Set environment variables:
#       - JIRA_URL (default: https://issues.redhat.com)
#       - JIRA_API_TOKEN (required)
#
# Usage:
#   ./close_issues.sh [OPTIONS]
#
# Options:
#   --changelog FILE    Path to changelog file (default: changelog.md)
#   --dry-run          Preview changes without actually closing issues
#   --version VERSION  Release version to include in Jira comments
#   --jira-url URL     Jira server URL (default: from JIRA_URL env or https://issues.redhat.com)
#   --rate-limit N     Delay in seconds between API calls (default: 1)
#   --help             Show this help message
#
# Examples:
#   # Dry run to preview what would be closed
#   ./close_issues.sh --dry-run --version v1.2.3
#
#   # Actually close issues in Release Pending status
#   ./close_issues.sh --version v1.2.3
#
# Security:
#   - All JSON payloads are properly escaped using jq
#   - Jira issue keys are validated against expected format
#   - Rate limiting prevents API abuse

set -euo pipefail

# =========================
# Configuration
# =========================

# Colors for output (disabled if not a terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# Default values
CHANGELOG_FILE="changelog.md"
DRY_RUN=false
VERSION=""
JIRA_URL="${JIRA_URL:-https://issues.redhat.com}"
JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
RATE_LIMIT_SECONDS="${RATE_LIMIT_SECONDS:-1}"

# Statistics
SUCCESS_COUNT=0
ALREADY_CLOSED_COUNT=0
NOT_RELEASE_PENDING_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

# Array to store non-release-pending issues
declare -a NON_RELEASE_PENDING_ISSUES=()

# =========================
# Helper Functions
# =========================

# Logging with timestamps
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# Print help from embedded documentation
print_help() {
  # Security fix: Use cat with heredoc instead of sed on $0
  cat << 'HELP_EOF'
close_issues.sh - Close released Jira issues from changelog

Usage:
  ./close_issues.sh [OPTIONS]

Options:
  --changelog FILE    Path to changelog file (default: changelog.md)
  --dry-run          Preview changes without actually closing issues
  --version VERSION  Release version to include in Jira comments
  --jira-url URL     Jira server URL (default: https://issues.redhat.com)
  --rate-limit N     Delay in seconds between API calls (default: 1)
  --help             Show this help message

Environment Variables:
  JIRA_URL           Jira server URL
  JIRA_API_TOKEN     Jira API token (required)

Examples:
  # Dry run to preview what would be closed
  ./close_issues.sh --dry-run --version v1.2.3

  # Actually close issues in Release Pending status
  ./close_issues.sh --version v1.2.3

  # Use custom changelog and rate limit
  ./close_issues.sh --changelog /path/to/CHANGELOG.md --rate-limit 2
HELP_EOF
  exit 0
}

# Print section separator
print_separator() {
  echo "============================================================"
}

# Validate Jira issue key format (e.g., KFLUXUI-123, ROK-818)
validate_issue_key() {
  local key="$1"
  if [[ ! "$key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
    log_warn "Invalid Jira issue key format: $key"
    return 1
  fi
  # Additional check: key should be reasonable length
  if [[ ${#key} -gt 50 ]]; then
    log_warn "Jira issue key too long: $key"
    return 1
  fi
  return 0
}

# Validate URL format
validate_url() {
  local url="$1"
  if [[ ! "$url" =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9](:[0-9]+)?(/.*)?$ ]]; then
    log_error "Invalid URL format: $url"
    return 1
  fi
  return 0
}

# Validate version format (alphanumeric, dots, dashes, underscores)
validate_version() {
  local version="$1"
  if [[ ! "$version" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    log_error "Invalid version format: $version (allowed: alphanumeric, dots, dashes, underscores)"
    return 1
  fi
  if [[ ${#version} -gt 100 ]]; then
    log_error "Version string too long (max 100 characters)"
    return 1
  fi
  return 0
}

# Validate file path (no directory traversal)
validate_file_path() {
  local path="$1"
  if [[ "$path" == *".."* ]]; then
    log_error "Invalid file path: directory traversal not allowed"
    return 1
  fi
  return 0
}

# Rate limiting
rate_limit() {
  if [[ "$RATE_LIMIT_SECONDS" -gt 0 ]]; then
    sleep "$RATE_LIMIT_SECONDS"
  fi
}

# =========================
# Dependency Checks
# =========================

check_dependencies() {
  if ! command -v jq &> /dev/null; then
    log_error "'jq' is required but not installed."
    echo "Please install jq:"
    echo "  macOS:   brew install jq"
    echo "  Ubuntu:  sudo apt-get install jq"
    echo "  RHEL:    sudo yum install jq"
    exit 1
  fi

  if ! command -v curl &> /dev/null; then
    log_error "'curl' is required but not installed."
    exit 1
  fi
}

# =========================
# Argument Parsing
# =========================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --changelog)
        if [[ -z "${2:-}" ]]; then
          log_error "--changelog requires a file path argument"
          exit 1
        fi
        CHANGELOG_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --version)
        if [[ -z "${2:-}" ]]; then
          log_error "--version requires a version string argument"
          exit 1
        fi
        VERSION="$2"
        shift 2
        ;;
      --jira-url)
        if [[ -z "${2:-}" ]]; then
          log_error "--jira-url requires a URL argument"
          exit 1
        fi
        JIRA_URL="$2"
        shift 2
        ;;
      --rate-limit)
        if [[ -z "${2:-}" ]]; then
          log_error "--rate-limit requires a number argument"
          exit 1
        fi
        RATE_LIMIT_SECONDS="$2"
        shift 2
        ;;
      --help|-h)
        print_help
        ;;
      -*)
        log_error "Unknown option: $1"
        echo "Use --help to see available options"
        exit 1
        ;;
      *)
        log_error "Unexpected argument: $1"
        echo "Use --help to see available options"
        exit 1
        ;;
    esac
  done
}

# =========================
# Input Validation
# =========================

validate_inputs() {
  # Validate changelog path
  validate_file_path "$CHANGELOG_FILE" || exit 1
  
  # Validate version if provided
  if [[ -n "$VERSION" ]]; then
    validate_version "$VERSION" || exit 1
  fi
  
  # Validate Jira URL
  validate_url "$JIRA_URL" || exit 1
  
  # Validate rate limit
  if [[ ! "$RATE_LIMIT_SECONDS" =~ ^[0-9]+$ ]]; then
    log_error "Rate limit must be a non-negative integer"
    exit 1
  fi
  
  # Check for API token
  if [[ -z "$JIRA_API_TOKEN" ]]; then
    log_error "JIRA_API_TOKEN environment variable is required"
    echo ""
    echo "Please set the JIRA_API_TOKEN environment variable:"
    echo "  export JIRA_API_TOKEN='your-token-here'"
    exit 1
  fi
}

# =========================
# Jira Issue Extraction
# =========================

extract_jira_issues() {
  if [[ ! -f "$CHANGELOG_FILE" ]]; then
    log_error "Changelog file not found: $CHANGELOG_FILE"
    exit 1
  fi

  # Extract Jira issue keys (e.g., KFLUXUI-123, ROK-818)
  # Pattern: 1+ uppercase letters, dash, 1+ digits
  local raw_issues
  raw_issues=$(grep -oE '\b[A-Z][A-Z0-9]*-[0-9]+\b' "$CHANGELOG_FILE" 2>/dev/null | sort -u || true)
  
  # Validate each issue key
  local validated_issues=""
  while IFS= read -r key; do
    if [[ -n "$key" ]] && validate_issue_key "$key"; then
      validated_issues+="$key"$'\n'
    fi
  done <<< "$raw_issues"
  
  # Remove trailing newline
  echo -n "$validated_issues" | sed '/^$/d'
}

# =========================
# Jira API Functions
# =========================

# Get issue details from Jira
get_issue() {
  local issue_key="$1"
  
  # Validate issue key before making API call
  validate_issue_key "$issue_key" || return 1
  
  local url="${JIRA_URL}/rest/api/2/issue/${issue_key}"
  local response
  local http_code
  local body
  
  response=$(curl -s -w "\n%{http_code}" \
    --max-time 30 \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
    "$url")

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "404" ]]; then
    echo "  ⚠️  Issue $issue_key not found"
    return 1
  elif [[ "$http_code" != "200" ]]; then
    echo "  ❌ Error fetching $issue_key: HTTP $http_code"
    return 1
  fi

  echo "$body"
}

# Get available transitions for an issue
get_transitions() {
  local issue_key="$1"
  local url="${JIRA_URL}/rest/api/2/issue/${issue_key}/transitions"

  curl -s --max-time 30 \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
    "$url"
}

# Transition issue to Done
transition_issue() {
  local issue_key="$1"
  local url="${JIRA_URL}/rest/api/2/issue/${issue_key}/transitions"

  # Get available transitions
  local transitions
  transitions=$(get_transitions "$issue_key")

  if [[ -z "$transitions" ]]; then
    echo "  ⚠️  No transitions available for $issue_key"
    return 1
  fi

  # Find transition ID for Done/Close/Closed/Resolve/Resolved
  local transition_id=""
  local transition_name=""
  
  for name in "Done" "Close" "Closed" "Resolve" "Resolved"; do
    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    transition_id=$(echo "$transitions" | jq -r ".transitions[] | select(.name | ascii_downcase == \"$name_lower\") | .id" 2>/dev/null | head -n1)
    if [[ -n "$transition_id" && "$transition_id" != "null" ]]; then
      transition_name="$name"
      break
    fi
  done

  if [[ -z "$transition_id" || "$transition_id" == "null" ]]; then
    echo "  ⚠️  No suitable transition found for $issue_key"
    local available
    available=$(echo "$transitions" | jq -r '.transitions[].name' 2>/dev/null | tr '\n' ', ' | sed 's/,$//' || echo "none")
    echo "     Available transitions: $available"
    return 1
  fi

  # Security fix: Build JSON payload using jq to properly escape values
  local payload
  payload=$(jq -n --arg id "$transition_id" '{"transition": {"id": $id}}')

  # Perform transition
  local response
  local http_code
  response=$(curl -s -w "\n%{http_code}" -X POST \
    --max-time 30 \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
    -d "$payload" \
    "$url")

  http_code=$(echo "$response" | tail -n1)

  if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
    echo "  ✅ Transitioned $issue_key to '$transition_name'"
    return 0
  else
    echo "  ❌ Error transitioning $issue_key: HTTP $http_code"
    return 1
  fi
}

# Add comment to issue
add_comment() {
  local issue_key="$1"
  local comment="$2"
  local url="${JIRA_URL}/rest/api/2/issue/${issue_key}/comment"

  # Security fix: Build JSON payload using jq to properly escape the comment
  local payload
  payload=$(jq -n --arg body "$comment" '{"body": $body}')

  local response
  local http_code
  response=$(curl -s -w "\n%{http_code}" -X POST \
    --max-time 30 \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
    -d "$payload" \
    "$url")

  http_code=$(echo "$response" | tail -n1)

  if [[ "$http_code" == "201" ]] || [[ "$http_code" == "200" ]]; then
    echo "  💬 Added comment to $issue_key"
    return 0
  else
    echo "  ❌ Error adding comment to $issue_key: HTTP $http_code"
    return 1
  fi
}

# =========================
# Issue Processing
# =========================

process_issue() {
  local issue_key="$1"

  echo ""
  echo "🔍 Processing $issue_key..."

  # Rate limiting between API calls
  rate_limit

  # Get issue details
  local issue
  if ! issue=$(get_issue "$issue_key"); then
    ((FAILED_COUNT++)) || true
    return 1
  fi

  # Extract status and assignee using jq (safe parsing)
  local status
  local assignee
  status=$(echo "$issue" | jq -r '.fields.status.name // "Unknown"' 2>/dev/null || echo "Unknown")
  assignee=$(echo "$issue" | jq -r '.fields.assignee.displayName // "Unassigned"' 2>/dev/null || echo "Unassigned")

  echo "  📊 Current status: $status"
  echo "  👤 Assignee: $assignee"

  # Check if already closed
  local status_lower
  status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
  
  if [[ "$status_lower" == "done" ]] || [[ "$status_lower" == "closed" ]] || [[ "$status_lower" == "resolved" ]]; then
    echo "  ℹ️  Issue is already $status"
    ((ALREADY_CLOSED_COUNT++)) || true
    return 0
  fi

  # Check if status is "Release Pending"
  if [[ "$status_lower" != "release pending" ]]; then
    echo "  ⏭️  Skipping - Not in 'Release Pending' status"
    NON_RELEASE_PENDING_ISSUES+=("$issue_key|$status|$assignee")
    ((NOT_RELEASE_PENDING_COUNT++)) || true
    return 0
  fi

  # Issue is in "Release Pending" status
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  🔸 [DRY RUN] Would transition $issue_key to Done"
    if [[ -n "$VERSION" ]]; then
      echo "  🔸 [DRY RUN] Would add comment: Released in version $VERSION"
    fi
    ((SKIPPED_COUNT++)) || true
    return 0
  fi

  # Add comment about release
  if [[ -n "$VERSION" ]]; then
    rate_limit
    add_comment "$issue_key" "This issue has been released in version $VERSION."
  fi

  # Transition to Done
  rate_limit
  if transition_issue "$issue_key"; then
    ((SUCCESS_COUNT++)) || true
  else
    ((FAILED_COUNT++)) || true
  fi
}

# =========================
# Output for GitHub Actions
# =========================

output_github_summary() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "issues_closed=$SUCCESS_COUNT"
      echo "issues_already_closed=$ALREADY_CLOSED_COUNT"
      echo "issues_skipped=$NOT_RELEASE_PENDING_COUNT"
      echo "issues_failed=$FAILED_COUNT"
    } >> "$GITHUB_OUTPUT"
  fi
  
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## Jira Issue Closer Summary"
      echo ""
      echo "| Metric | Count |"
      echo "|--------|-------|"
      echo "| ✅ Successfully closed | $SUCCESS_COUNT |"
      echo "| ℹ️ Already closed | $ALREADY_CLOSED_COUNT |"
      echo "| ⏭️ Not 'Release Pending' | $NOT_RELEASE_PENDING_COUNT |"
      echo "| ⚠️ Skipped (dry-run) | $SKIPPED_COUNT |"
      echo "| ❌ Failed | $FAILED_COUNT |"
      
      if [[ ${#NON_RELEASE_PENDING_ISSUES[@]} -gt 0 ]]; then
        echo ""
        echo "### Issues Not Auto-Closed (Not in 'Release Pending' status)"
        echo ""
        echo "| Issue | Status | Assignee |"
        echo "|-------|--------|----------|"
        for item in "${NON_RELEASE_PENDING_ISSUES[@]}"; do
          IFS='|' read -r key status assignee <<< "$item"
          echo "| $key | $status | $assignee |"
        done
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# =========================
# Main Function
# =========================

main() {
  # Check dependencies
  check_dependencies

  # Parse arguments
  parse_args "$@"
  
  # Validate all inputs
  validate_inputs

  # Print header
  print_separator
  echo "🚀 Jira Issue Closer for Released Changes"
  print_separator

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
  fi

  # Extract issues from changelog
  echo ""
  log_info "Reading changelog: $CHANGELOG_FILE"

  local issues
  issues=$(extract_jira_issues)

  if [[ -z "$issues" ]]; then
    echo ""
    log_info "No Jira issues found in changelog"
    output_github_summary
    exit 0
  fi

  # Count issues
  local issue_count
  issue_count=$(echo "$issues" | wc -l | tr -d ' ')

  echo ""
  echo "📋 Found $issue_count unique Jira issue(s):"
  echo "$issues" | while IFS= read -r issue; do
    [[ -n "$issue" ]] && echo "  - $issue"
  done

  echo ""
  log_info "Connected to Jira: $JIRA_URL"
  log_info "Rate limit: ${RATE_LIMIT_SECONDS}s between API calls"

  # Process issues
  echo ""
  print_separator
  echo "🔄 Processing issues..."
  print_separator

  while IFS= read -r issue_key; do
    [[ -n "$issue_key" ]] && process_issue "$issue_key" || true
  done <<< "$issues"

  # Print non-release-pending issues
  if [[ ${#NON_RELEASE_PENDING_ISSUES[@]} -gt 0 ]]; then
    echo ""
    print_separator
    echo "📋 Issues NOT in 'Release Pending' status (not auto-closed):"
    print_separator
    for item in "${NON_RELEASE_PENDING_ISSUES[@]}"; do
      IFS='|' read -r key status assignee <<< "$item"
      printf "  • %-15s Status: %-20s Assignee: %s\n" "$key" "$status" "$assignee"
    done
  fi

  # Print summary
  echo ""
  print_separator
  echo "📊 Summary"
  print_separator
  printf "✅ Successfully closed:        %d\n" "$SUCCESS_COUNT"
  printf "ℹ️  Already closed:            %d\n" "$ALREADY_CLOSED_COUNT"
  printf "⏭️  Not 'Release Pending':     %d\n" "$NOT_RELEASE_PENDING_COUNT"
  printf "⚠️  Skipped (dry-run):         %d\n" "$SKIPPED_COUNT"
  printf "❌ Failed:                    %d\n" "$FAILED_COUNT"
  printf "📝 Total processed:           %d\n" "$issue_count"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "💡 Run without --dry-run to actually close the issues"
  fi

  if [[ $NOT_RELEASE_PENDING_COUNT -gt 0 ]]; then
    echo ""
    echo "💡 Note: Issues not in 'Release Pending' status are listed above but not auto-closed"
  fi

  # Output for GitHub Actions
  output_github_summary

  # Exit with failure if any issues failed
  if [[ $FAILED_COUNT -gt 0 ]]; then
    exit 1
  fi
}

# Run main function
main "$@"

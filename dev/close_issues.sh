#!/bin/bash

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
#   --help             Show this help message
#
# Examples:
#   # Dry run to preview what would be closed
#   ./close_issues.sh --dry-run --version v1.2.3
#
#   # Actually close issues in Release Pending status
#   ./close_issues.sh --version v1.2.3

set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CHANGELOG_FILE="changelog.md"
DRY_RUN=false
VERSION=""
JIRA_URL="${JIRA_URL:-https://issues.redhat.com}"
JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"

# Statistics
SUCCESS_COUNT=0
ALREADY_CLOSED_COUNT=0
NOT_RELEASE_PENDING_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

# Array to store non-release-pending issues
declare -a NON_RELEASE_PENDING_ISSUES=()

# Function to print help
print_help() {
    sed -n '2,34p' "$0" | sed 's/^# \?//'
    exit 0
}

# Function to print colored output
print_color() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

# Function to print section separator
print_separator() {
    echo "============================================================"
}

# Check if jq is installed
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        print_color "$RED" "❌ Error: 'jq' is required but not installed."
        echo "Please install jq:"
        echo "  macOS:   brew install jq"
        echo "  Ubuntu:  sudo apt-get install jq"
        echo "  RHEL:    sudo yum install jq"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        print_color "$RED" "❌ Error: 'curl' is required but not installed."
        exit 1
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --changelog)
                CHANGELOG_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --jira-url)
                JIRA_URL="$2"
                shift 2
                ;;
            --help|-h)
                print_help
                ;;
            *)
                print_color "$RED" "❌ Unknown option: $1"
                echo "Use --help to see available options"
                exit 1
                ;;
        esac
    done
}

# Extract Jira issues from changelog
extract_jira_issues() {
    if [[ ! -f "$CHANGELOG_FILE" ]]; then
        print_color "$RED" "❌ Changelog file not found: $CHANGELOG_FILE"
        exit 1
    fi

    # Extract Jira issue keys (e.g., KFLUXUI-123, ROK-818)
    grep -oE '\b[A-Z]+-[0-9]+\b' "$CHANGELOG_FILE" | sort -u
}

# Get issue details from Jira
get_issue() {
    local issue_key=$1
    local url="${JIRA_URL}/rest/api/2/issue/${issue_key}"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
        "$url")

    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

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
    local issue_key=$1
    local url="${JIRA_URL}/rest/api/2/issue/${issue_key}/transitions"

    local response
    response=$(curl -s \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
        "$url")

    echo "$response"
}

# Transition issue to Done
transition_issue() {
    local issue_key=$1
    local url="${JIRA_URL}/rest/api/2/issue/${issue_key}/transitions"

    # Get available transitions
    local transitions
    transitions=$(get_transitions "$issue_key")

    if [[ -z "$transitions" ]]; then
        echo "  ⚠️  No transitions available for $issue_key"
        return 1
    fi

    # Find transition ID for Done/Close/Closed/Resolve/Resolved
    local transition_id
    local transition_name
    for name in "Done" "Close" "Closed" "Resolve" "Resolved"; do
        transition_id=$(echo "$transitions" | jq -r ".transitions[] | select(.name | ascii_downcase == \"${name,,}\") | .id" | head -n1)
        if [[ -n "$transition_id" ]]; then
            transition_name="$name"
            break
        fi
    done

    if [[ -z "$transition_id" ]]; then
        echo "  ⚠️  No suitable transition found for $issue_key"
        local available=$(echo "$transitions" | jq -r '.transitions[].name' | tr '\n' ', ' | sed 's/,$//')
        echo "     Available transitions: $available"
        return 1
    fi

    # Perform transition
    local response
    local http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
        -d "{\"transition\":{\"id\":\"${transition_id}\"}}" \
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
    local issue_key=$1
    local comment=$2
    local url="${JIRA_URL}/rest/api/2/issue/${issue_key}/comment"

    local response
    local http_code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
        -d "{\"body\":\"${comment}\"}" \
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

# Process a single issue
process_issue() {
    local issue_key=$1

    echo ""
    echo "🔍 Processing $issue_key..."

    # Get issue details
    local issue
    if ! issue=$(get_issue "$issue_key"); then
        ((FAILED_COUNT++))
        return 1
    fi

    # Extract status and assignee
    local status
    status=$(echo "$issue" | jq -r '.fields.status.name // "Unknown"')

    local assignee
    assignee=$(echo "$issue" | jq -r '.fields.assignee.displayName // "Unassigned"')

    echo "  📊 Current status: $status"
    echo "  👤 Assignee: $assignee"

    # Check if already closed
    local status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
    if [[ "$status_lower" == "done" ]] || [[ "$status_lower" == "closed" ]] || [[ "$status_lower" == "resolved" ]]; then
        echo "  ℹ️  Issue is already $status"
        ((ALREADY_CLOSED_COUNT++))
        return 0
    fi

    # Check if status is "Release Pending"
    if [[ "$status_lower" != "release pending" ]]; then
        echo "  ⏭️  Skipping - Not in 'Release Pending' status"
        NON_RELEASE_PENDING_ISSUES+=("$issue_key|$status|$assignee")
        ((NOT_RELEASE_PENDING_COUNT++))
        return 0
    fi

    # Issue is in "Release Pending" status
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  🔸 [DRY RUN] Would transition $issue_key to Done"
        if [[ -n "$VERSION" ]]; then
            echo "  🔸 [DRY RUN] Would add comment: Released in version $VERSION"
        fi
        ((SKIPPED_COUNT++))
        return 0
    fi

    # Add comment about release
    if [[ -n "$VERSION" ]]; then
        add_comment "$issue_key" "This issue has been released in version $VERSION."
    fi

    # Transition to Done
    if transition_issue "$issue_key"; then
        ((SUCCESS_COUNT++))
    else
        ((FAILED_COUNT++))
    fi
}

# Main function
main() {
    # Check dependencies
    check_dependencies

    # Parse arguments
    parse_args "$@"

    # Print header
    print_separator
    echo "🚀 Jira Issue Closer for Released Changes"
    print_separator

    if [[ "$DRY_RUN" == "true" ]]; then
        print_color "$YELLOW" "⚠️  DRY RUN MODE - No changes will be made"
    fi

    # Check for API token
    if [[ -z "$JIRA_API_TOKEN" ]]; then
        print_color "$RED" "❌ JIRA_API_TOKEN environment variable is required"
        echo ""
        echo "Please set the JIRA_API_TOKEN environment variable:"
        echo "  export JIRA_API_TOKEN='your-token-here'"
        exit 1
    fi

    # Extract issues from changelog
    echo ""
    echo "📖 Reading changelog: $CHANGELOG_FILE"

    local issues
    issues=$(extract_jira_issues)

    if [[ -z "$issues" ]]; then
        echo ""
        echo "✅ No Jira issues found in changelog"
        exit 0
    fi

    # Count issues
    local issue_count
    issue_count=$(echo "$issues" | wc -l | tr -d ' ')

    echo ""
    echo "📋 Found $issue_count unique Jira issue(s):"
    echo "$issues" | while read -r issue; do
        echo "  - $issue"
    done

    echo ""
    echo "🔗 Connected to Jira: $JIRA_URL"

    # Process issues
    echo ""
    print_separator
    echo "🔄 Processing issues..."
    print_separator

    while read -r issue_key; do
        process_issue "$issue_key" || true
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
}

# Run main function
main "$@"

#!/usr/bin/env bash
set -euo pipefail

# Review Loop — Setup Script
# Creates state file and prepares the review loop lifecycle.

ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      cat << 'HELP'
Usage: /review-loop <task description>

Starts a review loop:
  1. Claude implements your task
  2. Codex performs an independent code review
  3. Claude addresses the feedback

Environment variables:
  REVIEW_LOOP_CODEX_FLAGS  Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)

Example:
  /review-loop Add user authentication with JWT tokens and proper test coverage
HELP
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

PROMPT="${ARGS[*]:-}"

if [ -z "$PROMPT" ]; then
  echo "Error: No task description provided."
  echo "Usage: /review-loop <task description>"
  exit 1
fi

# Check dependencies
if ! command -v codex &> /dev/null; then
  echo "Warning: 'codex' CLI not found. The review phase will fall back to self-review."
  echo "Install Codex CLI to enable independent code reviews."
fi

if ! command -v jq &> /dev/null; then
  echo "Error: 'jq' is required but not found."
  echo "  macOS:  brew install jq"
  echo "  Linux:  apt install jq  /  yum install jq"
  echo "  Docs:   https://jqlang.github.io/jq/download/"
  exit 1
fi

# Check for existing loop
if [ -f ".claude/review-loop.local.md" ]; then
  echo "Error: A review loop is already active. Use /cancel-review to abort it first."
  exit 1
fi

# Generate unique ID: timestamp + random hex
# Prefer openssl, fallback to /dev/urandom
if command -v openssl &> /dev/null; then
  RAND_HEX=$(openssl rand -hex 3)
else
  RAND_HEX=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
REVIEW_ID="$(date +%Y%m%d-%H%M%S)-${RAND_HEX}"

# Clean up stale lock and transient files from previous runs
rm -f .claude/review-loop.lock .claude/review-loop-run-codex.sh .claude/review-loop-codex-prompt.txt .claude/review-loop-retries

# Create state file
mkdir -p .claude
cat > .claude/review-loop.local.md << STATE_EOF
---
active: true
phase: task
review_id: ${REVIEW_ID}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

${PROMPT}
STATE_EOF

# Ensure reviews directory exists
mkdir -p reviews

echo ""
echo "Review Loop activated"
echo "  ID:      ${REVIEW_ID}"
echo "  Phase:   1/2 — Task implementation"
echo "  Review:  reviews/review-${REVIEW_ID}.md"
echo ""
echo "  Lifecycle:"
echo "    1. You implement the task"
echo "    2. Stop hook runs Codex for independent review"
echo "    3. You address the feedback"
echo ""
echo "  Use /cancel-review to abort."
echo ""

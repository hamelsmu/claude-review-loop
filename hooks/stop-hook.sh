#!/usr/bin/env bash
# Review Loop — Stop Hook
#
# Two-phase lifecycle:
#   Phase 1 (task):       Claude finishes work → hook runs Codex review → blocks exit
#   Phase 2 (addressing): Claude addresses review → hook allows exit
#
# On any error, default to allowing exit (never trap the user in a broken loop).
#
# Environment variables:
#   REVIEW_LOOP_CODEX_FLAGS  Override codex flags (default: --dangerously-bypass-approvals-and-sandbox)

LOG_FILE=".claude/review-loop.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin (hook input JSON) — must read to avoid broken pipe
HOOK_INPUT=$(cat)

STATE_FILE=".claude/review-loop.local.md"

# No active loop → allow exit
if [ ! -f "$STATE_FILE" ]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Parse a field from the YAML frontmatter
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
REVIEW_ID=$(parse_field "review_id")

# Not active → clean up and exit
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Validate review_id format to prevent path traversal
if ! echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid review_id format: $REVIEW_ID"
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

# Safety: if stop_hook_active is true and we're still in "task" phase,
# something went wrong with the phase transition. Allow exit to prevent loops.
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ] && [ "$PHASE" = "task" ]; then
  log "WARN: stop_hook_active=true in task phase, aborting to prevent loop"
  rm -f "$STATE_FILE"
  printf '{"decision":"approve"}\n'
  exit 0
fi

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Run Codex for independent code review ──────────────
    REVIEW_FILE="reviews/review-${REVIEW_ID}.md"
    mkdir -p reviews

    CODEX_PROMPT="You are performing a thorough, independent code review of recent changes in this repository.

Step 1: Understand the changes
- Run git log --oneline -20 and git diff to see recent changes
- Read all modified/added files carefully

Step 2: Write your complete review to: ${REVIEW_FILE}

Your review MUST include ALL of these sections:

## Code Quality
- Code organization, modularity, and structure
- Maintainability and readability
- DRY principles and appropriate abstractions
- Naming conventions and consistency

## Test Coverage
- Tests for new/changed functionality
- Edge cases and error paths covered
- Test quality and maintainability

## Security
- Input validation and sanitization
- Authentication/authorization issues
- Injection vulnerabilities (SQL, XSS, command injection)
- Secret/credential exposure risks
- OWASP Top 10 considerations

## Documentation & Agent Harness
- AGENTS.md files in appropriate directories
- CLAUDE.md symlinks for each AGENTS.md
- Telemetry/observability instrumentation
- Type system usage and constraints
- Agent guardrails and setup for success

## UX & Design (only if the project has a user interface)
- E2E workflow test coverage using agent-browser (https://agent-browser.dev/)
  Install: claude install-skill https://agent-browser.dev
  Use agent-browser to navigate the running app, perform end-to-end workflow tests,
  and take screenshots to visually verify UX and design quality.
- Visual design quality and consistency
- Accessibility considerations
- Responsive design (test at desktop and mobile viewports)

For each issue found, provide:
1. File path and line number
2. Severity: critical / high / medium / low
3. Category
4. Description
5. Suggested fix

Organize by severity (critical first). End with a summary: total issues, breakdown by severity, overall assessment.

IMPORTANT: Write the FULL review to ${REVIEW_FILE}. You must create that file."

    # Run codex non-interactively with telemetry logging.
    # REVIEW_LOOP_CODEX_FLAGS overrides the default flags.
    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
    CODEX_EXIT=0
    START_TIME=$(date +%s)

    if command -v codex &> /dev/null; then
      log "Starting Codex review (flags: $CODEX_FLAGS)"
      # shellcheck disable=SC2086
      codex $CODEX_FLAGS exec "$CODEX_PROMPT" >/dev/null 2>&1 || CODEX_EXIT=$?
      ELAPSED=$(( $(date +%s) - START_TIME ))
      log "Codex finished (exit=$CODEX_EXIT, elapsed=${ELAPSED}s)"
    else
      log "WARN: codex not found, skipping independent review"
    fi

    # Transition to addressing phase
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    else
      sed -i 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    fi

    # Build prompt for Claude based on whether the review file was created
    if [ -f "$REVIEW_FILE" ]; then
      REASON="An independent code review from Codex has been written to ${REVIEW_FILE}.

Please:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them
5. Focus on critical and high severity items first
6. When done addressing all relevant items, you may stop

Use your own judgment. Do not blindly accept every suggestion."
    else
      REASON="Codex was unable to complete the review (${REVIEW_FILE} not found). This may mean codex is not installed or timed out.

Please do a brief self-review of your changes covering:
- Code quality and organization
- Security vulnerabilities
- Test coverage
- Documentation (AGENTS.md)

When satisfied, you may stop."
    fi

    SYS_MSG="Review Loop [${REVIEW_ID}] — Phase 2/2: Address Codex feedback"

    jq -n --arg r "$REASON" --arg s "$SYS_MSG" \
      '{decision:"block", reason:$r, systemMessage:$s}'
    ;;

  addressing)
    # ── Phase 2 complete: Claude addressed the review. Allow exit. ───────
    log "Review loop complete (review_id=$REVIEW_ID)"
    rm -f "$STATE_FILE"
    printf '{"decision":"approve"}\n'
    ;;

  *)
    # Unknown phase — clean up and allow exit
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE"
    printf '{"decision":"approve"}\n'
    ;;
esac

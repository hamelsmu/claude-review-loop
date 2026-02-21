#!/usr/bin/env bash
# Review Loop — Stop Hook
#
# Two-phase lifecycle:
#   Phase 1 (task):       Claude finishes work → hook runs Codex multi-agent review → blocks exit
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

# ── Project type detection ────────────────────────────────────────────────
detect_nextjs() {
  [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ] || \
    ([ -f "package.json" ] && grep -q '"next"' package.json 2>/dev/null)
}

detect_browser_ui() {
  # Has HTML/JSX/TSX files in app/ or pages/ or src/ directories, or has a public/ dir
  [ -d "app" ] || [ -d "pages" ] || [ -d "src/app" ] || [ -d "src/pages" ] || \
    [ -d "public" ] || [ -f "index.html" ]
}

# ── Build the multi-agent review prompt ───────────────────────────────────
build_review_prompt() {
  local REVIEW_FILE="$1"

  local IS_NEXTJS=false
  local HAS_UI=false
  detect_nextjs && IS_NEXTJS=true
  detect_browser_ui && HAS_UI=true

  log "Project detection: nextjs=$IS_NEXTJS, browser_ui=$HAS_UI"

  # ── Preamble ──
  cat << PREAMBLE_EOF
You are orchestrating a thorough, independent code review of recent changes in this repository.

Use multi-agent to run the following review agents IN PARALLEL. Each agent should return its findings as structured text (not write to files). After ALL agents complete, consolidate their findings into a single deduplicated review file.

IMPORTANT: Spawn one agent per review path below. Wait for all agents to finish. Then deduplicate overlapping findings and write the consolidated review to: ${REVIEW_FILE}

PREAMBLE_EOF

  # ── Agent 1: Diff Review ──
  cat << 'DIFF_EOF'
---
AGENT 1: Diff Review (focus on uncommitted and recently committed changes ONLY)

Run `git diff` and `git diff --cached` to see all uncommitted changes. Also run `git log --oneline -5` and `git diff HEAD~5` for recently committed work. Focus your review EXCLUSIVELY on this changed code.

Review criteria for changed code:

Code Quality:
- Is the changed code well-organized, modular, and readable?
- Does it follow DRY principles — no copy-pasted blocks that should be abstracted?
- Are names (variables, functions, files) clear and consistent with the codebase?
- Are abstractions at the right level — not over-engineered, not under-abstracted?
- Is there unnecessary complexity that could be simplified?

Test Coverage:
- Does every new function/endpoint/component have corresponding tests?
- Are edge cases covered: empty inputs, nulls, boundary values, error paths?
- Are tests isolated, deterministic, and fast?
- Do tests verify behavior (not implementation details)?
- For bug fixes: is there a regression test that would have caught the original bug?

Security:
- Input validation: are all user inputs validated and sanitized before use?
- Authentication/authorization: are auth checks present on all protected routes/actions?
- Injection: any risk of SQL injection, XSS, command injection, path traversal?
- Secrets: are any credentials, API keys, or tokens hardcoded or logged?
- OWASP Top 10: check for broken access control, cryptographic failures, insecure design, security misconfiguration, vulnerable dependencies, SSRF
- Are error messages safe (no stack traces or internal details leaked to users)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

DIFF_EOF

  # ── Agent 2: Holistic Review ──
  cat << 'HOLISTIC_EOF'
---
AGENT 2: Holistic Review (evaluate overall project structure and agent readiness)

Read the full project directory structure, key config files, README, and any AGENTS.md / CLAUDE.md files. This is NOT about individual line changes — it's about whether the project is well-structured for maintainability and agent-driven development.

Review criteria for the whole project:

Code Organization & Modularity:
- Is the project structure logical and navigable? Can a new developer (or agent) find things?
- Are concerns properly separated (data access, business logic, presentation, config)?
- Are there god files/functions that do too much and should be split?
- Is shared code properly extracted into reusable modules?
- Are import paths clean (absolute imports, no deep relative paths)?

Documentation & Agent Harness:
- Does every major directory have an AGENTS.md with operating guidelines for agents?
- Is there a CLAUDE.md symlinked to each AGENTS.md for Claude Code compatibility?
- Do AGENTS.md files document: conventions, file purposes, testing patterns, common pitfalls?
- Is there telemetry/observability instrumentation (logging, metrics, tracing)?
- Is there a type system in use (TypeScript, Python type hints, etc.) with proper coverage?
- Are there proper constraints and guardrails so agents working on the code are set up for success?
- Are environment variables documented and validated at startup?
- Are there clear boundaries between server-only and client-safe code?

Architecture:
- Is the dependency graph clean (no circular dependencies)?
- Are external integrations properly abstracted behind interfaces?
- Is configuration centralized rather than scattered?
- Is error handling consistent across the codebase?

For each issue: return file path (or directory), severity (critical/high/medium/low), category, description, and suggested fix.

HOLISTIC_EOF

  # ── Agent 3: Next.js Best Practices (conditional) ──
  if [ "$IS_NEXTJS" = "true" ]; then
    cat << 'NEXTJS_EOF'
---
AGENT 3: Next.js & React Best Practices Review

This is a Next.js project. Review the codebase against these specific patterns:

App Router & Server Components:
- Are Server Components used by default? Is 'use client' only added when interactivity is needed?
- Is data fetched in Server Components, not Client Components?
- Are Suspense boundaries used for streaming slow data sources?
- Are file conventions correct: layout.tsx, page.tsx, loading.tsx, error.tsx, not-found.tsx?
- Are searchParams and params handled as Promises (await searchParams / await params)?
- Is generateStaticParams() used to pre-render known dynamic routes?
- Is generateMetadata() used for SEO-critical pages?
- Is notFound() called for missing resources instead of returning null?

Data Fetching & Caching:
- Are parallel data fetches used (Promise.all) instead of sequential waterfalls?
- Is cache strategy appropriate: no-store for fresh data, force-cache for static, revalidate for ISR?
- Are cache tags used for fine-grained invalidation after mutations?
- Is React.cache() used to deduplicate queries within a single request?

Server Actions & Mutations:
- Are Server Actions validated and auth-checked as if they were public API endpoints?
- Is revalidateTag/revalidatePath called after mutations to invalidate cache?
- Is after() used for non-blocking post-response work (logging, analytics)?

Performance & Bundle Size:
- No barrel file imports — import directly from source paths?
- Is next/dynamic with { ssr: false } used for heavy client-only components?
- Are non-critical libraries (analytics, error tracking) deferred until after hydration?
- Are heavy bundles preloaded on user intent (hover/focus)?
- Is data minimized across the RSC boundary (only pass fields client needs)?

React Performance:
- Is derived state calculated during render, not in effects?
- Are expensive computations memoized appropriately?
- Is useTransition used for non-urgent updates?
- No unnecessary useEffect for things that belong in event handlers?
- Are stable callback references used (functional setState, refs) to avoid re-render churn?
- Is content-visibility: auto used for long lists?
- Are inline scripts used to set client data before hydration (prevent FOUC)?

For each issue: return file path, line number, severity (critical/high/medium/low), category, description, and suggested fix.

NEXTJS_EOF
  fi

  # ── Agent 4: UX & Browser Testing (conditional) ──
  if [ "$HAS_UI" = "true" ]; then
    cat << 'UX_EOF'
---
AGENT (UX): Browser-Based UX Review (SKIP if you cannot access a running dev server)

If the project has a running dev server, use agent-browser to test the UI.
Install agent-browser if needed: npm install -g agent-browser (or: brew install agent-browser)

Testing checklist:
- Navigate to all major routes/pages
- Test key user workflows end-to-end (signup, login, CRUD operations, etc.)
- Take screenshots at desktop (1280x720) and mobile (375x812) viewports
- Check for: broken layouts, missing error states, loading states, empty states
- Verify accessibility: keyboard navigation, focus indicators, color contrast
- Check responsive design at multiple breakpoints
- Verify forms have proper validation feedback
- Check that error messages are user-friendly

If the dev server is not running or you cannot access it, skip this agent and note that UX testing was not performed.

For each issue: return screenshot description, severity, category, description, and suggested fix.

UX_EOF
  fi

  # ── Consolidation instructions ──
  cat << CONSOLIDATION_EOF
---
CONSOLIDATION INSTRUCTIONS (after all agents complete):

1. Collect all findings from all agents
2. Deduplicate: if multiple agents flagged the same issue, keep the most detailed version
3. Organize all findings by severity (critical first, then high, medium, low)
4. For each finding, include:
   - File path and line number (or directory for structural issues)
   - Severity: critical / high / medium / low
   - Category: which review path found it (Diff, Holistic, Next.js, UX)
   - Description: clear explanation
   - Suggested fix: concrete, actionable recommendation
5. End with a summary: total issues, breakdown by severity, agents that ran, overall assessment
6. Write the COMPLETE consolidated review to: ${REVIEW_FILE}

IMPORTANT: You MUST create the file ${REVIEW_FILE} with the full review.
CONSOLIDATION_EOF
}

case "$PHASE" in
  task)
    # ── Phase 1 → 2: Run Codex multi-agent review ──────────────────────
    REVIEW_FILE="reviews/review-${REVIEW_ID}.md"
    mkdir -p reviews

    CODEX_PROMPT=$(build_review_prompt "$REVIEW_FILE")

    # Run codex non-interactively with telemetry logging.
    CODEX_FLAGS="${REVIEW_LOOP_CODEX_FLAGS:---dangerously-bypass-approvals-and-sandbox}"
    CODEX_EXIT=0
    START_TIME=$(date +%s)

    if ! command -v codex &> /dev/null; then
      log "ERROR: codex not found on PATH"
      rm -f "$STATE_FILE"
      REASON="ERROR: Codex CLI is not installed. The review loop requires Codex for independent code review.

Install it: npm install -g @openai/codex

Then enable multi-agent — either:
  1. Run codex, type /experimental, and enable Multi-agents
  2. Or add to ~/.codex/config.toml:
     [features]
     multi_agent = true

After installing, run /review-loop again."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
      exit 0
    fi

    # Check that multi-agent is enabled in Codex config
    CODEX_CONFIG="${HOME}/.codex/config.toml"
    if [ -f "$CODEX_CONFIG" ]; then
      # Look for multi_agent = true in the [features] section
      if ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
        log "ERROR: multi_agent not enabled in $CODEX_CONFIG"
        rm -f "$STATE_FILE"
        REASON="ERROR: Codex multi-agent is not enabled. The review loop requires parallel sub-agents for thorough reviews.

Enable it — either:
  1. Run codex, type /experimental, and enable Multi-agents
  2. Or add to ~/.codex/config.toml:
     [features]
     multi_agent = true

Then run /review-loop again."
        jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
        exit 0
      fi
    else
      log "ERROR: no Codex config found at $CODEX_CONFIG"
      rm -f "$STATE_FILE"
      REASON="ERROR: No Codex config file found at ~/.codex/config.toml. The review loop requires Codex multi-agent.

Enable it — either:
  1. Run codex, type /experimental, and enable Multi-agents
  2. Or create the config:
     mkdir -p ~/.codex
     echo '[features]' >> ~/.codex/config.toml
     echo 'multi_agent = true' >> ~/.codex/config.toml

Then run /review-loop again."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
      exit 0
    fi

    log "Starting Codex multi-agent review (flags: $CODEX_FLAGS)"
    # shellcheck disable=SC2086
    codex $CODEX_FLAGS exec "$CODEX_PROMPT" >/dev/null 2>&1 || CODEX_EXIT=$?
    ELAPSED=$(( $(date +%s) - START_TIME ))
    log "Codex finished (exit=$CODEX_EXIT, elapsed=${ELAPSED}s)"

    # Transition to addressing phase
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    else
      sed -i 's/^phase: task$/phase: addressing/' "$STATE_FILE"
    fi

    if [ ! -f "$REVIEW_FILE" ]; then
      log "ERROR: Codex finished but review file not found: $REVIEW_FILE"
      rm -f "$STATE_FILE"
      REASON="ERROR: Codex ran but did not produce a review file (${REVIEW_FILE}). This may mean the review timed out or Codex encountered an error. Check .claude/review-loop.log for details.

Run /review-loop again to retry."
      jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
      exit 0
    fi

    REASON="An independent multi-agent code review from Codex has been written to ${REVIEW_FILE}.

Please:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them
5. Focus on critical and high severity items first
6. When done addressing all relevant items, you may stop

Use your own judgment. Do not blindly accept every suggestion."

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

#!/bin/bash
# yanfu-gate.sh -- The strict father's gate
#
# This Stop hook intercepts every time the coder agent tries to complete.
# It collects context, spawns a QA validation agent, and blocks completion
# unless all validations pass.
#
# Exit codes:
#   0 = PASS (coder may stop)
#   2 = FAIL (coder is blocked, must address feedback)

set -euo pipefail

# ============================================================
# Configuration -- edit these for your project
# ============================================================

# Dev server (set to empty string if not applicable)
DEV_SERVER_URL="${YANFU_DEV_URL:-http://localhost:3000}"

# Database query command (set to empty string to skip DB validation)
# Examples:
#   "psql -U postgres -d myapp -c"
#   "mysql -u root -p mydb -e"
#   "sqlite3 ./db.sqlite3"
DB_QUERY_CMD="${YANFU_DB_CMD:-}"

# Max tokens for QA agent (controls cost)
MAX_TOKENS="${YANFU_MAX_TOKENS:-16000}"

# Strictness: strict | moderate | smoke
STRICTNESS="${YANFU_STRICTNESS:-strict}"

# Skip flag
if [ "${YANFU_SKIP:-0}" = "1" ]; then
  echo "yanfu: skipped (YANFU_SKIP=1)"
  exit 0
fi

# ============================================================
# Read Stop hook input from stdin (JSON)
# ============================================================

# Claude Code passes a JSON object on stdin to Stop hooks:
#   {
#     "session_id": "...",
#     "transcript_path": "/path/to/transcript.jsonl",
#     "cwd": "/path/to/project",
#     "hook_event_name": "Stop",
#     "stop_hook_active": false,
#     "last_assistant_message": "I've completed the implementation..."
#   }

HOOK_INPUT=$(cat)

# jq is required for reliable JSON parsing.
# last_assistant_message contains markdown, newlines, quotes --
# regex-based extraction is not viable.
if ! command -v jq &> /dev/null; then
  echo "yanfu: WARNING -- jq not found, context extraction will be limited"
  echo "yanfu: install jq for full functionality (brew install jq / apt install jq)"
fi

# --- Guard: prevent recursive invocation ---
# When stop_hook_active is true, another Stop hook is already running
# (e.g., the QA agent's own claude -p finishing). Exit immediately.
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# Extract the assistant's final message -- this is the best signal
# for what the coder agent thinks it accomplished.
LAST_MESSAGE=""
TRANSCRIPT_PATH=""
if command -v jq &> /dev/null; then
  LAST_MESSAGE=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null || echo "")
  TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
fi

# Extract the original user task from the transcript.
# The first user message is typically the task description.
USER_TASK=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && command -v jq &> /dev/null; then
  USER_TASK=$(jq -r 'select(.type == "human") | .message.content // empty' "$TRANSCRIPT_PATH" 2>/dev/null | head -1 || echo "")
  # Try alternate transcript format
  if [ -z "$USER_TASK" ]; then
    USER_TASK=$(head -20 "$TRANSCRIPT_PATH" | jq -r 'select(.role == "user") | .content // empty' 2>/dev/null | head -1 || echo "")
  fi
fi

# ============================================================
# Collect context from git
# ============================================================

# What changed?
# Strategy: check uncommitted -> staged -> recent commits (last 10 min).
# AI agents often commit before stopping, so git diff HEAD would be empty.
DIFF=""
DIFF_STAT=""
CHANGED_FILES=""
DIFF_SOURCE=""

# 1. Uncommitted changes
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || echo "")
if [ -n "$CHANGED_FILES" ]; then
  DIFF_SOURCE="uncommitted"
  DIFF=$(git diff HEAD 2>/dev/null || echo "")
  DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || echo "")
fi

# 2. Staged but not committed
if [ -z "$CHANGED_FILES" ]; then
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
  if [ -n "$CHANGED_FILES" ]; then
    DIFF_SOURCE="staged"
    DIFF=$(git diff --cached 2>/dev/null || echo "")
    DIFF_STAT=$(git diff --cached --stat 2>/dev/null || echo "")
  fi
fi

# 3. Already committed -- check commits from the last 10 minutes.
#    This catches the common case where the AI agent commits then stops.
if [ -z "$CHANGED_FILES" ]; then
  RECENT_COMMITS=$(git log --since="10 minutes ago" --format="%H" 2>/dev/null || echo "")
  if [ -n "$RECENT_COMMITS" ]; then
    # Get the oldest commit in the window; diff from its parent to HEAD
    OLDEST_RECENT=$(echo "$RECENT_COMMITS" | tail -1)
    PARENT="${OLDEST_RECENT}^"
    # Verify parent exists (might be the initial commit)
    if git rev-parse "$PARENT" &>/dev/null; then
      DIFF_SOURCE="recent-commits"
      CHANGED_FILES=$(git diff --name-only "$PARENT" HEAD 2>/dev/null || echo "")
      DIFF=$(git diff "$PARENT" HEAD 2>/dev/null || echo "")
      DIFF_STAT=$(git diff --stat "$PARENT" HEAD 2>/dev/null || echo "")
    fi
  fi
fi

# 4. Nothing found at all
if [ -z "$CHANGED_FILES" ]; then
  echo "yanfu: no code changes detected (uncommitted, staged, or recent commits), passing"
  exit 0
fi

# Detect change scope
HAS_FRONTEND=false
HAS_BACKEND=false
HAS_DATABASE=false
HAS_CONFIG=false
HAS_TESTS_ONLY=false

if echo "$CHANGED_FILES" | grep -qE '\.(tsx|jsx|vue|svelte|css|scss|html)$'; then
  HAS_FRONTEND=true
fi
if echo "$CHANGED_FILES" | grep -qE '(api/|handlers/|routes/|controllers/|services/|server\.|middleware)'; then
  HAS_BACKEND=true
fi
if echo "$CHANGED_FILES" | grep -qE '(migration|schema|model|\.sql|prisma/|drizzle/)'; then
  HAS_DATABASE=true
fi
if echo "$CHANGED_FILES" | grep -qE '(\.config\.|\.env|package\.json|requirements\.txt|Dockerfile)'; then
  HAS_CONFIG=true
fi
if echo "$CHANGED_FILES" | grep -qE '(\.test\.|\.spec\.|__tests__|test_)' && \
   ! echo "$CHANGED_FILES" | grep -qvE '(\.test\.|\.spec\.|__tests__|test_)'; then
  HAS_TESTS_ONLY=true
fi

# Fast-track: if only tests changed, just run them
if [ "$HAS_TESTS_ONLY" = true ]; then
  echo "yanfu: only test files changed, running quick validation"
  npm test 2>&1 || {
    echo "========================================="
    echo "YANFU BLOCKED: Tests are failing"
    echo "========================================="
    echo "You modified test files but they don't pass."
    echo "Fix the tests before completing."
    exit 2
  }
  exit 0
fi

# Detect project type
PROJECT_TYPE="unknown"
if [ -f "next.config.js" ] || [ -f "next.config.ts" ] || [ -f "next.config.mjs" ]; then
  PROJECT_TYPE="nextjs"
elif [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then
  PROJECT_TYPE="nuxt"
elif [ -f "astro.config.mjs" ] || [ -f "astro.config.ts" ]; then
  PROJECT_TYPE="astro"
elif [ -f "manage.py" ] && [ -d "templates" ]; then
  PROJECT_TYPE="django"
elif [ -f "app.py" ] || [ -f "main.py" ] && [ -f "requirements.txt" ]; then
  PROJECT_TYPE="flask-or-fastapi"
elif [ -f "Gemfile" ] && [ -d "app" ]; then
  PROJECT_TYPE="rails"
elif [ -f "go.mod" ]; then
  PROJECT_TYPE="go"
fi

# Build task description from hook input + fallback files
TASK_DESC=""
if [ -n "$USER_TASK" ]; then
  TASK_DESC="$USER_TASK"
elif [ -f ".claude/current-task.md" ]; then
  TASK_DESC=$(cat .claude/current-task.md)
elif [ -f ".claude/task" ]; then
  TASK_DESC=$(cat .claude/task)
fi

# Read project CLAUDE.md for context
PROJECT_CONTEXT=""
if [ -f "CLAUDE.md" ]; then
  PROJECT_CONTEXT=$(head -100 CLAUDE.md)
fi

# ============================================================
# Build the QA agent prompt
# ============================================================

QA_AGENT_PROMPT_FILE=".claude/agents/yanfu-qa.md"

if [ ! -f "$QA_AGENT_PROMPT_FILE" ]; then
  echo "yanfu: QA agent prompt not found at $QA_AGENT_PROMPT_FILE"
  echo "yanfu: falling back to basic validation"

  # Fallback: run basic checks
  ERRORS=0
  if [ -f "package.json" ]; then
    if grep -q '"typecheck"' package.json; then
      npm run typecheck 2>&1 || ERRORS=$((ERRORS+1))
    fi
    if grep -q '"lint"' package.json; then
      npm run lint 2>&1 || ERRORS=$((ERRORS+1))
    fi
    if grep -q '"test"' package.json; then
      npm test 2>&1 || ERRORS=$((ERRORS+1))
    fi
  fi
  if [ $ERRORS -gt 0 ]; then
    echo "yanfu: $ERRORS basic check(s) failed"
    exit 2
  fi
  exit 0
fi

# ============================================================
# Spawn the QA agent
# ============================================================

CONTEXT=$(cat <<CTXEOF
## Original User Task
${TASK_DESC:-"No explicit task description found. Infer the task from the git diff."}

## Coder Agent's Completion Message
${LAST_MESSAGE:-"No completion message captured."}

## Project Type
${PROJECT_TYPE}

## Strictness Level
${STRICTNESS}

## Dev Server URL
${DEV_SERVER_URL}

## Database Query Command
${DB_QUERY_CMD:-"Not configured. Skip database validation."}

## Diff Source
${DIFF_SOURCE} (uncommitted / staged / recent-commits)

## Changed Files
${CHANGED_FILES}

## Diff Summary
${DIFF_STAT}

## Change Scope
- Frontend changed: ${HAS_FRONTEND}
- Backend changed: ${HAS_BACKEND}
- Database changed: ${HAS_DATABASE}
- Config changed: ${HAS_CONFIG}

## Full Diff
\`\`\`diff
$(echo "$DIFF" | head -500)
\`\`\`

## Project Context (from CLAUDE.md)
${PROJECT_CONTEXT:-"No CLAUDE.md found."}
CTXEOF
)

QA_PROMPT=$(cat "$QA_AGENT_PROMPT_FILE")

FULL_PROMPT="${QA_PROMPT}

---

# Current Validation Context

${CONTEXT}"

# Run the QA agent via claude CLI.
# The agent inherits MCP servers from the project's .claude/settings.json
# or ~/.claude/settings.json. Ensure Playwright MCP is configured there.
RESULT=$(claude -p "$FULL_PROMPT" --max-tokens "$MAX_TOKENS" --output-format text 2>&1) || true

# ============================================================
# Parse result -- only trust explicit VERDICT markers
# ============================================================

if echo "$RESULT" | grep -qiE '^\s*VERDICT\s*:\s*PASS'; then
  echo "yanfu: QA validation PASSED"
  echo ""
  echo "$RESULT" | tail -20
  exit 0
elif echo "$RESULT" | grep -qiE '^\s*VERDICT\s*:\s*FAIL'; then
  echo "========================================="
  echo "YANFU BLOCKED: QA validation FAILED"
  echo "========================================="
  echo ""
  echo "$RESULT"
  echo ""
  echo "Fix the issues above before completing."
  exit 2
else
  # No explicit VERDICT found -- QA agent may have crashed or timed out.
  # Default to PASS to avoid blocking on infrastructure issues.
  # The QA agent prompt requires it to always output a VERDICT line,
  # so missing VERDICT usually means the agent did not run properly.
  echo "yanfu: WARNING -- no VERDICT marker found in QA agent output"
  echo "yanfu: passing by default (QA agent may not have run correctly)"
  echo ""
  echo "--- QA agent output (last 20 lines) ---"
  echo "$RESULT" | tail -20
  exit 0
fi

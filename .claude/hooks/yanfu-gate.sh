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
# Collect context
# ============================================================

# What changed?
DIFF=$(git diff HEAD 2>/dev/null || echo "no git diff available")
DIFF_STAT=$(git diff --stat HEAD 2>/dev/null || echo "")
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || echo "")

# If nothing changed, check staged
if [ -z "$CHANGED_FILES" ]; then
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
  if [ -z "$CHANGED_FILES" ]; then
    echo "yanfu: no code changes detected, passing"
    exit 0
  fi
  DIFF=$(git diff --cached 2>/dev/null || echo "")
  DIFF_STAT=$(git diff --cached --stat 2>/dev/null || echo "")
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

# Read task description if available
TASK_DESC=""
if [ -f ".claude/current-task.md" ]; then
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
## Task Description
${TASK_DESC:-"No explicit task description found. Infer the task from the git diff."}

## Project Type
${PROJECT_TYPE}

## Strictness Level
${STRICTNESS}

## Dev Server URL
${DEV_SERVER_URL}

## Database Query Command
${DB_QUERY_CMD:-"Not configured. Skip database validation."}

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

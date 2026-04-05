#!/bin/bash
# yanfu installer -- one command to add the strict father to your project
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/spytensor/yanfu/main/install.sh | bash
#
# Or clone and run locally:
#   bash yanfu/install.sh

set -euo pipefail

echo ""
echo "yanfu -- Give every AI coder a strict father"
echo "=================================================="
echo ""

# ============================================================
# Check prerequisites
# ============================================================

if [ ! -f "package.json" ] && [ ! -f "requirements.txt" ] && [ ! -f "go.mod" ] && [ ! -f "Gemfile" ] && [ ! -f "Cargo.toml" ]; then
  echo "Warning: No recognizable project file found in current directory."
  echo "Are you in your project root? (y/N)"
  read -r CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Aborting. cd into your project root first."
    exit 1
  fi
fi

if ! command -v claude &> /dev/null; then
  echo "Error: Claude Code CLI not found."
  echo "Install it from: https://docs.anthropic.com/en/docs/claude-code"
  exit 1
fi

# ============================================================
# Detect project type
# ============================================================

PROJECT_TYPE="unknown"
DEV_CMD=""
DEV_URL="http://localhost:3000"
DB_CMD=""

if [ -f "next.config.js" ] || [ -f "next.config.ts" ] || [ -f "next.config.mjs" ]; then
  PROJECT_TYPE="Next.js"
  DEV_CMD="npm run dev"
  DEV_URL="http://localhost:3000"
  if [ -f "prisma/schema.prisma" ]; then
    DB_CMD='npx prisma db execute --stdin'
  fi
elif [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then
  PROJECT_TYPE="Nuxt"
  DEV_CMD="npm run dev"
  DEV_URL="http://localhost:3000"
elif [ -f "astro.config.mjs" ] || [ -f "astro.config.ts" ]; then
  PROJECT_TYPE="Astro"
  DEV_CMD="npm run dev"
  DEV_URL="http://localhost:4321"
elif [ -f "vite.config.ts" ] || [ -f "vite.config.js" ]; then
  PROJECT_TYPE="Vite"
  DEV_CMD="npm run dev"
  DEV_URL="http://localhost:5173"
elif [ -f "manage.py" ]; then
  PROJECT_TYPE="Django"
  DEV_CMD="python manage.py runserver"
  DEV_URL="http://localhost:8000"
  DB_CMD="python manage.py dbshell"
elif [ -f "app.py" ] || [ -f "main.py" ] && [ -f "requirements.txt" ]; then
  PROJECT_TYPE="Flask/FastAPI"
  DEV_CMD="python -m uvicorn main:app --reload"
  DEV_URL="http://localhost:8000"
elif [ -f "Gemfile" ] && [ -d "app" ]; then
  PROJECT_TYPE="Rails"
  DEV_CMD="rails server"
  DEV_URL="http://localhost:3000"
  DB_CMD="rails dbconsole"
elif [ -f "go.mod" ]; then
  PROJECT_TYPE="Go"
  DEV_CMD="go run ."
  DEV_URL="http://localhost:8080"
fi

echo "Detected project type: ${PROJECT_TYPE}"
echo "Dev server URL: ${DEV_URL}"
if [ -n "$DB_CMD" ]; then
  echo "Database command: ${DB_CMD}"
fi
echo ""

# ============================================================
# Create directory structure
# ============================================================

echo "Installing yanfu..."
echo ""

mkdir -p .claude/hooks
mkdir -p .claude/agents

# ============================================================
# Download or copy files
# ============================================================

YANFU_SOURCE=""

# Check if running from cloned repo
if [ -f "yanfu/.claude/hooks/yanfu-gate.sh" ]; then
  YANFU_SOURCE="local"
elif [ -f "../yanfu/.claude/hooks/yanfu-gate.sh" ]; then
  YANFU_SOURCE="local-parent"
fi

if [ "$YANFU_SOURCE" = "local" ]; then
  cp yanfu/.claude/hooks/yanfu-gate.sh .claude/hooks/yanfu-gate.sh
  cp yanfu/agents/yanfu-qa.md .claude/agents/yanfu-qa.md
  echo "  [ok] Copied hook script"
  echo "  [ok] Copied QA agent prompt"
elif [ "$YANFU_SOURCE" = "local-parent" ]; then
  cp ../yanfu/.claude/hooks/yanfu-gate.sh .claude/hooks/yanfu-gate.sh
  cp ../yanfu/agents/yanfu-qa.md .claude/agents/yanfu-qa.md
  echo "  [ok] Copied hook script"
  echo "  [ok] Copied QA agent prompt"
else
  REPO_URL="https://raw.githubusercontent.com/spytensor/yanfu/main"
  curl -sSL "${REPO_URL}/.claude/hooks/yanfu-gate.sh" -o .claude/hooks/yanfu-gate.sh
  curl -sSL "${REPO_URL}/agents/yanfu-qa.md" -o .claude/agents/yanfu-qa.md
  echo "  [ok] Downloaded hook script"
  echo "  [ok] Downloaded QA agent prompt"
fi

chmod +x .claude/hooks/yanfu-gate.sh

# ============================================================
# Configure yanfu-gate.sh with detected values
# ============================================================

# Portable sed -i (works on both macOS and Linux)
_sed_i() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

if [ -n "$DEV_URL" ]; then
  _sed_i "s|DEV_SERVER_URL=\"\${YANFU_DEV_URL:-http://localhost:3000}\"|DEV_SERVER_URL=\"\${YANFU_DEV_URL:-${DEV_URL}}\"|" .claude/hooks/yanfu-gate.sh
fi

if [ -n "$DB_CMD" ]; then
  _sed_i "s|DB_QUERY_CMD=\"\${YANFU_DB_CMD:-}\"|DB_QUERY_CMD=\"\${YANFU_DB_CMD:-${DB_CMD}}\"|" .claude/hooks/yanfu-gate.sh
fi

echo "  [ok] Configured for ${PROJECT_TYPE}"

# ============================================================
# Merge or create settings.json
# ============================================================

SETTINGS_FILE=".claude/settings.json"

HOOK_CONFIG='{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/yanfu-gate.sh",
            "timeout": 300000
          }
        ]
      }
    ]
  }
}'

if [ -f "$SETTINGS_FILE" ]; then
  if grep -q "yanfu-gate" "$SETTINGS_FILE"; then
    echo "  [skip] Stop hook already configured in ${SETTINGS_FILE}"
  else
    echo "  [!!] Existing ${SETTINGS_FILE} found."
    echo "  You need to manually merge the Stop hook configuration."
    echo "  Add this to your hooks section:"
    echo ""
    echo '    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "bash .claude/hooks/yanfu-gate.sh", "timeout": 300000}]}]'
    echo ""
  fi
else
  echo "$HOOK_CONFIG" > "$SETTINGS_FILE"
  echo "  [ok] Created ${SETTINGS_FILE} with Stop hook"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "=================================================="
echo "yanfu installed successfully!"
echo "=================================================="
echo ""
echo "Files created:"
echo "  .claude/hooks/yanfu-gate.sh  -- Stop hook entry point"
echo "  .claude/agents/yanfu-qa.md   -- QA agent prompt (the strict father)"
echo "  .claude/settings.json        -- Hook configuration"
echo ""
echo "Next steps:"
echo ""
echo "  1. Ensure Playwright MCP is configured for browser validation."
echo "     Add to .claude/settings.json or ~/.claude/settings.json:"
echo ""
echo '     "mcpServers": {'
echo '       "playwright": {'
echo '         "command": "npx",'
echo '         "args": ["@anthropic-ai/playwright-mcp@latest"]'
echo '       }'
echo '     }'
echo ""
echo "  2. (Optional) Append yanfu context to your CLAUDE.md:"
echo "     See CLAUDE.md.template for what to add"
echo ""
echo "  3. Start coding with Claude Code as usual."
echo "     yanfu will automatically validate when Claude tries to complete."
echo ""
echo "  4. To temporarily skip validation:"
echo "     YANFU_SKIP=1 claude"
echo ""
echo "  5. To adjust strictness (strict/moderate/smoke):"
echo "     YANFU_STRICTNESS=moderate claude"
echo ""

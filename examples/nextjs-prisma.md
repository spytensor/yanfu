# yanfu Example: Next.js + Prisma

## Setup

### .claude/hooks/yanfu-gate.sh overrides

```bash
DEV_SERVER_URL="http://localhost:3000"
DB_QUERY_CMD="npx prisma db execute --stdin"
```

### Prerequisites

```bash
# Ensure Playwright MCP is configured in your Claude Code settings
# In .claude/settings.json or ~/.claude/settings.json:
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@anthropic-ai/playwright-mcp@latest"]
    }
  }
}
```

### CLAUDE.md additions

```markdown
## Dev Environment
- Start dev server: `npm run dev` (http://localhost:3000)
- Database: PostgreSQL via Prisma ORM
- Migrations: `npx prisma migrate dev`
- DB browser: `npx prisma studio` (http://localhost:5555)
- Query DB directly: `npx prisma db execute --stdin <<< "SELECT * FROM users LIMIT 5;"`
```

## What yanfu validates for this stack

### Frontend change (e.g., new form field)
```
Layer 0: npm run typecheck && npm run lint && npm test
Layer 1: Playwright -> open http://localhost:3000/affected-page -> screenshot
Layer 2: Playwright -> fill form -> submit -> verify success state
```

### API route change (e.g., new endpoint)
```
Layer 0: npm run typecheck && npm run lint && npm test
Layer 3: curl -X POST http://localhost:3000/api/users -d '{"name":"test"}' -> check 201
         curl http://localhost:3000/api/users/1 -> check response has new field
```

### Prisma migration (e.g., new column)
```
Layer 0: npm run typecheck && npx prisma validate
Layer 3: curl the affected API endpoint -> verify new field in response
Layer 4: npx prisma db execute --stdin <<< "SELECT column_name FROM information_schema.columns WHERE table_name='users';" -> verify column exists
```

### Full-stack feature (e.g., "add phone number field, save to DB")
```
Layer 0: typecheck + lint + unit tests
Layer 1: Playwright -> open /profile -> verify phone input renders
Layer 2: Playwright -> fill "13800138000" -> submit -> verify success
Layer 3: curl GET /api/users/me -> verify phone_number in response body
Layer 4: SELECT phone_number FROM users WHERE id=1; -> verify "13800138000"
Layer 1: Playwright -> refresh page -> verify phone_number shows "13800138000"
```

## Example validation session

```
yanfu QA Agent starting validation...

Task: Add phone_number field to user profile
Stack: Next.js + Prisma (PostgreSQL)
Changed: src/app/profile/page.tsx, src/app/api/users/route.ts, prisma/schema.prisma, prisma/migrations/...

=== Layer 0: Build & Types ===
[PASS] npm run typecheck -- 0 errors
[PASS] npm run lint -- 0 warnings
[PASS] npm test -- 12/12 tests passed

=== Layer 1: Visual Rendering ===
[PASS] Navigated to http://localhost:3000/profile
[PASS] Phone number input field is visible
[PASS] No console errors
[EVIDENCE] Screenshot saved

=== Layer 2: User Interaction ===
[PASS] Filled phone_number with "13800138000"
[PASS] Clicked Save button
[PASS] Success toast appeared: "Profile updated"
[FAIL] Error state test: entered "abc" but no validation error shown
  Expected: Validation error message for invalid phone format
  Actual: Form submitted successfully with "abc"

=== VERDICT: FAIL ===

Failed validations:
1. [Layer 2] Phone number validation missing
   - Expected: Invalid input "abc" should show validation error
   - Actual: Form accepts any string without validation
   - How to fix: Add phone number format validation in the form
     component and/or the API handler
```

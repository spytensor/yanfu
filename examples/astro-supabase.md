# yanfu Example: Astro + Supabase

## Setup

### .claude/hooks/yanfu-gate.sh overrides

```bash
DEV_SERVER_URL="http://localhost:4321"
DB_QUERY_CMD="npx supabase db execute"
# Or for direct PostgreSQL:
# DB_QUERY_CMD="psql $DATABASE_URL -c"
```

### CLAUDE.md additions

```markdown
## Dev Environment
- Start dev server: `npm run dev` (http://localhost:4321)
- Supabase local: `npx supabase start` (dashboard at http://localhost:54323)
- Database: PostgreSQL via Supabase
- Migrations: `npx supabase migration new <name>` then `npx supabase db push`
- Query DB: `npx supabase db execute "SELECT * FROM table LIMIT 5"`
- Run tests: `npm test`
- E2E tests: `npx playwright test`
```

## What yanfu validates

### Static page change
```
Layer 0: npm run build (Astro builds must succeed)
Layer 1: Playwright -> navigate to page -> verify content renders
         Playwright -> check no console errors
         Playwright -> screenshot
```

### Interactive island change
```
Layer 0: npm run build + npm test
Layer 1: Playwright -> navigate -> verify island renders
Layer 2: Playwright -> interact with island (click, type, etc.)
         Playwright -> verify client-side state updates
         Playwright -> verify no hydration errors in console
```

### Supabase integration change (e.g., new table, new query)
```
Layer 0: npm run build + npm test
Layer 3: curl Supabase REST API:
         curl "$SUPABASE_URL/rest/v1/tablename" -H "apikey: $SUPABASE_ANON_KEY"
         -> verify response
Layer 4: npx supabase db execute "SELECT * FROM tablename LIMIT 1"
         -> verify data structure
```

### Full feature (e.g., "add comment form that saves to Supabase")
```
Layer 0: build + typecheck + tests
Layer 1: Playwright -> open /blog/post-slug -> verify comment form renders
Layer 2: Playwright -> fill name + comment -> submit
         Playwright -> verify success message
         Playwright -> verify new comment appears in list
Layer 3: curl "$SUPABASE_URL/rest/v1/comments?post_slug=eq.post-slug" -> verify comment in API
Layer 4: npx supabase db execute "SELECT * FROM comments ORDER BY created_at DESC LIMIT 1"
         -> verify comment row with correct data
Layer 1: Playwright -> refresh page -> verify comment persists after reload
```

### Auth flow change
```
Layer 0: build + tests
Layer 2: Playwright -> navigate to login page
         Playwright -> fill credentials -> submit
         Playwright -> verify redirect to dashboard
         Playwright -> verify auth state (user menu shows name)
         Playwright -> navigate to protected route -> verify access
         Playwright -> sign out -> verify redirect to login
         Playwright -> navigate to protected route -> verify redirect to login
```

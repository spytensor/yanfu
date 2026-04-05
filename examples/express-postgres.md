# yanfu Example: Express + PostgreSQL

## Setup

### .claude/hooks/yanfu-gate.sh overrides

```bash
DEV_SERVER_URL="http://localhost:4000"
DB_QUERY_CMD="psql -U postgres -d myapp -c"
```

### CLAUDE.md additions

```markdown
## Dev Environment
- Start server: `npm run dev` (http://localhost:4000)
- Database: PostgreSQL 16
- Migrations: `npm run migrate`
- Query DB: `psql -U postgres -d myapp -c "YOUR SQL HERE"`
- Run tests: `npm test`
- Run integration tests: `npm run test:integration`
```

## What yanfu validates

### New API endpoint
```
Layer 0: npm run typecheck && npm run lint && npm test
Layer 3: curl -v POST /api/resource -d '{"field":"value"}' -> check 201 + response body
         curl -v POST /api/resource -d '{}' -> check 400 + error message
         curl -v GET /api/resource/1 -> check 200 + correct data
         curl -v GET /api/resource/999 -> check 404
```

### Database migration
```
Layer 0: typecheck + lint + tests
Layer 3: Hit affected endpoints -> verify they still work
Layer 4: psql -c "\d tablename" -> verify column exists with correct type
         psql -c "SELECT count(*) FROM tablename" -> verify no data loss
```

### Auth/middleware change
```
Layer 0: typecheck + lint + tests
Layer 3: curl without auth -> verify 401
         curl with valid token -> verify 200
         curl with expired token -> verify 401
         curl with wrong role -> verify 403
```

### Full-stack API feature
```
Layer 0: typecheck + lint + unit tests + integration tests
Layer 3: Full CRUD cycle:
         POST /api/items -d '{"name":"test"}' -> 201, get id
         GET /api/items/{id} -> 200, verify fields
         PUT /api/items/{id} -d '{"name":"updated"}' -> 200
         GET /api/items/{id} -> verify "updated"
         DELETE /api/items/{id} -> 204
         GET /api/items/{id} -> 404
Layer 4: After POST: SELECT * FROM items WHERE name='test' -> verify row
         After DELETE: SELECT * FROM items WHERE id={id} -> verify empty
```

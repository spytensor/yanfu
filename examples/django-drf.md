# yanfu Example: Django + Django REST Framework

## Setup

### .claude/hooks/yanfu-gate.sh overrides

```bash
DEV_SERVER_URL="http://localhost:8000"
DB_QUERY_CMD="python manage.py dbshell"
```

### CLAUDE.md additions

```markdown
## Dev Environment
- Start server: `python manage.py runserver` (http://localhost:8000)
- Database: PostgreSQL via Django ORM
- Migrations: `python manage.py makemigrations && python manage.py migrate`
- DB shell: `python manage.py dbshell`
- Django shell: `python manage.py shell`
- Run tests: `python manage.py test`
- Admin: http://localhost:8000/admin/ (create superuser with `python manage.py createsuperuser`)
```

## What yanfu validates

### New model + API endpoint
```
Layer 0: python manage.py test
Layer 3: curl POST /api/items/ -d '{"name":"test"}' -> 201
         curl GET /api/items/ -> 200, verify list contains item
         curl GET /api/items/1/ -> 200, verify fields
Layer 4: python manage.py shell -c "from myapp.models import Item; print(Item.objects.count())"
         -> verify count increased
```

### Model migration
```
Layer 0: python manage.py test
Layer 3: curl affected endpoints -> verify backward compatibility
Layer 4: python manage.py dbshell -c "\d myapp_modelname" -> verify new column
         python manage.py shell -c "from myapp.models import Model; print(Model._meta.get_fields())"
```

### Template/view change
```
Layer 0: python manage.py test
Layer 1: Playwright -> navigate to affected URL -> screenshot
Layer 2: Playwright -> interact with forms/buttons -> verify behavior
Layer 3: If view returns JSON: curl -> verify response shape
```

### Serializer change
```
Layer 0: python manage.py test
Layer 3: curl GET endpoint -> verify new/modified fields in response
         curl POST endpoint with new fields -> verify acceptance
         curl POST endpoint with invalid data -> verify 400 + error details
```

### Permission/auth change
```
Layer 0: python manage.py test
Layer 3: curl without auth -> 401
         curl with token (no permission) -> 403
         curl with token (has permission) -> 200
         curl admin endpoint with non-staff -> 403
```

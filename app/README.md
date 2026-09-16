# `app/` — Laravel web application

**Spec sections:** A (hosting), D (APIs), E (MapLibre shell)

Laravel **13** application for the public map shell and JSON APIs.

## Purpose

- Public HTML shell hosting **MapLibre GL JS** (Section E)
- JSON APIs: parcel drawer, comps, map config (Section D)
- Health: `GET /api/health` (database + map config smoke test)
- No owner names on public responses; TAD license footer content

## Local development

From the **repository root** (preferred same-origin stack):

```bash
# one-time
cp .env.example .env          # stack env
# ensure app/.env exists (composer scaffold already created it)
infra/scripts/bootstrap-db.sh # needs postgres superuser once
infra/scripts/install-martin.sh

infra/scripts/dev-up.sh
# open http://127.0.0.1:8080/
# health http://127.0.0.1:8080/api/health
# tiles  http://127.0.0.1:8080/tiles/catalog

infra/scripts/dev-down.sh
```

Laravel-only (no proxy):

```bash
cd app && php artisan serve --host=127.0.0.1 --port=8000
```

## Configuration

| File | Role |
|------|------|
| `.env` | DB + `MAP_*` knobs |
| `config/map.php` | Map product settings |
| `routes/api.php` | `/api/*` |
| `routes/web.php` | UI routes |

See repository root `README.md` for ports and path conventions.

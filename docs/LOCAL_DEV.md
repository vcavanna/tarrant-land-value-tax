# Local development runbook

End-to-end guide for running **tad-analysis** on a developer machine.

**If you just want it running, use `./start-local.sh` and the quickstart in the repository root
[README.md](../README.md).** This document is the detailed reference behind it: what each step
does, every port and env var, and the troubleshooting table. For *why* the constants are what
they are, see [FIELD_NOTES.md](FIELD_NOTES.md).

Native host stack is the default (PostgreSQL/PostGIS, PHP, Node, Python). **Docker is optional.**

---

## Architecture (local)

```text
Browser → :8080 dev-proxy
            ├─ /  and /api/*  → Laravel :8000
            └─ /tiles/*       → Martin :3000  → PostGIS :5432

ETL (host):  File GDB  →  etl/.venv (pyogrio)  →  PostGIS
             (optional) ogrinfo/ogr2ogr from gdal-bin
```

---

## Ports

| Service | Bind | Notes |
|---------|------|--------|
| Same-origin proxy | **8080** | Preferred entry (`infra/scripts/dev-proxy.mjs`) |
| Laravel | 8000 | `php artisan serve` |
| Martin | 3000 | MVT + `/catalog` |
| PostgreSQL | 5432 | Cluster with PostGIS |

---

## Environment files

| File | Purpose |
|------|---------|
| `.env` (repo root) | Sourced by `dev-up.sh` / ETL scripts (DB URL, ports) |
| `app/.env` | Laravel + `MAP_*` knobs |

```bash
cp .env.example .env
# Keep app/.env DB_* in sync with root .env
```

### Database (local defaults)

| Key | Value |
|-----|--------|
| Host | `127.0.0.1` |
| Port | `5432` |
| Database | `tad_analysis` |
| User / password | `tad` / `tad` |
| URL | `postgresql://tad:tad@127.0.0.1:5432/tad_analysis` |

### Map knobs (`MAP_*` → `app/config/map.php`)

| Variable | Default | Meaning |
|----------|---------|---------|
| `MAP_HEIGHT_K` | `1` | Extrusion scale |
| `MAP_VPA_CAP` | `5000` | Cap; over-cap styled black |
| `MAP_PARCEL_MINZOOM` | `12` | Hide parcels below this zoom |
| `MAP_DEFAULT_METRIC` | `land` | land \| total \| appraised |
| `MAP_DEFAULT_MODE` | `color` | color \| 3d |
| `MAP_TILES_URL` | `/tiles` | Same-origin tile base |
| `MAP_OPENFREEMAP_STYLE` | OpenFreeMap Liberty URL | Basemap |
| `MAP_COLOR_MIN` / `MAX` | empty until ETL stats | Countywide domain |

Quote values with spaces or parentheses in root `.env` (e.g. `MAP_LICENSE_FOOTER='...'`).

---

## One-time setup

### 1. PostgreSQL role, database, PostGIS

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -f infra/scripts/bootstrap-db.sql
# helper: infra/scripts/bootstrap-db.sh

PGPASSWORD=tad psql -h 127.0.0.1 -U tad -d tad_analysis \
  -c 'SELECT postgis_full_version();'
```

### 2. Martin binary

```bash
infra/scripts/install-martin.sh   # → infra/bin/martin
```

### 3. Laravel

```bash
cd app
composer install
# if needed: cp .env.example .env && php artisan key:generate
cd ..
```

PHP extensions: `pdo_pgsql` (required), `pgsql`.

### 4. ETL tooling (Section A.3)

**Purpose:** open the TAD Esri **File Geodatabase** and prove load into PostGIS before Section B.

| Tooling | Role |
|---------|------|
| **Python venv** (`etl/.venv`) | `pyogrio` + `geopandas` read GDB; write sample GeoPackage / PostGIS |
| **gdal-bin** (recommended) | System `ogrinfo` / `ogr2ogr` for bulk CLI loads in Section B |

```bash
# Install venv deps + run smoke tests
etl/scripts/setup-tools.sh

# Smoke only (after setup)
etl/scripts/smoke-etl-tools.sh
etl/scripts/smoke-etl-tools.sh --cleanup   # drop etl_smoke_parcels
```

System GDAL CLI (Ubuntu/Debian):

```bash
sudo apt-get update
sudo apt-get install -y gdal-bin
ogrinfo --version
ogrinfo --formats | grep -i OpenFileGDB
```

#### Source package

```text
data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb
```

Smoke test expects layers including **`TADParcels`** and **`PropertyData`**, CRS **EPSG:2276** on parcel geometry, then reprojects a 5-feature sample to **EPSG:4326** for PostGIS.

#### What the smoke test does

1. Lists GDB layers (Python; and `ogrinfo` if installed).  
2. Reads 5 features from `TADParcels`.  
3. Writes `data/processed/smoke_tadparcels_sample.gpkg`.  
4. Writes/replaces PostGIS table **`etl_smoke_parcels`** (SRID 4326).  
5. Prints `SMOKE OK`.

This is **not** the production parcel ETL (no account join, no VPA columns)—only tooling verification.

#### Activate Python env for ad-hoc work

```bash
source etl/.venv/bin/activate
python -c "import pyogrio; print(pyogrio.__gdal_version__)"
```

---

## Daily start / stop

```bash
infra/scripts/dev-up.sh
infra/scripts/dev-down.sh
```

Smoke checks:

```bash
curl -sS http://127.0.0.1:8080/api/health | jq .
curl -sS http://127.0.0.1:8080/tiles/catalog | jq .
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
```

Logs: `.run/logs/{martin,laravel,proxy}.log`.

---

## Optional: system nginx

`infra/nginx/local.conf` — same routing as the Node proxy on :8080. Use if you prefer nginx (needs permission to enable a site).

## Optional: Docker Compose

```bash
docker compose -f infra/docker/docker-compose.yml up -d
cd app && php artisan serve --host=127.0.0.1 --port=8000
```

See `infra/docker/docker-compose.yml`. Host-native path remains the documented default.

---

## Troubleshooting

| Symptom | Likely fix |
|---------|------------|
| `password authentication failed for user "tad"` | Run `bootstrap-db.sql` as superuser |
| `role "vincentcavanna" does not exist` | Use `-h 127.0.0.1 -U tad` (TCP + password), not peer socket as OS user |
| Martin exits immediately | DB not bootstrapped; check `.run/logs/martin.log` |
| `/api/health` `"ok": false` | Same as DB; check `app/.env` `DB_*` |
| `source .env` syntax error | Quote values with `()` / spaces |
| `Missing File GDB` | Place package under `data/raw/2025ESRI_Parcels/` |
| `ogrinfo not found` | `sudo apt install gdal-bin` (Python smoke still works) |
| pyogrio import errors | Re-run `etl/scripts/setup-tools.sh` |
| Port 8080 in use | `PROXY_PORT=8081 infra/scripts/dev-up.sh` or free the port |
| Map renders blank, no console error | **Focus the browser tab.** MapLibre renders in `requestAnimationFrame`, which Chrome throttles in unfocused tabs; the map loads but never paints or requests tiles |
| Map blank *and* `#map` has height 0 | MapLibre's unlayered CSS beating Tailwind's layered utilities — check `@layer maplibre` in `resources/css/app.css` |
| Map blank and `maplibre-gl-worker.mjs` 404s | The Vite plugin in `vite.config.js` must emit it; re-check after any bundler upgrade |
| Page slow to load assets | `dev-up.sh` sets `PHP_CLI_SERVER_WORKERS=8`; PHP's built-in server is single-worker otherwise |
| Stale JS after editing `resources/js` | `cd app && npm run build`, then hard-reload (Chrome caches the HTML) |

---

## What is installed vs still future work

| Present after A.1–A.3 | Not yet (later sections) |
|----------------------|---------------------------|
| Empty PostGIS + PostGIS extension | Full parcel ETL, VPA columns (B) |
| Martin binary + empty catalog | Dynamic parcel MVT layer (C) |
| Laravel + `/api/health` | Drawer / comps APIs (D) |
| Same-origin proxy | MapLibre UI (E) |
| ETL venv + GDB smoke | Production load scripts |

---

## Script index

| Script | Role |
|--------|------|
| `start-local.sh` | One-shot setup + run (`--check` reports readiness, `--no-start` sets up only) |
| `infra/scripts/bootstrap-db.sh` / `.sql` | Create `tad` / `tad_analysis` + PostGIS |
| `infra/scripts/install-martin.sh` | Download Martin |
| `infra/scripts/dev-up.sh` / `dev-down.sh` | Start/stop stack |
| `infra/scripts/dev-proxy.mjs` | Same-origin reverse proxy |
| `etl/scripts/setup-tools.sh` | Create venv, install requirements, smoke |
| `etl/scripts/smoke-etl-tools.sh` | GDB → GPKG + PostGIS sample |
| `etl/scripts/profile-source.py` | B.1 source profiling → `data/processed/source_profile.json` |
| `etl/scripts/load-parcels.sh` | Full parcel load: GDB → staging → `parcels` (~1 min) |
| `etl/sql/05_tiles.sql` | Martin tile source `parcels_mvt(z,x,y)` (Section C) |

### Frontend assets

`app/` uses Vite. `app/public/build` is gitignored, so after cloning:

```bash
cd app && npm ci && npm run build      # once, and after editing resources/js|css
cd app && npm run dev                 # optional: hot reload while developing
```

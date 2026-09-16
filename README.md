# tad-analysis

Interactive map of every parcel in **Tarrant County, Texas**, coloured by **value per acre**.

The argument: a small downtown lot can out-earn a large suburban one by orders of magnitude, and
you should be able to see that. 690,000 parcels, appraised land / total / improvement value,
2D colour and 3D extrusion, click any parcel for detail and comparable land.

Public map · no Mapbox account required for basemap or tiles · data from the Tarrant Appraisal
District, informational use only.

```text
GDB → ETL → PostGIS ──► Martin ──► MapLibre   (paint every parcel)
                    └──► Laravel ──► drawer   (explain one parcel)
Basemap: OpenFreeMap
```

| Doc | What it covers |
|-----|----------------|
| **[docs/FIELD_NOTES.md](docs/FIELD_NOTES.md)** | **Start here if you are new.** What was hard, what the data actually is, and why the constants are what they are |
| [docs/LOCAL_DEV.md](docs/LOCAL_DEV.md) | Detailed runbook: ports, env vars, troubleshooting |
| [docs/VALUE_PER_ACRE_SPEC.md](docs/VALUE_PER_ACRE_SPEC.md) | Implementation spec and per-section completion notes |
| [docs/VALUE_PER_ACRE_WEBAPP.md](docs/VALUE_PER_ACRE_WEBAPP.md) | Source geodatabase data model and join rules |

---

## Run it locally

### The short version

```bash
git clone <this repo> && cd tad-analysis
./start-local.sh
```

`start-local.sh` checks prerequisites, creates env files, downloads the tile server, installs
PHP and Node dependencies, builds the frontend, starts everything, and smoke-tests it. It is
idempotent — re-running only does what is missing.

Then open **<http://127.0.0.1:8080/>**.

Two things that look like bugs and are not:

- **Focus the browser tab.** MapLibre renders inside `requestAnimationFrame`, which Chrome
  throttles in background tabs. In an unfocused tab the map loads and then paints nothing.
- **Parcels appear at zoom 13 and closer.** Below that you get basemap only, by design — a
  zoom-12 tile would hold 30,000 parcels.

Stop with `infra/scripts/dev-down.sh`. Logs are in `.run/logs/`.

### Prerequisites

`start-local.sh --check` reports all of these without changing anything.

| Tool | Why | Debian / Ubuntu |
|------|-----|-----------------|
| **PHP 8.3+** with `pdo_pgsql` | Laravel app | `sudo apt install php-cli php-pgsql` |
| **Composer** | PHP dependencies | <https://getcomposer.org/download/> |
| **Node 20+** and npm | Frontend build, dev proxy | `sudo apt install nodejs npm` |
| **PostgreSQL 16+** with **PostGIS** | Spatial database | `sudo apt install postgresql postgresql-postgis` |
| **Python 3.11+** with `venv` | ETL tooling | `sudo apt install python3 python3-venv` |
| **gdal-bin** | `ogr2ogr`, to load the data | `sudo apt install gdal-bin` |

### The one manual step: the database role

Creating a Postgres role and database needs a superuser, so the script will not do it for you:

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -f infra/scripts/bootstrap-db.sql
```

That creates role `tad`, database `tad_analysis`, and enables PostGIS. Local dev credentials are
`tad` / `tad` on `127.0.0.1:5432`. Re-run `./start-local.sh` afterwards.

### Loading the parcel data

The county's parcel geodatabase is **596 MB** and is not in this repository. Without it the stack
still runs — you get a basemap with no parcels.

1. Obtain the 2025 ESRI parcel package from the
   [Tarrant Appraisal District](https://www.tad.org/) and extract it so that this path exists:

   ```text
   data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb
   ```

2. Create the Python environment and load:

   ```bash
   etl/scripts/setup-tools.sh      # once — creates etl/.venv
   etl/scripts/load-parcels.sh     # about one minute for the full county
   ```

The loader wipes and rebuilds from source every time; there is no incremental path. It finishes
by running 17 validation checks against the figures recorded in the spec, and prints the colour
domain to paste into `app/.env` if you change the data.

Useful flags: `--skip-extract` re-runs only the SQL, `--limit 5000` loads a subset for iterating.

### What you should see

| URL | What |
|-----|------|
| **<http://127.0.0.1:8080/>** | **The map** |
| <http://127.0.0.1:8080/parcels/27825---04> | Deep link — opens with one parcel selected |
| <http://127.0.0.1:8080/api/health> | Database and config health |
| <http://127.0.0.1:8080/api/map-config> | Caps, `k`, colour domain served to the frontend |
| <http://127.0.0.1:8080/api/parcels/id/43407> | Raw drawer JSON for one parcel |
| <http://127.0.0.1:8080/tiles/parcels> | Tile metadata (TileJSON) |
| <http://127.0.0.1:8080/tiles/> | Martin's tile inspector (local only) |

### Working on it

```bash
cd app && npm run build     # after editing resources/js or resources/css
cd app && npm run dev       # or run Vite with hot reload alongside the stack
cd app && php artisan test  # 43 tests; they skip cleanly without a database
```

Built assets are gitignored, so a fresh clone always builds once. Chrome caches the page HTML —
hard-reload (Ctrl+Shift+R) after a rebuild if you get a stale bundle.

If something looks wrong, `docs/LOCAL_DEV.md` has a troubleshooting table covering the blank-map
causes, stale assets, and port conflicts.

---

## Ports

| Port | Service |
|------|---------|
| **8080** | Same-origin proxy — `/` and `/api` → Laravel, `/tiles` → Martin |
| 8000 | Laravel (`php artisan serve`) |
| 3000 | Martin tile server |
| 5432 | PostgreSQL |

Everything goes through 8080 so there is no CORS, matching the production shape.

---

## Repository layout

```text
tad-analysis/
├── start-local.sh            # one-shot setup + run
├── docs/                     # field notes, runbook, spec, data guide
├── app/                      # Laravel 13 — API, Blade shell, MapLibre frontend
│   ├── app/Actions/          # comparable-parcel selection
│   ├── app/Http/             # drawer + map-config controllers, API resources
│   ├── resources/js/map.js   # the map
│   └── tests/Feature/        # 43 integration tests against the loaded database
├── etl/
│   ├── sql/                  # 01_schema → 02_transform → 03_indexes → 04_stats
│   │                         #   → 05_tiles → 99_validate
│   └── scripts/              # profile-source.py, load-parcels.sh, setup-tools.sh
├── infra/
│   ├── scripts/              # bootstrap-db, install-martin, dev-up/down, dev-proxy
│   ├── martin/config.yaml    # tile source definition
│   └── docker/               # optional Compose stack
└── data/raw/2025ESRI_Parcels/  # source geodatabase (not in git)
```

---

## How it fits together

**PostGIS** is the source of truth: one row per parcel, with acres and all three value-per-acre
figures precomputed by the ETL. A `map_eligible` flag encodes which parcels reach the map.

**Martin** serves vector tiles from a SQL function, so tiles follow the database with no rebuild
step. Tiles are deliberately lean — an id and three numbers per parcel — because properties, not
geometry, dominate tile size.

**Laravel** answers the questions tiles cannot: the selection drawer, comparable parcels, and the
deploy constants the frontend would otherwise hard-code.

**MapLibre** draws parcels over an OpenFreeMap basemap. Switching metric is a paint change only —
all three values are already in the tile.

Why those choices, and the measurements behind every constant, are in
[docs/FIELD_NOTES.md](docs/FIELD_NOTES.md).

---

## Status

Sections A–E of the spec are complete: local stack, data model and ETL, tiles, APIs, and
frontend. **Section F (production deploy on a GCE VM with CDN) has not been started.**

Two product decisions are open and documented in the spec: the colour ramp saturates downtown
(a log scale is the likely fix), and zoom 12 is unreachable without dropping most parcels.

## Licence and data

Parcel and appraisal data come from the **Tarrant Appraisal District**. Informational use only;
not for legal, engineering, or surveying purposes. No owner names appear anywhere in the curated
data, the API, or the map.

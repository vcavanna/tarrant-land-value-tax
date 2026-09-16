#!/usr/bin/env bash
# One-shot local setup and run.
#
# Idempotent: every step checks whether it has already been done, so re-running
# is cheap. Takes a fresh clone to a map in the browser.
#
#   ./start-local.sh              # set up anything missing, then start
#   ./start-local.sh --check      # report readiness and exit, change nothing
#   ./start-local.sh --no-start   # set up only
#
# Data loading is NOT automatic: it needs the county's 596 MB geodatabase, which
# is not in this repo. The script tells you what to run once it is in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

CHECK_ONLY=0
NO_START=0
for arg in "$@"; do
  case "${arg}" in
    --check) CHECK_ONLY=1 ;;
    --no-start) NO_START=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

MISSING=0

# ---------------------------------------------------------------------------
step "1. Prerequisites"
# ---------------------------------------------------------------------------
require() {  # require <command> <why> <install hint>
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 — $2"
  else
    fail "$1 missing — $2   (install: $3)"
    MISSING=1
  fi
}

require php      "Laravel app"            "sudo apt install php-cli php-pgsql"
require composer "PHP dependencies"       "https://getcomposer.org/download/"
require node     "asset build + proxy"    "sudo apt install nodejs npm  (Node 20+)"
require npm      "asset build"            "comes with nodejs"
require python3  "ETL tooling"            "sudo apt install python3 python3-venv"
require psql     "database client"        "sudo apt install postgresql-client"

if php -m 2>/dev/null | grep -qi pdo_pgsql; then
  ok "php pdo_pgsql extension"
else
  fail "php pdo_pgsql missing — Laravel cannot reach Postgres   (install: sudo apt install php-pgsql)"
  MISSING=1
fi

if command -v ogr2ogr >/dev/null 2>&1; then
  ok "ogr2ogr — bulk data load"
else
  warn "ogr2ogr missing — only needed to load parcel data   (install: sudo apt install gdal-bin)"
fi

if [[ "${MISSING}" -eq 1 ]]; then
  echo
  echo "Install the missing prerequisites above, then re-run." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
step "2. Environment files"
# ---------------------------------------------------------------------------
if [[ -f .env ]]; then
  ok "root .env"
elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
  warn "root .env missing"
else
  cp .env.example .env && ok "root .env created from .env.example"
fi

if [[ -f app/.env ]]; then
  ok "app/.env"
elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
  warn "app/.env missing"
else
  cp app/.env.example app/.env && ok "app/.env created from app/.env.example"
fi

# ---------------------------------------------------------------------------
step "3. Database"
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
[[ -f .env ]] && set -a && source .env && set +a || true
DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-5432}"
DB_DATABASE="${DB_DATABASE:-tad_analysis}"
DB_USERNAME="${DB_USERNAME:-tad}"; DB_PASSWORD="${DB_PASSWORD:-tad}"
export PGPASSWORD="${DB_PASSWORD}"

psql_q() { psql -At -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USERNAME}" -d "${DB_DATABASE}" -c "$1" 2>/dev/null; }

if ! pg_isready -h "${DB_HOST}" -p "${DB_PORT}" >/dev/null 2>&1; then
  fail "PostgreSQL is not accepting connections on ${DB_HOST}:${DB_PORT}"
  echo "      start it (e.g. sudo systemctl start postgresql), then re-run." >&2
  exit 1
fi
ok "PostgreSQL reachable"

if [[ "$(psql_q 'select 1')" == "1" ]]; then
  ok "database '${DB_DATABASE}' and role '${DB_USERNAME}' exist"
else
  fail "cannot connect as '${DB_USERNAME}' to '${DB_DATABASE}'"
  echo "      This one step needs a Postgres superuser, so it is not automated:" >&2
  echo "        sudo -u postgres psql -v ON_ERROR_STOP=1 -f infra/scripts/bootstrap-db.sql" >&2
  exit 1
fi

if [[ -n "$(psql_q 'select 1 from pg_extension where extname=$$postgis$$')" ]]; then
  ok "PostGIS installed ($(psql_q 'select postgis_version()'))"
else
  fail "PostGIS extension not present — re-run infra/scripts/bootstrap-db.sql"
  exit 1
fi

PARCELS="$(psql_q 'select count(*) from parcels' || true)"
if [[ -n "${PARCELS}" && "${PARCELS}" != "0" ]]; then
  ELIGIBLE="$(psql_q 'select count(*) from parcels_map')"
  ok "parcel data loaded — ${PARCELS} parcels, ${ELIGIBLE} on the map"
  DATA_READY=1
else
  warn "no parcel data yet — the map will render a basemap with no parcels"
  DATA_READY=0
fi

# ---------------------------------------------------------------------------
step "4. Martin tile server binary"
# ---------------------------------------------------------------------------
if [[ -x infra/bin/martin ]]; then
  ok "infra/bin/martin"
elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
  warn "infra/bin/martin missing"
else
  infra/scripts/install-martin.sh >/dev/null && ok "martin downloaded to infra/bin/"
fi

# ---------------------------------------------------------------------------
step "5. PHP dependencies"
# ---------------------------------------------------------------------------
if [[ -d app/vendor ]]; then
  ok "app/vendor"
elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
  warn "app/vendor missing (composer install)"
else
  ( cd app && composer install --no-interaction --quiet ) && ok "composer install"
fi

if grep -q '^APP_KEY=base64:' app/.env 2>/dev/null; then
  ok "APP_KEY set"
elif [[ "${CHECK_ONLY}" -eq 0 ]]; then
  ( cd app && php artisan key:generate --quiet ) && ok "APP_KEY generated"
fi

# ---------------------------------------------------------------------------
step "6. Frontend assets"
# ---------------------------------------------------------------------------
# public/build is gitignored, so a fresh clone always has to build once.
if [[ -d app/node_modules ]]; then
  ok "app/node_modules"
elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
  warn "app/node_modules missing (npm ci)"
else
  ( cd app && npm ci --silent ) && ok "npm ci"
fi

if [[ -f app/public/build/manifest.json ]]; then
  ok "built assets present"
elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
  warn "app/public/build missing (npm run build)"
else
  ( cd app && npm run build --silent >/dev/null ) && ok "npm run build"
fi

# ---------------------------------------------------------------------------
step "7. ETL tooling (only needed to load data)"
# ---------------------------------------------------------------------------
if [[ -x etl/.venv/bin/python ]]; then
  ok "etl/.venv"
else
  warn "etl/.venv missing — run etl/scripts/setup-tools.sh before loading data"
fi

GDB="data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb"
if [[ -d "${GDB}" ]]; then
  ok "source geodatabase present"
else
  warn "source geodatabase not found at ${GDB}"
fi

# ---------------------------------------------------------------------------
if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  step "Check complete — nothing was changed."
  exit 0
fi

if [[ "${DATA_READY}" -eq 0 ]]; then
  step "Next: load the parcel data"
  cat <<TXT
  The map needs the county's 2025 parcel geodatabase, which is too large for git.
  Put the extracted package at:

    data/raw/2025ESRI_Parcels/

  then run (about a minute):

    etl/scripts/setup-tools.sh       # once, creates etl/.venv
    etl/scripts/load-parcels.sh      # GDB -> PostGIS

  The stack will start anyway — you will get a basemap with no parcels on it.
TXT
fi

if [[ "${NO_START}" -eq 1 ]]; then
  step "Setup complete (--no-start). Run infra/scripts/dev-up.sh when ready."
  exit 0
fi

# ---------------------------------------------------------------------------
step "8. Starting the stack"
# ---------------------------------------------------------------------------
infra/scripts/dev-up.sh

# Give the services a moment, then confirm rather than assume.
sleep 3
step "Smoke test"
for path in "/" "/api/health" "/tiles/parcels"; do
  code="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${PROXY_PORT:-8080}${path}" || echo 000)"
  if [[ "${code}" == "200" ]]; then ok "${path} → ${code}"; else fail "${path} → ${code}"; fi
done

cat <<TXT

$(bold "Open the map:")  http://127.0.0.1:${PROXY_PORT:-8080}/

  Two things that look like bugs and are not:
    • Focus the browser tab. MapLibre renders in requestAnimationFrame, which
      Chrome throttles in background tabs — the map will sit blank until focused.
    • Parcels only appear at zoom 13 and closer. Below that it is basemap only.

  Stop with:  infra/scripts/dev-down.sh
  Logs:       .run/logs/
TXT

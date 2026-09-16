#!/usr/bin/env bash
# Start local stack: Martin + Laravel + same-origin proxy.
# Requires: PostGIS DB (bootstrap-db.sh), Martin binary (install-martin.sh), PHP, Node.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Load KEY=VALUE pairs safely (quoted values OK; ignore comments/blank lines).
if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env" || {
    echo "WARN: failed to source ${ROOT}/.env — check quoting of values with spaces/parens" >&2
  }
  set +a
fi

RUN_DIR="${ROOT}/.run"
LOG_DIR="${RUN_DIR}/logs"
mkdir -p "${LOG_DIR}"

MARTIN_BIN="${ROOT}/infra/bin/martin"
LARAVEL_PORT="${LARAVEL_PORT:-8000}"
MARTIN_PORT="${MARTIN_PORT:-3000}"
PROXY_PORT="${PROXY_PORT:-8080}"
DATABASE_URL="${DATABASE_URL:-postgresql://tad:tad@127.0.0.1:5432/tad_analysis}"

if [[ ! -x "${MARTIN_BIN}" ]]; then
  echo "Martin not found at ${MARTIN_BIN}. Run: infra/scripts/install-martin.sh" >&2
  exit 1
fi

if ! command -v php >/dev/null; then
  echo "php not found" >&2
  exit 1
fi

if ! command -v node >/dev/null; then
  echo "node not found (needed for same-origin proxy)" >&2
  exit 1
fi

# Quick DB check (non-fatal warning if down — Martin/Laravel will error clearly)
if command -v psql >/dev/null; then
  if ! PGPASSWORD="${DB_PASSWORD:-tad}" psql -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-5432}" \
      -U "${DB_USERNAME:-tad}" -d "${DB_DATABASE:-tad_analysis}" -c 'SELECT 1' >/dev/null 2>&1; then
    echo "WARN: cannot connect to PostGIS as ${DB_USERNAME:-tad}@${DB_DATABASE:-tad_analysis}."
    echo "      Run: infra/scripts/bootstrap-db.sh"
  fi
fi

start_bg() {
  local name="$1"
  shift
  local pidfile="${RUN_DIR}/${name}.pid"
  local logfile="${LOG_DIR}/${name}.log"
  if [[ -f "${pidfile}" ]] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
    echo "already running: ${name} (pid $(cat "${pidfile}"))"
    return
  fi
  echo "==> starting ${name}: $*"
  nohup "$@" >"${logfile}" 2>&1 &
  echo $! >"${pidfile}"
  echo "    pid $!  log ${logfile}"
}

# --config is required, not optional: without it Martin auto-publishes every
# table it can find, which would put raw staging and the full parcels table
# (situs and all) on a public tile endpoint. The config publishes only
# public.parcels_mvt.
# --webui is a local development convenience (tile inspector at /tiles/). It is
# bound to 127.0.0.1 here and must not be enabled on the public VM.
start_bg martin \
  env DATABASE_URL="${DATABASE_URL}" \
  "${MARTIN_BIN}" \
  --config "${ROOT}/infra/martin/config.yaml" \
  --webui enable-for-all \
  --listen-addresses "127.0.0.1:${MARTIN_PORT}"

# php artisan serve wraps PHP's built-in server, which is single-worker by
# default: one slow request blocks every other. That is fine for JSON, but this
# app also serves a ~1 MB bundle, MapLibre's 513 kB worker dependency and a
# stream of tile requests, which serialised into a ~10 s first paint.
# PHP_CLI_SERVER_WORKERS forks additional workers (Linux/macOS, PHP 7.4+).
start_bg laravel \
  env PHP_CLI_SERVER_WORKERS="${PHP_CLI_SERVER_WORKERS:-8}" \
  php "${ROOT}/app/artisan" serve --host=127.0.0.1 --port="${LARAVEL_PORT}"

start_bg proxy \
  env PROXY_PORT="${PROXY_PORT}" \
      LARAVEL_URL="http://127.0.0.1:${LARAVEL_PORT}" \
      MARTIN_URL="http://127.0.0.1:${MARTIN_PORT}" \
      node "${ROOT}/infra/scripts/dev-proxy.mjs"

sleep 0.5
echo
echo "Local stack (same-origin entrypoint):"
echo "  http://127.0.0.1:${PROXY_PORT}/           → Laravel"
echo "  http://127.0.0.1:${PROXY_PORT}/api/health → Laravel health"
echo "  http://127.0.0.1:${PROXY_PORT}/tiles/catalog → Martin catalog"
echo
echo "Direct (optional):"
echo "  Laravel  http://127.0.0.1:${LARAVEL_PORT}"
echo "  Martin   http://127.0.0.1:${MARTIN_PORT}/catalog"
echo
echo "Frontend assets are served from app/public/build (Vite).
  After editing resources/js or resources/css:  cd app && npm run build
  Or run a hot-reloading dev server alongside:  cd app && npm run dev

Stop with: infra/scripts/dev-down.sh"
echo "Logs:      ${LOG_DIR}/"

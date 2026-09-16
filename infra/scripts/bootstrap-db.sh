#!/usr/bin/env bash
# Bootstrap local PostGIS database (requires superuser access once).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SQL="${ROOT}/infra/scripts/bootstrap-db.sql"

echo "==> Creating role tad / database tad_analysis + PostGIS"
echo "    (needs a Postgres superuser; typically: sudo -u postgres ...)"
echo

if [[ "${1:-}" == "--docker" ]]; then
  # Inside docker-compose postgres service as superuser
  docker compose -f "${ROOT}/infra/docker/docker-compose.yml" exec -T db \
    psql -U postgres -v ON_ERROR_STOP=1 -f - <"${SQL}"
  exit 0
fi

if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -f "${SQL}"
elif [[ -n "${PGUSER:-}" ]] || [[ -n "${PGPASSWORD:-}" ]]; then
  psql -v ON_ERROR_STOP=1 -f "${SQL}"
else
  cat <<EOF
Could not run as superuser automatically (sudo needs a password in this environment).

Run one of:

  sudo -u postgres psql -v ON_ERROR_STOP=1 -f ${SQL}

  # or, if you have a superuser password:
  PGPASSWORD=... psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -f ${SQL}

  # or Docker stack:
  ${ROOT}/infra/scripts/bootstrap-db.sh --docker

Then verify:

  PGPASSWORD=tad psql -h 127.0.0.1 -U tad -d tad_analysis -c 'SELECT postgis_full_version();'
EOF
  exit 1
fi

echo
echo "==> Verify as app role:"
PGPASSWORD=tad psql -h 127.0.0.1 -U tad -d tad_analysis -c 'SELECT postgis_full_version();'
echo "OK"

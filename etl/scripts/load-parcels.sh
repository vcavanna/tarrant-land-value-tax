#!/usr/bin/env bash
# B.3–B.11 — full parcel load: File GDB → staging → curated PostGIS.
#
# Wipe-and-reload by design; there is no incremental path (spec: manual reload
# only in v1). Roughly 10–20 minutes on a laptop for the full county.
#
#   etl/scripts/load-parcels.sh              # full load
#   etl/scripts/load-parcels.sh --skip-extract   # re-run SQL against existing staging
#   etl/scripts/load-parcels.sh --limit 5000     # small subset, for iterating
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GDB="${ROOT}/data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb"
SQL="${ROOT}/etl/sql"
SKIP_EXTRACT=0
LIMIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-extract) SKIP_EXTRACT=1; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v ogr2ogr >/dev/null 2>&1 || { echo "ogr2ogr not found. sudo apt install gdal-bin" >&2; exit 1; }
command -v psql    >/dev/null 2>&1 || { echo "psql not found." >&2; exit 1; }
[[ -d "${GDB}" ]] || { echo "Missing File GDB at ${GDB}" >&2; exit 1; }

# shellcheck disable=SC1091
[[ -f "${ROOT}/.env" ]] && set -a && source "${ROOT}/.env" && set +a || true

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_DATABASE="${DB_DATABASE:-tad_analysis}"
DB_USERNAME="${DB_USERNAME:-tad}"
DB_PASSWORD="${DB_PASSWORD:-tad}"
export PGPASSWORD="${DB_PASSWORD}"

PG="PG:host=${DB_HOST} port=${DB_PORT} dbname=${DB_DATABASE} user=${DB_USERNAME} password=${DB_PASSWORD}"
psql_run() { psql -v ON_ERROR_STOP=1 -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USERNAME}" -d "${DB_DATABASE}" "$@"; }

step() { echo; echo "=== $* ==="; }

if [[ "${SKIP_EXTRACT}" -eq 0 ]]; then
  LIMIT_CLAUSE=""
  [[ -n "${LIMIT}" ]] && LIMIT_CLAUSE=" LIMIT ${LIMIT}"

  # Geometry stays in EPSG:2276: acres must be finalised in feet before the
  # reprojection to 4326 that 02_transform does.
  step "Extract TADParcels → stg_parcels (EPSG:2276)"
  ogr2ogr -f PostgreSQL "${PG}" "${GDB}" \
    -sql "SELECT TAXPIN AS taxpin, EXEMPTSTATUS AS exemptstatus, ACRES AS acres, \
          CALCULATED_ACREAGE AS calculated_acreage, PARCELTYPE AS parceltype, \
          Shape_Area AS shape_area FROM TADParcels${LIMIT_CLAUSE}" \
    -nln stg_parcels -nlt MULTIPOLYGON -overwrite \
    -lco GEOMETRY_NAME=geom -lco SPATIAL_INDEX=NONE -lco FID=fid \
    --config PG_USE_COPY YES -progress

  step "Extract PropertyData → stg_property"
  ogr2ogr -f PostgreSQL "${PG}" "${GDB}" \
    -sql "SELECT Account_Nu AS account_nu, GIS_Link AS gis_link, Property_C AS property_c, \
          State_Use_ AS state_use_, City AS city, Situs_Addr AS situs_addr, \
          Land_Acres AS land_acres, Land_Value AS land_value, Improvemen AS improvemen, \
          Total_Valu AS total_valu, Appraised_ AS appraised_ FROM PropertyData" \
    -nln stg_property -overwrite -lco FID=fid \
    --config PG_USE_COPY YES -progress

  step "Staging row counts"
  psql_run -c "SELECT 'stg_parcels' AS t, count(*) FROM stg_parcels
               UNION ALL SELECT 'stg_property', count(*) FROM stg_property;"
else
  step "Skipping extract (--skip-extract)"
fi

for f in 01_schema 02_transform 03_indexes 04_stats 05_tiles; do
  step "${f}.sql"
  psql_run -f "${SQL}/${f}.sql"
done

step "99_validate.sql"
psql_run -f "${SQL}/99_validate.sql"

echo
echo "LOAD OK — curated table: parcels; tile source: parcels_map; style stats: map_stats"
echo "Next: point Martin at parcels_map (Section C) and copy MAP_COLOR_* into app/.env"

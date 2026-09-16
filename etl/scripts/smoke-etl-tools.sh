#!/usr/bin/env bash
# A.3 smoke test: read File GDB, sample to GeoPackage + PostGIS, report versions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${ROOT}/etl/.venv"
GDB="${ROOT}/data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb"
PROCESSED="${ROOT}/data/processed"
SAMPLE_GPKG="${PROCESSED}/smoke_tadparcels_sample.gpkg"
CLEANUP=0

for arg in "$@"; do
  case "${arg}" in
    --cleanup) CLEANUP=1 ;;
    -h|--help)
      echo "Usage: $0 [--cleanup]"
      echo "  --cleanup  Drop PostGIS table etl_smoke_parcels after success"
      exit 0
      ;;
  esac
done

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "Missing ${VENV}. Run: etl/scripts/setup-tools.sh" >&2
  exit 1
fi

if [[ ! -d "${GDB}" ]]; then
  echo "Missing File GDB at ${GDB}" >&2
  exit 1
fi

# shellcheck disable=SC1091
[[ -f "${ROOT}/.env" ]] && set -a && source "${ROOT}/.env" && set +a || true

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_DATABASE="${DB_DATABASE:-tad_analysis}"
DB_USERNAME="${DB_USERNAME:-tad}"
DB_PASSWORD="${DB_PASSWORD:-tad}"

export GDB SAMPLE_GPKG PROCESSED
export DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD CLEANUP

echo "--- System GDAL CLI ---"
if command -v ogrinfo >/dev/null 2>&1; then
  ogrinfo --version
  ogrinfo --formats 2>/dev/null | grep -iE 'OpenFileGDB|FileGDB|PostgreSQL' || true
  echo "GDB layers (ogrinfo -so):"
  ogrinfo -so -ro "${GDB}" | head -40
else
  echo "ogrinfo not installed (optional). Python path will still run."
fi

echo
echo "--- Python (pyogrio / geopandas) + PostGIS sample ---"
"${VENV}/bin/python" <<'PY'
import os
import sys
from pathlib import Path

import pyogrio
from sqlalchemy import create_engine, text

gdb = Path(os.environ["GDB"])
sample = Path(os.environ["SAMPLE_GPKG"])
processed = Path(os.environ["PROCESSED"])
processed.mkdir(parents=True, exist_ok=True)

print(f"pyogrio {pyogrio.__version__}  GDAL {pyogrio.__gdal_version__}")

layers = pyogrio.list_layers(gdb)
print("layers:")
for name, gtype in layers:
    print(f"  - {name}  ({gtype})")

expected = {"TADParcels", "PropertyData"}
found = {name for name, _ in layers}
missing = expected - found
if missing:
    print("ERROR: missing expected layers:", missing, file=sys.stderr)
    sys.exit(1)

info = pyogrio.read_info(gdb, layer="TADParcels")
print(
    f"TADParcels: features={info.get('features')} crs={info.get('crs')} "
    f"geom={info.get('geometry_type')}"
)
pd_info = pyogrio.read_info(gdb, layer="PropertyData")
print(f"PropertyData: features={pd_info.get('features')} (non-spatial table)")

# Sample extract: 5 parcels → 4326 GeoPackage
df = pyogrio.read_dataframe(gdb, layer="TADParcels", max_features=5)
assert str(df.crs).endswith("2276") or "2276" in str(df.crs), df.crs
df4326 = df.to_crs("EPSG:4326")
if sample.exists():
    sample.unlink()
pyogrio.write_dataframe(df4326, sample, layer="sample", driver="GPKG")
print(f"wrote {sample} ({sample.stat().st_size} bytes)")

# PostGIS via GeoPandas/GeoAlchemy2 (pyogrio wheel often lacks PostgreSQL driver)
url = (
    f"postgresql+psycopg://{os.environ['DB_USERNAME']}:{os.environ['DB_PASSWORD']}"
    f"@{os.environ['DB_HOST']}:{os.environ['DB_PORT']}/{os.environ['DB_DATABASE']}"
)
engine = create_engine(url)
with engine.connect() as conn:
    conn.execute(text("SELECT postgis_version()"))
    conn.commit()

df4326.to_postgis("etl_smoke_parcels", engine, if_exists="replace", index=False)
with engine.connect() as conn:
    n = conn.execute(text("SELECT COUNT(*) FROM etl_smoke_parcels")).scalar()
    srid = conn.execute(
        text("SELECT ST_SRID(geometry) FROM etl_smoke_parcels LIMIT 1")
    ).scalar()
    print(f"PostGIS etl_smoke_parcels: rows={n} srid={srid}")
    if n != 5 or int(srid) != 4326:
        print("ERROR: unexpected smoke table contents", file=sys.stderr)
        sys.exit(1)
    if os.environ.get("CLEANUP") == "1":
        conn.execute(text("DROP TABLE IF EXISTS etl_smoke_parcels"))
        conn.commit()
        print("dropped etl_smoke_parcels (--cleanup)")

print("SMOKE OK")
PY

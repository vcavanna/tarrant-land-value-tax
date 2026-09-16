#!/usr/bin/env bash
# A.3 — install / verify ETL host tooling (Python venv + optional system GDAL).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${ROOT}/etl/.venv"
REQ="${ROOT}/etl/requirements.txt"

echo "==> ETL Python venv → ${VENV}"
if [[ ! -d "${VENV}" ]]; then
  python3 -m venv "${VENV}"
fi
"${VENV}/bin/pip" install -U pip wheel
"${VENV}/bin/pip" install -r "${REQ}"

echo
echo "==> System GDAL/OGR CLI (optional but recommended for Section B)"
if command -v ogrinfo >/dev/null 2>&1; then
  ogrinfo --version
  echo "OpenFileGDB / FileGDB drivers:"
  ogrinfo --formats 2>/dev/null | grep -iE 'OpenFileGDB|FileGDB|PostgreSQL' || true
else
  cat <<'EOF'
ogrinfo not found. Install CLI tools (Ubuntu/Debian):

  sudo apt-get update
  sudo apt-get install -y gdal-bin

Python FileGDB access still works via pyogrio in etl/.venv without gdal-bin.
EOF
fi

echo
echo "==> Smoke check"
"${ROOT}/etl/scripts/smoke-etl-tools.sh"
echo
echo "Setup complete. Activate later with:  source etl/.venv/bin/activate"

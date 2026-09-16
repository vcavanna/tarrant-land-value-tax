# `etl/` — Extract, transform, load

**Spec:** Section A.3 (tooling) → Section B (full load)

## A.3 tooling (ready)

| Path | Role |
|------|------|
| `requirements.txt` | Python deps (pyogrio, geopandas, SQLAlchemy, …) |
| `.venv/` | Local virtualenv (gitignored) — create via `scripts/setup-tools.sh` |
| `scripts/setup-tools.sh` | Create venv, install deps, run smoke |
| `scripts/smoke-etl-tools.sh` | Read File GDB → sample GPKG + PostGIS |

```bash
# From repository root
etl/scripts/setup-tools.sh
etl/scripts/smoke-etl-tools.sh --cleanup
```

### Source input

```text
data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb
```

Layers of interest: `TADParcels`, `PropertyData` (join later: `TAXPIN` = `GIS_Link`).  
Details: [docs/VALUE_PER_ACRE_WEBAPP.md](../docs/VALUE_PER_ACRE_WEBAPP.md).

### Optional system GDAL

```bash
sudo apt-get install -y gdal-bin
ogrinfo -so data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb
```

## Section B (not yet)

Production pipeline will live here:

- `scripts/` — load orchestration  
- `sql/` — curated schema, aggregation, map-eligible views, stats  

Outputs: PostGIS curated parcels with precomputed VPAs; optional files under `data/processed/`.

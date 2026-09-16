# `data/` — Geospatial inputs and intermediates

## Layout

| Path | Role | In git? |
|------|------|---------|
| `raw/` | Vendor source packages (immutable inputs) | Layout + docs only; **GDB ignored** |
| `raw/2025ESRI_Parcels/` | 2025 TAD ESRI parcels map package | GDB/commondata **not** committed |
| `processed/` | Regenerable ETL exports | **Ignored** |

## 2025 source package

```text
data/raw/2025ESRI_Parcels/
├── commondata/2025parcels.gdb/   # Primary File Geodatabase (~595 MB)
├── esriinfo/                     # Package metadata
├── p20/  p30/                    # ArcGIS Pro map documents
```

**Primary layers:** `TADParcels`, `PropertyData` (join `TAXPIN` = `GIS_Link`).  
Full field notes: [docs/VALUE_PER_ACRE_WEBAPP.md](../docs/VALUE_PER_ACRE_WEBAPP.md).

## Policy

- Treat `raw/` as read-only source.
- Write intermediates only under `processed/` or into PostGIS.
- Do not commit large binaries; clone + local copy of the GDB (or shared disk) for ETL.

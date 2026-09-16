# 2025 ESRI Parcels — Data Guide & Value/Acre Web App Notes

Guide to the TAD ESRI parcel package and how to use it to build a **value-per-acre by polygon** web application.

**Source package:** `data/raw/2025ESRI_Parcels/` (extracted ArcGIS Pro Map Package)  
**Origin:** Tarrant Appraisal District (TAD), 2025 parcel data  
**Coordinate system:** NAD 1983 StatePlane Texas North Central FIPS 4202 Feet (**EPSG:2276**, US feet)  
**Implementation spec:** `docs/VALUE_PER_ACRE_SPEC.md` · **Repo layout:** root `README.md`

---

## 1. Directory layout

Package root: **`data/raw/2025ESRI_Parcels/`** (relative to the `tad-analysis` repository root).

| Path | Role |
|------|------|
| `commondata/2025parcels.gdb/` | **Primary data** (~595 MB File Geodatabase) |
| `esriinfo/` | Package metadata, thumbnail, license text |
| `p20/`, `p30/` | ArcGIS Pro map documents (`.mapx`) that layer and relate the data |

Related files outside this folder (typical download siblings):

- `2025ESRI_Parcels.mpkx` — original ArcGIS map package
- `2025ESRI_Parcels.zip` — zipped package / extract

This package is **desktop GIS content**, not a web app by itself. Browsers cannot read File Geodatabases directly; you convert and serve the data first (see `etl/` and the implementation spec).

### Metadata (from `esriinfo/iteminfo.xml`)

- **Title:** 2025ESRI_Parcels  
- **Tags:** Tarrant Appraisal District, TAD  
- **Summary:** 2025 TAD parcel data with a relationship class between a feature class and non-spatial tables  
- **Description:** TADParcels with real and business personal data as related tables  
- **License (paraphrased):** Informational only; not prepared for legal, engineering, or surveying purposes; approximate relative property boundaries only  

---

## 2. What’s inside the geodatabase

Four main datasets live in `commondata/2025parcels.gdb/`.

### 2.1 `TADParcels` (polygon feature class) — core geometry

Parcel boundaries. Rough scale: hundreds of thousands of polygons (county-wide).

| Field | Type (schema) | Meaning |
|-------|---------------|---------|
| `OBJECTID` | OID | Row id |
| `TAXPIN` | String | Parcel / tax pin — **join key** to appraisal tables |
| `EXEMPTSTATUS` | String | Exempt vs non-exempt (default often Non-Exempt) |
| `LAST_REVISION` | Date | Last revision |
| `REVISED_BY` | String | Who revised |
| `ACRES` | String | Acreage (text — parse carefully) |
| `CALCULATED_ACREAGE` | Double | Acreage (numeric) — often better for math |
| `PARCELTYPE` | Integer | Parcel type |
| `MAPPING_STATUS` | String | Mapping status |
| `SELECT_CODE` | Integer | Select / filter code |
| `created_user`, `created_date` | String / Date | Editor tracking |
| `last_edited_user`, `last_edited_date` | String / Date | Editor tracking |
| `GlobalID` | GlobalID | Global id |
| `Shape` | Geometry | Polygon geometry |
| `Shape_Area`, `Shape_Length` | Double | Area / length in CRS units (US feet) |

### 2.2 `PropertyData` (non-spatial table) — real property / appraisal

Largest table (~300 MB). Related to parcels by:

```text
TADParcels.TAXPIN  =  PropertyData.GIS_Link
```

Field names in the GDB are often **truncated** (Esri 10-character-style names). Interpret carefully against TAD documentation or sample rows.

| Field (as stored) | Likely meaning |
|-------------------|----------------|
| `Account_Nu` | Account number |
| `PIDN` | Parcel / property id |
| `GIS_Link` | Link to parcel `TAXPIN` |
| `Owner_Name`, `Owner_Addr`, `Owner_City`, `Owner_Zip`, … | Owner mailing info |
| `Situs_Addr` | Site address |
| `LegalDescr` | Legal description |
| `Property_C` | Property class / category |
| `State_Use_` | State use code |
| `Land_Value` | Land value |
| `Improvemen` | Improvement value |
| `Total_Valu` | Total value |
| `Appraised_` | Appraised value |
| `Land_Acres`, `Land_SqFt` | Land size from appraisal |
| `Ag_Code`, `Ag_Acres`, `Ag_Value` | Agricultural valuation |
| `Year_Built`, `Living_Are`, `Num_Bedroo`, `Num_Bathro`, … | Structure details |
| `County`, `City`, `School`, `ZipCode` | Jurisdiction |
| `Deed_Date`, `Deed_Book`, `Deed_Page` | Deed references |
| `Record_Typ`, `Sequence_N`, `RP`, `Appraisal_`, … | Record / appraisal identifiers |
| `Overlap_Fl`, `Instrument`, `From_Accts`, … | Misc. flags / links |

This table drives valuation for a value/acre map.

### 2.3 `PropertyData_P` (non-spatial table)

Same field pattern as `PropertyData`, same join (`TAXPIN` ↔ `GIS_Link`). Package metadata describes **real and business personal property**; `_P` is almost certainly **personal / business personal property**. Usually secondary for **land** value-per-acre maps; keep for full account context if needed.

### 2.4 `Historic_Lot_Line` (polyline feature class)

Historic lot lines for reference mapping. **Not required** for value/acre.

### 2.5 Map documents (`.mapx`)

`p20/2025ESRI_Parcels.mapx` and `p30/2025ESRI_Parcels.mapx` define layers, basemaps (World Topographic Map, World Hillshade), and relates:

| Relate name | Keys |
|-------------|------|
| `Relate_PD` / `Relate_P` | Primary: `TADParcels.TAXPIN` · Foreign: `GIS_Link` |

---

## 3. Conceptual data model

```text
┌─────────────────────┐         TAXPIN = GIS_Link         ┌──────────────────┐
│     TADParcels      │ 1 ─────────────────────────── *  │   PropertyData   │
│  (polygons)         │                                   │  (appraisal)     │
│  geometry, ACRES    │                                   │  Total_Valu, …   │
└─────────────────────┘                                   └──────────────────┘
          │
          │ same join pattern
          ▼
┌─────────────────────┐
│  PropertyData_P     │
│  (personal prop.)   │
└─────────────────────┘
```

**Important:** the join is a **relationship**, often **one parcel → many accounts** (multi-account parcels, condos, etc.). For a clean map you must decide how to **aggregate** values onto each polygon.

---

## 4. Value / acre by polygon — calculation

Core formula:

```text
value_per_acre = total_value / acres
```

### 4.1 Choose the numerator (value)

| Choice | Field(s) | Use when |
|--------|----------|----------|
| Total package | `Total_Valu` | Overall assessed/market-style $/acre |
| Land only | `Land_Value` | Pure land value intensity (often best for “land $/acre”) |
| Appraised | `Appraised_` | When you specifically need appraised value |
| Multi-account | `SUM(...)` over accounts for one `GIS_Link` | Multiple rows per parcel |

### 4.2 Choose the denominator (acres)

Prefer, in order:

1. **`TADParcels.CALCULATED_ACREAGE`** (numeric, geometry-oriented)  
2. **`PropertyData.Land_Acres`** (appraisal land size)  
3. **`TADParcels.ACRES`** (parse string → number)  
4. Geometry: `Shape_Area` (sq ft in EPSG:2276) ÷ **43,560**

### 4.3 Guardrails

```text
WHERE acres > 0
  AND value IS NOT NULL
  -- optionally: value > 0
  -- optionally filter EXEMPTSTATUS, parcel type, non-real accounts
```

### 4.4 Aggregation example (parcel-level SQL sketch)

```sql
SELECT
  p.TAXPIN,
  p.geometry,
  SUM(CAST(d.Total_Valu AS numeric)) AS total_value,
  COALESCE(
    NULLIF(p.CALCULATED_ACREAGE, 0),
    NULLIF(MAX(CAST(d.Land_Acres AS numeric)), 0)
  ) AS acres,
  SUM(CAST(d.Total_Valu AS numeric))
    / NULLIF(
        COALESCE(
          NULLIF(p.CALCULATED_ACREAGE, 0),
          NULLIF(MAX(CAST(d.Land_Acres AS numeric)), 0)
        ),
        0
      ) AS value_per_acre
FROM TADParcels p
LEFT JOIN PropertyData d ON p.TAXPIN = d.GIS_Link
GROUP BY p.TAXPIN, p.geometry, p.CALCULATED_ACREAGE;
```

**Acres rule of thumb when aggregating:** **sum values once per account; use parcel acres only once** (do not sum `Land_Acres` across accounts unless you know accounts partition the land without double-counting).

### 4.5 Two interpretations of “divided by polygons”

| Mode | Meaning | How |
|------|---------|-----|
| **A. Parcel choropleth** | Each parcel polygon colored by its own $/acre | Join + aggregate to parcel; style `value_per_acre` |
| **B. Larger zones** | Neighborhoods, tracts, or user-drawn areas | Spatially aggregate parcels: `Σ value / Σ acres` |

Both start from the same joined parcel layer; (B) adds a dissolve / zone join step.

---

## 5. Building a web application

### 5.1 Step 1 — Open / extract the File GDB

| Tool | Notes |
|------|--------|
| **GDAL/OGR** | `ogrinfo`, `ogr2ogr` — solid default |
| **ArcGIS Pro** | Export to GeoPackage, GeoJSON, Feature Service, etc. |
| **QGIS** | Open GDB, export |
| **Python** | `geopandas` + `pyogrio` / `fiona` (needs GDAL) |

Example:

```bash
# From repository root; GDB path relative to package
GDB=data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb

# Inspect layers
ogrinfo -so "$GDB"

# Export parcels (reproject for web) — example intermediate under data/processed/
ogr2ogr -t_srs EPSG:4326 data/processed/parcels.gpkg \
  "$GDB" TADParcels

# Export appraisal table
ogr2ogr data/processed/property.gpkg "$GDB" PropertyData
```

- Reproject to **EPSG:4326** or **EPSG:3857** for most web maps.  
- Prefer computing **area in EPSG:2276 (feet)** *before* reprojecting, if you use geometry-based acres.

### 5.2 Step 2 — Join + compute metrics offline

1. Join `TAXPIN` ↔ `GIS_Link`  
2. Cast string value fields to numbers (handle blanks, commas, nulls)  
3. Aggregate multi-account parcels  
4. Compute `value_per_acre` and optionally `land_value_per_acre`  
5. Keep a lean attribute set for the map: metrics + popup fields (owner, situs, year built, use code, etc.)

### 5.3 Step 3 — Serve for the browser

County-wide parcels are too heavy as a single raw GeoJSON. Prefer:

| Approach | When |
|----------|------|
| **Vector tiles (MVT / PMTiles)** | Best general interactive map performance |
| **PostGIS + API** (bbox / tile queries) | Filtering, search, analysis |
| **GeoPackage / Parquet + DuckDB** | Local tools / prototypes |
| **ArcGIS Feature / Map Service** | Staying in the Esri stack |
| **Tippecanoe / martin / pg_tileserv / Protomaps** | Tile generation and serving |

Precompute `value_per_acre`, simplify geometries at low zooms, full detail at high zoom.

### 5.4 Step 4 — Front end (choropleth)

Typical stack:

- **MapLibre GL JS** or **Leaflet** + vector tiles  
- Color scale on `value_per_acre`  
- Use **quantiles** or a **log scale** — land values are heavily skewed  
- Click → popup: address, owner, total value, acres, $/acre, land vs improvement  
- Filters: city, school district, use code, min/max $/acre, year built  
- Optional: user draws a polygon → weighted avg $/acre of intersected parcels (`Σ value / Σ acres`)

Example MapLibre color expression (replace breaks with quantiles from your data):

```js
'fill-color': [
  'step', ['get', 'value_per_acre'],
  '#f7fcf5',
  50000, '#c7e9c0',
  150000, '#74c476',
  400000, '#238b45',
  1000000, '#00441b'
]
```

### 5.5 Useful app features for this dataset

1. Choropleth of $/acre (total and/or land-only)  
2. Parcel identify (click → appraisal details)  
3. Search by address, owner, TAXPIN, account  
4. Compare modes: land $/acre vs total $/acre vs improvement intensity  
5. Custom AOI analysis (draw polygon → aggregate)  
6. Filters by `City`, `School`, use code, exemption  

---

## 6. Recommended architecture

```text
2025parcels.gdb
    │  ogr2ogr / geopandas
    ▼
ETL job
  - join TAXPIN = GIS_Link
  - aggregate accounts → parcel
  - value_per_acre = total_value / acres
  - reproject → 4326 (area done in 2276 if needed)
  - simplify for tiles
    │
    ├─► PostGIS  (source of truth + search)
    └─► PMTiles / MVT  (map display)
              │
              ▼
        MapLibre (or ArcGIS JS) web app
        choropleth + popup + filters + optional AOI
```

### Minimal MVP path

1. Export a **subset** (one city) as GeoJSON or GeoPackage  
2. Join + compute `value_per_acre`  
3. Leaflet/MapLibre choropleth + popups  
4. Validate join, nulls, and color breaks  
5. Scale to full county with vector tiles + PostGIS (or tiles only)  

---

## 7. Caveats

1. **License / fitness for use** — Informational only; not a legal survey.  
2. **Truncated field names** — Confirm `Total_Valu`, `Improvemen`, `Appraised_`, etc. against TAD docs or samples.  
3. **Many value fields are strings** — Cast carefully.  
4. **One-to-many accounts** — Sum values; do not double-count acres.  
5. **CRS** — Area in feet under EPSG:2276; after reprojecting to 4326, don’t recompute area from web geometry without care.  
6. **Size** — Full-county interactive map needs tiles or server queries.  
7. **PII** — Owner names and addresses are present; treat carefully if publishing publicly.  

---

## 8. Quick reference

| Need | Use |
|------|-----|
| Parcel polygons | `TADParcels` |
| Appraisal values | `PropertyData` |
| Join key | `TADParcels.TAXPIN` = `PropertyData.GIS_Link` |
| Acres (preferred) | `CALCULATED_ACREAGE` or carefully chosen land acres |
| Total value | `Total_Valu` (cast to number) |
| Land value | `Land_Value` (cast to number) |
| Metric | `value_per_acre = value / acres` |
| CRS for area | EPSG:2276 (US feet) |
| CRS for web | EPSG:4326 or EPSG:3857 |
| Personal property table | `PropertyData_P` (optional for land $/acre) |
| Historic lines | `Historic_Lot_Line` (optional basemap context) |

---

## 9. Next steps (when ready to implement)

1. Install GDAL (or use ArcGIS Pro / QGIS) and list layers with `ogrinfo`.  
2. Export a small geographic subset and inspect real values in `Total_Valu`, `Land_Value`, `GIS_Link`, `TAXPIN`.  
3. Write a short ETL script (Python or SQL) that produces a single parcel layer with `value_per_acre`.  
4. Prototype the map on the subset.  
5. Productionize with tiles + (optional) PostGIS search/API.  

---

*Generated as working notes for building a Tarrant County value-per-acre polygon web map from the 2025 TAD ESRI parcels package.*

# Tarrant County Value-per-Acre Map — Product & Implementation Spec

**Status:** Design freeze (implementation-ready)  
**Related notes:** `docs/VALUE_PER_ACRE_WEBAPP.md` (data guide & original ideas)  
**Repo layout:** repository root `README.md` (Section A.1)  
**Stack:** Laravel · PostgreSQL/PostGIS · Martin · MapLibre GL JS · OpenFreeMap · GCE (single VM) + local dev

This document synthesizes the design discussion into **sections of work**, each broken into **broad tasks**, with **section-level dependencies** called out. It is a plan for building the system, not application code.

### Repository map (A.1)

| Path | Role |
|------|------|
| `docs/` | This spec + data guide |
| `app/` | Laravel application (APIs + MapLibre shell) |
| `etl/` | Load scripts and SQL for PostGIS |
| `infra/` | Docker, Martin, nginx, deploy scripts |
| `data/raw/2025ESRI_Parcels/` | TAD ESRI source package (File GDB) |
| `data/processed/` | Regenerable intermediates (gitignored) |

---

## 1. Product summary

A **public** web map of Tarrant County parcels colored (and optionally extruded in 3D) by precomputed **value per acre (VPA)**. Users toggle **metric** (land / total / appraised) and **view mode** (2D color vs 3D extrusion), click a parcel for a **selection drawer** (summary + 3 comps), and may open richer detail later from the same API shape. No owner names. TAD license footer. No Mapbox product dependency, no turf.js, no AOI tools, no fuzzy owner/address search, no aggregate geography layers in v1.

### 1.1 Hybrid architecture (one line)

| Layer | Responsibility |
|-------|----------------|
| **PostGIS** | Source of truth: parcel geometry + precomputed acres/VPAs + detail attributes |
| **Martin** | Dynamic **MVT** tiles (lean properties); simplified by zoom |
| **CDN** | Cache tile responses (dataset treated as immutable for now) |
| **Laravel** | App shell, **dynamic** drawer/detail/comps JSON APIs, ETL orchestration |
| **MapLibre** | Map UI: OpenFreeMap basemap + parcel overlay, dual mode, click → drawer |
| **OpenFreeMap** | Basemap only |

```text
GDB → ETL → PostGIS (4326, precomputed VPAs)
                ├─► Martin → CDN → MapLibre (paint)
                └─► Laravel APIs → MapLibre drawer (explain)
```

### 1.2 Locked product rules

| Topic | Rule |
|-------|------|
| Grain | **Parcel-level** after account aggregation |
| Metrics stored | **All** VPA definitions: land, total, appraised (at minimum) |
| Map eligibility | **Exclude** null/zero VPA, parcels under the **acres floor** (0.005 ac), and parcels under the **land-value floor** ($1,000 nominal placeholders). Exempt exclusion **dropped** — the source field carries no signal (see B.1 notes) |
| Tiles | **Lean**: id + VPA columns (± acres); no filter query params in v1 |
| Drawer | **Rich** API by `taxpin`: summary + **3 comps**; **no owner name** |
| Default UI | **2D color** + **land VPA** |
| Color domain | **Countywide** fixed min/max |
| 3D | Height from selected VPA; **per-metric `cap`** (land `1_500_000`, total/appraised `6_500_000`) and **per-metric `k`** sharing one 3,000 m ceiling (land `1/500`); over-cap → **black** fill/extrusion; true VPA always in drawer |
| Zoom | **No aggregate tables** v1; **`ST_Simplify` by z** + **parcel layer minzoom** (basemap only below) |
| Comps | Same city + acres in **[0.5×, 2×]** subject; order by **\|\|Δ land VPA\|\| DESC** (drama); fill to 3 by dropping city, then acreage |
| CRS | Store **`geom` EPSG:4326**; acres & VPAs **precomputed attributes** (area logic from source CRS in ETL) |
| Acres floor | **0.005 acres** (~218 sq ft) minimum for map eligibility; below that VPA is an artifact |
| Land-value floor | **$1,000** minimum for map eligibility; below that TAD is recording a placeholder, not a valuation (B.2) |
| Legal | **TAD informational / license footer**; not for legal/survey use |
| Auth | **Public** |
| Hosting | **One GCE VM** (+ local Docker-style dev); HTTPS; prefer **same origin** (`/`, `/api`, `/tiles`) |
| Out of scope v1 | Mapbox billing path, turf.js, AOI, fuzzy search, yearly refresh automation, quantile legend requirement, aggregate zip/tract layers |

---

## 2. Task sections and dependency graph

Sections are ordered so that **foundations come first**. Arrows mean **“must be sufficiently done before.”**

```text
  A. Foundations & environments
           │
           ▼
  B. Data model & ETL
           │
           ├──────────────────────┐
           ▼                      ▼
  C. Martin tile layer     D. Laravel APIs
           │                      │
           └──────────┬───────────┘
                      ▼
              E. MapLibre frontend
                      │
                      ▼
              F. Production deploy & CDN
                      │
                      ▼
              G. Hardening & polish (can overlap late E/F)
```

| Section | Depends on | Unblocks |
|---------|------------|----------|
| **A. Foundations** | — | B, and local work for all later sections |
| **B. Data model & ETL** | A | C, D |
| **C. Martin tiles** | A, B | E, F |
| **D. Laravel APIs** | A, B | E, F |
| **E. MapLibre frontend** | C (tiles reachable), D (drawer API), A (app host) | F, G |
| **F. Production deploy & CDN** | C, D, E (MVP UI), A (infra baseline) | public launch |
| **G. Hardening & polish** | E (and ideally F) | production quality |

**Parallelism:** After **B** is loaded and validated, **C** and **D** can proceed **in parallel**. **E** needs at least stub tiles + stub drawer; full polish needs both complete. **F** can start VM/nginx while E is in progress, but go-live needs E.

---

## 3. Section A — Foundations & environments

**Depends on:** nothing  
**Goal:** Repeatable local and production-shaped runtimes for Postgres/PostGIS, Martin, Laravel, and a web entrypoint.

### Tasks (broad strokes)

1. **Define repo layout** for Laravel app, infra configs (Docker Compose / scripts), ETL scripts, and docs (this spec + data guide). — **Done** (see root `README.md`).
2. **Local development stack:** PostGIS, Martin, Laravel (PHP), nginx or `artisan serve` + reverse-proxy sketch; document ports and env vars. — **Done** (see `docs/LOCAL_DEV.md`, `infra/scripts/dev-up.sh`).
3. **Tooling for ETL host:** GDAL/OGR (and/or Python geo stack) available locally for GDB → PostGIS. — **Done** (`etl/scripts/setup-tools.sh`, `smoke-etl-tools.sh`, `etl/requirements.txt`).
4. **Convention for config:** `k`, `cap`, color domain min/max, parcel minzoom, Martin URL path, OpenFreeMap style URL — env or config file, not hard-coded forever. — **Done** (`MAP_*`, `app/config/map.php`, docs).
5. **Same-origin path plan:** e.g. `/` app, `/api/*` Laravel, `/tiles/*` Martin (via proxy) to minimize CORS pain. — **Done** (`infra/scripts/dev-proxy.mjs`, `infra/nginx/local.conf`).

### Exit criteria

- Developer can start PostGIS + Martin + Laravel locally with documented commands.
- Empty PostGIS accepts connections; Martin health-checkable even before real layers.

### A.1 completion notes

Repo layout established at monorepo root: `docs/`, `app/`, `etl/`, `infra/`, `data/raw|processed/`. Source package lives at `data/raw/2025ESRI_Parcels/`. Large GDB paths are gitignored; see root `README.md` and `.gitignore`.

### A.2 completion notes

- **Laravel 13** scaffolded under `app/` with `GET /api/health` and `config/map.php`.
- **Martin 1.13** installed via `infra/scripts/install-martin.sh` → `infra/bin/martin` (gitignored binary).
- **PostGIS DB** bootstrap: `infra/scripts/bootstrap-db.sql` / `bootstrap-db.sh` (role `tad`, db `tad_analysis`). Requires a Postgres superuser once (e.g. `sudo -u postgres …`).
- **Same-origin local entry:** Node proxy `infra/scripts/dev-proxy.mjs` on **:8080** (`/` + `/api` → Laravel :8000, `/tiles` → Martin :3000). Optional `infra/nginx/local.conf` and `infra/docker/docker-compose.yml`.
- **Runbooks:** `docs/LOCAL_DEV.md`, `infra/scripts/dev-up.sh` / `dev-down.sh`.

### A.3 completion notes

- **Python ETL venv:** `etl/requirements.txt` + `etl/scripts/setup-tools.sh` → `etl/.venv` (pyogrio ships GDAL; reads FileGDB).
- **Smoke:** `etl/scripts/smoke-etl-tools.sh` lists GDB layers, samples 5 `TADParcels` → `data/processed/*.gpkg` + PostGIS `etl_smoke_parcels` (EPSG:4326).
- **System `gdal-bin`:** recommended for Section B CLI (`ogrinfo`/`ogr2ogr`); documented in README / LOCAL_DEV; not strictly required if Python path works.
- **Full local setup docs:** root `README.md` + `docs/LOCAL_DEV.md`.

---

## 4. Section B — Data model & ETL

**Depends on:** A  
**Goal:** One curated parcel dataset in PostGIS suitable for tiles and APIs.

### Tasks (broad strokes)

1. **Inspect source GDB** (`TADParcels`, `PropertyData`, join `TAXPIN` = `GIS_Link`); confirm truncated value fields and sample multi-account parcels (see `VALUE_PER_ACRE_WEBAPP.md`).
2. **Specify target schema** (conceptual tables/views):
   - Raw import tables (optional, for reprocessing).
   - **Curated `parcels`** (or equivalent): `taxpin` (PK after dedupe), `geom` (4326), `acres`, `land_vpa`, `total_vpa`, `appraised_vpa`, value components as needed, use/class (`Property_C`, `State_Use_`), city **code**, situs, map-eligibility flag or enforced by view. No exempt flag (B.1).
3. **ETL: extract** parcels + appraisal table via ogr2ogr/geopandas; cast string numerics safely.
4. **ETL: aggregate accounts → parcel** (sum values once; acres once; document rules for multi-account).
5. **ETL: compute and store all VPA columns** (`value / acres` with guards); do **not** recompute from 4326 geometry.
6. **ETL: reproject** geometry to **EPSG:4326** for storage (area/acres already finalized).
7. **Map eligibility rule:** exclude null/zero values and parcels below the **0.005-acre floor** from the **layer used by Martin** (view or filtered table). No exempt filter.
8. **Indexes:** GIST on `geom`; B-tree on `taxpin`; defer other indexes until query plans demand them.
9. **One-time stats for map style:** countywide min/max (and optional p99) for land/total/appraised VPA among **map-eligible** parcels → store in `map_stats` or config exported for the frontend.
10. **Validation checklist:** join coverage, multi-account rates, VPA distribution sanity, row counts, null rates, spot-check known parcels.
11. **Load path documentation:** how to wipe/reload (manual is fine; no automated yearly refresh in v1).

### Exit criteria

- Map-eligible parcel count and VPA ranges known.
- Point queries by `taxpin` and spatial bbox queries work.
- Sample SQL for “drawer fields + comps inputs” succeeds.

### Notes / non-goals

- Aggregate zip/tract tables: **out of scope**.
- Yearly refresh pipeline: **out of scope** (manual reload only).

### B.1 completion notes — source profiling

Produced by `etl/scripts/profile-source.py` (read-only; ~22 s full county; machine-readable
output at `data/processed/source_profile.json`). Re-run after any source refresh.

**Layer inventory:** `TADParcels` 689,933 polygons (EPSG:2276) · `PropertyData` 716,370 rows ·
`PropertyData_P` 39,537 rows (personal property, unused) · `Historic_Lot_Line` 60,308 (unused).

#### Join quality — better than assumed

| Measure | Result |
|---|---|
| Parcels with ≥1 account | **686,125 / 689,908 (99.45%)** |
| Accounts with blank `GIS_Link` | 3,731 (0.52%) |
| Accounts with no matching parcel | **31** |
| Matched parcels with exactly one account | **675,908 (98.51%)** |
| Multi-account parcels | 10,217 · max **494** accounts on one parcel (condo tower) |
| Multi-account parcels with conflicting `City` | 428 (4.19%) — take `City` from the largest-value account |

**Numeric parsing is clean:** zero unparseable values across `Land_Value`, `Improvemen`,
`Total_Valu`, `Appraised_`, `Land_Acres`. Blanks are a uniform 0.52% (the same 3,731 rows).
`Land + Improvement = Total` holds on **100.00%** of comparable rows, so `total` is derivable —
but `Total = Appraised` holds on only **79.64%**, so appraised earns its own stored column.

#### Decision 1 — exempt exclusion is **dropped**

`EXEMPTSTATUS` is `'Non-Exempt'` on 99.98% of rows; the other 145 are nulls, blanks and junk
(`'3'`, `'.'`, `'+'`, `'r'`, `'H'`). Filtering non-exempt drops **zero** parcels from the funnel,
and **zero** exempt parcels carry land value. `Property_C = 'X'` (the real exempt class) covers
just **90 accounts**. This package is taxable property only — churches, schools and government
land are not in it. The rule in §1.2 was unimplementable and has been removed rather than
faked; no eligibility filter keys off exemption.

#### Decision 2 — `cap` was wrong by ~3 orders of magnitude

Measured land VPA over the eligible set (n = 682,788):

| Metric | p5 | p25 | **p50** | p75 | p95 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|---|
| land | 54.6k | 187k | **307k** | 436k | 796k | 1.67M | 3.17M | 1.48B |
| total | 99.7k | 847k | 1.46M | 2.14M | 3.38M | 6.41M | 15.4M | 1.48B |
| appraised | 88.6k | 781k | 1.42M | 2.11M | 3.33M | 6.33M | 15.2M | 1.48B |

At the original `cap = 5000`, **98.26% of the county would render black**. Caps are now
**per metric**, anchored near the measured p99 (land 1.5M; total/appraised 6.5M), because land
and total differ by roughly 5×. `k` is per-metric too, chosen so all three top out at the same
**3,000 m** ceiling — land `k = 1/500`, total/appraised `k = 1/2167` — which keeps the metric
toggle visually comparable. See §10.2.

#### Decision 3 — acres floor of **0.005 acres** (~218 sq ft)

The 1.48B/acre maximum is a 0.000534-acre scrap holding $792k. Effect of candidate floors:

| Floor | Parcels removed | Resulting max land VPA |
|---|---|---|
| none | 0 | $1,482,206,213 |
| 0.001 | 12 | $78,408,482 |
| **0.005** | **142 (0.02%)** | **$35,997,097** |
| 0.01 | 361 | $35,997,097 |
| 0.05 | 9,018 | $35,997,097 |

0.005 removes both artifacts and then stops paying off: the next parcel down
(`42371C---09`, 0.44 ac, $15.8M land value) is legitimate downtown land, not a sliver. For
scale, the 1st percentile of eligible parcel size is 0.043 ac — the floor sits an order of
magnitude below anything real.

#### Decision 4 — `taxpin` dedupe makes the primary key valid

`TAXPIN` is *nearly* unique: **16 blank** and **16 duplicated rows across 7 distinct keys**.
The duplicates are three different problems:

| TAXPIN | Rows | Nature |
|---|---|---|
| `13740-1-1AR1R2` | 2 | Exact duplicate (identical acres + `Shape_Area`) |
| `A 555-1C05` | 2 | Real polygon + degenerate 0.78 sqft sliver |
| `A 356-2` | 3 | Real polygon + two slivers; all three carry the same 0.2016 acres |
| `10460-1-1` | 3 | Three parts, two with null acreage |
| `15630-12-8-10`, `A1888-1`, `A1888-1A` | 2 each | Genuine multi-part parcels, distinct acreages |

`MAX(acres)` truncates the genuine multi-parts; `SUM(acres)` triple-counts `A 356-2`. **Rule:**
`ST_Union` geometry grouped by `taxpin`, and for these seven keys only, derive acres from the
unioned EPSG:2276 area ÷ 43,560 instead of `CALCULATED_ACREAGE`. Correct for all three cases at
once, and defensible because the two agree within 5% on 89% of the county.

The 16 blank-`TAXPIN` rows are discardable: 15 have null acreage, 11 have `Shape_Area = 0`, none
join to an account. **Net: 689,933 rows → 689,908 parcels, `taxpin` as a true primary key.**

#### Decision 5 — `City` stays a raw code in v1

`City` is a 43-value numeric code (`026` = 308,953 rows, `024` = 113,728, …) with no lookup
table in the GDB. Comps group on the code correctly; the drawer will display `026` until TAD's
city-code table is sourced. Accepted for v1.

#### Acres source and the eligibility funnel

`CALCULATED_ACREAGE` is usable on 99.67% of parcels. The `Land_Acres` fallback rescues **2,201
of the 2,262** failures, so it is worth wiring in. The two disagree by >20% on 5,611 parcels
(0.82%) — stale geometry or stale acreage, immaterial at this rate.

| Funnel step | Parcels |
|---|---|
| All parcels | 689,909 |
| has ≥1 matched account | 686,125 (99.45%) |
| + acres > 0 | 683,909 (99.13%) |
| + land value > 0 | **682,788 (98.97%)** |

682,788 is the count on `CALCULATED_ACREAGE` alone. The `Land_Acres` fallback then adds 2,245
and the acres floor removes 142, giving 684,851; the land-value floor added in B.2 removes a
further 10,332, so the **realised tile row count is 674,519**.

#### Open items carried into B.2/B.3

- `MAP_COLOR_MIN` / `MAP_COLOR_MAX` still unset — populate from `map_stats` once loaded.
  The p5–p95 band (land: 54.6k–796k) is the sensible starting domain; the 1.48B max means a
  linear ramp to `max` is unusable.
- `app/config/map.php` needs restructuring from scalar `vpa_cap` / `height_k` to per-metric maps.

### B.2–B.11 completion notes — schema and load

Built and run against the full county. Load takes **~1 minute** end to end (~25 s extract,
~30 s transform), so a wipe-and-reload is cheap enough that no incremental path is needed.

| Artifact | Role |
|---|---|
| `etl/sql/01_schema.sql` | `etl_num()`, `parcels`, `parcels_map`, `map_stats` |
| `etl/sql/02_transform.sql` | staging → curated: dedupe, repair, aggregate, VPA, reproject |
| `etl/sql/03_indexes.sql` | geom GIST + partial `(city_code, acres)` for comps |
| `etl/sql/04_stats.sql` | `map_stats` + the `MAP_COLOR_*` lines to paste into `app/.env` |
| `etl/sql/99_validate.sql` | B.10 checklist as PASS/FAIL rows against the B.1 expectations |
| `etl/scripts/load-parcels.sh` | driver; `--skip-extract` re-runs SQL, `--limit N` for a subset |

**Loaded result: 689,908 parcels, 674,519 map-eligible.** All 17 validation checks pass.

#### Design decisions taken during implementation

- **Eligibility is a stored column, not just a view predicate.** `parcels.map_eligible` is a
  `GENERATED ALWAYS … STORED` boolean; `parcels_map` is `WHERE map_eligible`. Section D's comps
  query needs the same rule *plus* `city_code`, which the lean tile view deliberately omits —
  without the flag the rule would have been restated in every drawer query and drifted.
- **`acres_source` is recorded per parcel** (`calculated` | `land_acres` | `geometry`) so a
  surprising VPA can be traced to its denominator. 2,200 parcels use the `land_acres` fallback.
- **Geometry is repaired only where invalid.** 22 parcels tripped ring self-intersections or a
  hole-outside-shell; `ST_MakeValid` + `ST_CollectionExtract(…, 3)` runs only on those. Left
  unrepaired they would have failed `ST_UnaryUnion` here and `ST_Simplify` in the tile query.
- **Unmatched parcels are stored** (3,783, `account_count = 0`, NULL VPAs) so a direct
  `/api/parcels/{taxpin}` lookup resolves; `map_eligible` is false, so they never reach a tile.
- **A $1,000 land-value floor was added after the first load** (see below). Excluded parcels are
  still stored and reachable by taxpin; only `map_eligible` is false.
- **`improvement_value` is stored** despite being derivable, for the drawer's land-vs-improvement
  contrast.

#### Data quirk found during validation

`Land + Improvement = Total` holds on **689,907 of 689,908** parcels, not all of them. Parcel
`26911C---09` (a 31-account condo) has two accounts where `Total_Valu` exceeds `Land +
Improvement` by ~$18k each; on those same accounts `Appraised_` equals `Land + Improvement`
exactly, so TAD's total carries a component outside the land/improvement split. Immaterial at
this rate, but it means the identity is a near-invariant and the validation check allows ≤ 5.

#### Nominal-value placeholders — found during verification

TAD carries a large population of parcels at a **nominal** land value rather than a real one:
**8,164 at exactly $1** and **799 at exactly $100**; 11,574 sit at or below $1,000. They are
overwhelmingly class `C1` (vacant residential lots, HOA common areas, drainage easements), plus
some public utility land — the largest is `A  85-8`, a 156.9-acre `J1` tract on Lake Worth
carried at $1 whose immediate neighbour `A  85-8D` is the same class at 138.8 acres and $1.6M.
Note this is also the population the dropped exempt rule was meant to catch; `EXEMPTSTATUS`
reads `Non-Exempt` on it, which is further evidence that field is inert.

They form a distinct population, not a tail — measured land VPA runs $18 at p1 and $9,858 at p2.
**Rule: `land_value > 1000` added to `map_eligible`,** which sits inside that cliff.

This mattered most for **comps**, not paint. The colour ramp starts at p5, so placeholders would
merely clamp to the floor colour; but the locked comp rule orders by `ABS(land_vpa - subject)
DESC`, so the "most different" neighbours of any normal parcel are exactly these $1 lots. Every
drawer in a subdivision would have shown three meaningless comps. Filtering in `map_eligible`
fixes paint and comps in one place.

**Not** excluded: 50 parcels with genuinely low VPA above the floor, mostly `D1` agricultural and
large rural `C1C` tracts. Texas 1-d-1 open-space valuation taxes ag land on productivity rather
than market value (e.g. `A1185-3`, 12.3 ac at $2,000 = $162/acre), which is a real number and
arguably the sort of thing this map exists to show. Placeholders are nominal round figures
unrelated to size; these scale with acreage.

**Eligible count: 684,851 → 674,519.**

#### Measured stats now in `map_stats`

| Metric | p5 | p50 | p95 | p99 | cap | k | over cap |
|---|---|---|---|---|---|---|---|
| land | 71,981 | 311,356 | 807,925 | 1,697,524 | 1,500,000 | 1/500 | 8,459 (1.25%) |
| total | 145,664 | 1,481,249 | 3,410,433 | 6,543,382 | 6,500,000 | 1/2167 | 6,844 (1.01%) |
| appraised | 133,415 | 1,441,147 | 3,353,619 | 6,433,450 | 6,500,000 | 1/2167 | 6,597 (0.98%) |

(Measured over the 674,519 eligible parcels, after the land-value floor.)

The chosen caps land almost exactly on the realised p99 — **~1% of parcels render black** per
metric, against 98.26% under the original `cap = 5000`. Top VPAs are now plausible downtown
land (`42371C---09`: 0.44 ac, $15.8M land value, F1 commercial) rather than sliver artifacts.

`MAP_COLOR_MIN` / `MAX` per metric (the p5–p95 band): land **71,981–807,925**; total
**145,664–3,410,433**; appraised **133,415–3,353,619**. `04_stats.sql` prints these on every load.

#### Reload procedure (B.11)

```bash
etl/scripts/load-parcels.sh                  # full wipe-and-reload from the GDB
etl/scripts/load-parcels.sh --skip-extract   # re-run SQL only, staging untouched
etl/scripts/load-parcels.sh --limit 5000     # subset, for iterating on the SQL
```

Staging tables (`stg_parcels`, `stg_property`) and the intermediates (`etl_parcel_geom`,
`etl_account_agg`) are retained after a load for inspection. After a source refresh, re-run
`profile-source.py` first and update the expectations in `99_validate.sql`.

---

## 5. Section C — Martin tile server

**Depends on:** A, B  
**Goal:** Dynamic vector tiles for map-eligible parcels with lean properties and zoom-aware simplification.

### Tasks (broad strokes)

1. **Configure Martin** against PostGIS (table or **function/source** recommended for simplify-by-z).
2. **Define lean tile properties:** at least `taxpin`, `land_vpa`, `total_vpa`, `appraised_vpa` (optional `acres`); no owner; no long text.
3. **Implement zoom simplification:** `ST_Simplify` / `ST_SimplifyPreserveTopology` (or equivalent) parameterized by `z` inside tile SQL/function.
4. **Enforce map eligibility** in the tile source (same rules as product: no null/zero values, nothing under the acres floor).
5. **Parcel layer minzoom policy:** document and enforce (Martin minzoom and/or MapLibre `minzoom`) so low zooms are basemap-only; pick concrete z after first load test (implementation detail).
6. **No filter query parameters** on tile URLs in v1 (metric toggle = client style on columns already in the tile).
7. **Local verification:** MapLibre or a tile debugger loads parcels over a city subset/full county; check tile size and pan performance.
8. **Proxy path** `/tiles/*` in local nginx (or equivalent) matching production shape.

### Exit criteria

- Stable tile URL pattern serving MVT for eligible parcels.
- Properties sufficient for color/3D metric toggle without extra tile requests.
- Acceptable performance at/above minzoom with simplification (tune tolerances as needed).

### C completion notes — tile source and measurements

`etl/sql/05_tiles.sql` defines `public.parcels_mvt(z, x, y)`, published by Martin as the single
source `parcels`. Tile URL: **`/tiles/parcels/{z}/{x}/{y}`**.

A **function** source rather than a table source, because the simplification tolerance has to
vary with `z` and a table source cannot see the zoom. Eligibility needs no restating: the
function selects from `parcels_map`, which *is* the rule.

#### Measured: minzoom is 13 (revised from 14 after a visual review)

Every tile covering the county, sized at both candidate zooms:

| Zoom | Tiles with data | Median | p99 | Max | Over 500 kB |
|---|---|---|---|---|---|
| z13 | 156 | 225 kB | — | **608 kB** | **12** |
| z14 | 598 | **53 kB** | 175 kB | **194 kB** | **0** |

**z14 proved too restrictive in use** — it allows no county-scale view at all. z13 was adopted
after dropping the unused `acres` tile property (the client reads acres from the drawer API,
never from a tile feature), which brings z13 to **median 213 kB, max 578 kB**. Acceptable.

**z12 was measured and rejected.** A z12 tile holds **30,758 parcels** and stays over **1 MB**
even with only one VPA property and 3x simplification. The only lever is an acreage filter, and
the cost is severe:

| Acres floor at z12 | Parcels kept | Tile |
|---|---|---|
| none | 100% | 1,030 kB |
| 0.15 | 55.7% | 581 kB |
| 0.25 | **21.1%** | 228 kB |
| 0.5 | 7.9% | 91 kB |

Reaching an acceptable tile size means dropping ~79% of parcels and emptying the suburbs — a
change to what the map *shows*, not a tuning decision. Left for a product call.

Geometry is only ~25% of a tile's bytes (at z13, 116 kB of 463 kB), so simplifying harder barely
helps: at 3x tolerance a z13 tile goes 263 kB → 261 kB. Feature count is the binding constraint.

Note the densest tile is **not** downtown: suburban subdivisions beat it, because downtown is
fewer, larger commercial parcels. Sampling the obvious spot would have picked the wrong number.

**Consequence:** at z13 a viewport shows roughly 14 miles across — about half the county.
Below that it is basemap only.

#### Payload optimisations (41% off a dense tile)

Measured at z13, 463 kB baseline:

| Change | Result |
|---|---|
| Round VPAs to whole dollars, acres to 2 dp | 356 kB (−23%) |
| Carry `parcel_id` as the MVT **feature id** instead of `taxpin` as a property | 274 kB (−41% total) |

MVT varint-encodes feature ids but stores string properties in a per-layer dictionary that
unique values defeat. Hence `parcels.parcel_id`, assigned deterministically by taxpin order so
the same source data always yields the same ids and CDN-cached tiles stay consistent. Clicks
resolve id → drawer; Section D should accept `parcel_id` as well as `taxpin`.

#### Three bugs the verification pass caught

1. **Martin was publishing everything.** `dev-up.sh` never passed `--config`, so auto-discovery
   put `stg_parcels` (raw staging, EPSG:2276) and the full `parcels` table — `situs` included —
   on a public tile endpoint. The launcher now passes `--config`, and the config publishes only
   `parcels_mvt`. Martin rejects `--config` alongside a positional connection string, so the
   connection moved into the config as `${DATABASE_URL}`.
2. **The proxy was discarding compression.** `dev-proxy.mjs` deleted `accept-encoding` for all
   routes, so Martin never gzipped: 54 kB over the wire against 37 kB. Tiles now pass it
   through; other routes keep the original behaviour.
3. **TileJSON advertised Martin's private address.** MapLibre would have read the TileJSON and
   then fetched tiles around the proxy. Fixed with `base_path: /tiles` plus forwarding the
   original `Host` header on the tile route, as nginx does in production.

#### Verified end to end

`/tiles/parcels` returns TileJSON with the correct same-origin template, bounds, minzoom 14 and
the TAD attribution (carried in the function's SQL comment, which Martin parses as TileJSON).
z13 returns 404, z14+ return `application/x-protobuf` with `content-encoding: gzip`. A fetched
z16 tile decoded with GDAL yields 115 features; feature id `43407` resolves to parcel
`14437-10-1A` with land VPA 2,457,432 and 0.09 acres, matching Postgres exactly — and carries no
`situs`, confirming the lean-property rule holds in the wire format.

Generation time from a warm cache: z14 24 ms, z15 26 ms, z16 13 ms.

#### Remaining in C

- **C.7 pan performance** needs a real MapLibre client, which arrives in Section E.
- CDN caching of `/tiles/*` is Section F.

### Dependency note for Section E

Frontend can start against **C** as soon as tiles exist for a bounding box; full county polish may continue in parallel.

---

## 6. Section D — Laravel APIs (drawer, comps, app shell)

**Depends on:** A, B  
**Goal:** Dynamic JSON for selection drawer (summary + 3 comps) and public app routes; no owner names; TAD footer content available to UI.

### Tasks (broad strokes)

1. **Laravel app skeleton** (if not already): routing, config for DB, cap/k/minzoom/stats, CORS only if not same-origin.
2. **Parcel show/drawer endpoint** e.g. `GET /api/parcels/{taxpin}`:
   - Summary: use/class, situs, city, acres, land/total/appraised VPA (and components if useful).
   - **Exclude owner name** (and any other deferred PII).
   - Embed or link **comps** (see below).
   - 404 if unknown / optionally if not map-eligible (product choice: still show non-map parcels via direct URL or not—default: by taxpin if present in curated table).
3. **Comp algorithm (server-side SQL):**
   - Subject: city \(C\), acres \(A\), land VPA \(V\) (comps use **land VPA** even if map metric is total/appraised, unless product later changes).
   - Tier 1: ≠ subject, map-eligible preferred, city = \(C\), acres ∈ \([0.5A, 2A]\); order by `ABS(land_vpa - V) DESC`; take up to 3.
   - Tier 2: drop city; keep acreage band; fill remaining slots.
   - Tier 3: drop acreage; fill remaining slots.
   - Always **limit 3** total; return enough fields for UI contrast (taxpin, city, acres, VPAs, use)—**no owner**.
4. **Map config endpoint (optional but useful):** countywide color min/max, `k`, `cap`, default metric/mode, OpenFreeMap style id—so the frontend does not hard-code deploy constants.
5. **Web routes for SPA/page shell** that will host MapLibre (Blade, Inertia, or API+static—implementation choice).
6. **Global license copy:** TAD informational disclaimer for footer (and optionally API `meta`).
7. **Basic error handling & logging** for missing taxpin, DB failures.
8. **Manual/feature tests** for comp tier fallback (subjects with sparse neighbors).

### Exit criteria

- Drawer JSON stable enough for frontend binding.
- Comp endpoint always returns up to 3 when any other eligible parcels exist; documents behavior when county is empty (dev only).

### Parallelism

- **D** does not wait on Martin once PostGIS is loaded.
- Drawer remains **dynamic** (not CDN-cached as a product requirement).

### D.3 completion notes — comps

`app/app/Actions/FindComparableParcels.php`, with `app/app/Models/Parcel.php` and
`app/tests/Feature/FindComparableParcelsTest.php` (9 tests, 23 assertions).

Implemented as a Laravel **action**, not raw SQL — but every tier still executes as one
indexed query in Postgres. Candidate filtering must not move into PHP collections: the
eligible set is ~674k rows and tier 3 is unbounded.

#### The locked ordering rule degenerated and was replaced

The spec ordered comps by `ABS(land_vpa - subject) DESC` ("drama"). Measured against the
loaded county, that rule collapses. Land VPA is heavily right-skewed (median $311k, max
$36M), so `|c - V|` is maximised by the **largest `c` in the band for virtually every
subject**, regardless of `V`. Ordering by distance-descending is therefore equivalent to
ordering by value-descending.

Observed: **40 random Fort Worth subjects produced only 8 distinct comp sets**, with one
parcel (`21630-45-1B`) appearing in 36 of them. The drawer was a static "top 3 in your
city" list — a coherent statement, but identical for everyone who clicked.

**Replacement (product decision): multiplier targets.** Each comp is the parcel nearest to
**0.25x, 4x and 16x** the subject's land VPA. Contrast is preserved — a quarter of yours,
four times, sixteen times — but the answer now moves with the subject.

| | Before | After |
|---|---|---|
| Distinct comp sets (40 random subjects) | 8 | **40** |
| Distinct parcels used | — | 108 |
| Most frequent comp | 36 of 40 | **5 of 40** |

Mid-range subjects hit their targets almost exactly (0.25x, 4.00x, 15.94x measured).

#### Displayed ratio is the actual one, never the target

A subject near the top of the county cannot reach 4x or 16x, and the nearest available
parcel may be well *below* it — the county-max parcel's comps come back at 0.20x, 0.46x and
0.50x. Labelling those "16x" would be a lie, so comps carry both `comp_target_multiple`
(provenance) and **`comp_ratio`** (actual, for display). Results are sorted by `land_vpa` so
the drawer reads as an escalation regardless of which targets were reachable.

#### Tier ladder unchanged

1. same city + acres in [0.5x, 2x] · 2. drop city, keep band · 3. drop acreage
Each target descends the ladder independently until it finds a parcel; already-chosen
parcels are excluded rather than duplicated. Verified: city `043` (13 source rows) falls to
tier 2 correctly.

#### Edge cases verified

| Subject | Result |
|---|---|
| County max / min land VPA | 3 comps, ratios all < 1 at the top |
| Largest (1,350 ac) / smallest (0.005 ac) parcel | 3 comps, tier 1 |
| Sparsest city (`043`) | 3 comps via **tier 2** |
| Ineligible $1 placeholder (direct URL) | 3 comps; never returns placeholders *as* comps |
| Unmatched parcel (`account_count = 0`) | **0 comps** — no land VPA to contrast |

#### Testing note

`parcels` is ETL-owned with no Laravel migrations, so there is no factory and the loaded
county *is* the fixture. The tests configure the `pgsql` connection explicitly (phpunit.xml
pins the suite to in-memory SQLite) and **skip** when Postgres is unreachable or empty, so
the suite still runs without a database. `TAD_DB_*` vars in `phpunit.xml` override the target.

### D.2 completion notes — drawer endpoint

| File | Role |
|---|---|
| `app/app/Http/Controllers/ParcelController.php` | `showByTaxpin` / `showById` |
| `app/app/Http/Resources/ParcelResource.php` | Drawer payload shape |
| `app/app/Http/Resources/ComparableParcelResource.php` | Comp shape |
| `app/tests/Feature/ParcelDrawerTest.php` | 9 contract tests |
| `app/tests/Concerns/UsesLoadedParcels.php` | Shared pgsql-or-skip setup |

**Routes.** `GET /api/parcels/{taxpin}` and `GET /api/parcels/id/{parcel_id}`. Both are
needed: a map click carries `parcel_id` (Section C moved the tile identifier to the integer
surrogate), while a shared link carries `taxpin`. Verified to return byte-identical payloads.

Taxpins are URL-safe as a path segment — 4–18 chars of letters, digits, hyphens and spaces
across the whole 2025 package, with **no slashes, dots or URL metacharacters**. 12,606
contain spaces (e.g. `A  85-8`) and work URL-encoded. The id route is declared first so it
cannot be swallowed by the taxpin route.

**Ineligible parcels resolve rather than 404** (spec D.2's default): a direct link to an
unmatched parcel or a nominal-value placeholder returns 200 with `map_eligible: false`.
Unmatched parcels come back with null values and zero comps. Only a genuinely absent taxpin
or id 404s.

`meta` carries the TAD licence from `config('map.license_footer')`, satisfying D.6 for the
API surface.

#### Comps performance: 108 ms → 0.1 ms per target

The first implementation ordered by `abs(land_vpa - target)`, which is not indexable.
Postgres used a **parallel sequential scan over 83,763 rows** — 108 ms per target, three
targets per drawer, ~325 ms of every request.

Rewritten to walk outward from the target in both directions (nearest `>=` and nearest `<=`,
then the closer of the two): two ordered index scans returning one row each. New indexes
`parcels_city_vpa_idx` and `parcels_vpa_idx` in `03_indexes.sql`.

| | Before | After |
|---|---|---|
| One target, tier 1 | 108 ms (seq scan) | **0.1 ms** (index scan) |
| Drawer request end to end | 200–490 ms | **~110 ms** |
| Test suite | 11.1 s | **1.3 s** |

#### A bug the first test suite missed

The rewrite silently returned the *farther* of the two sides — 4.83 from target instead of
4.49 — because a multi-criteria `Collection::sortBy()` with a closure criterion did not order
as expected. Every existing test still passed: the assertion was "within 25% of target", which
a merely-close match also satisfies.

Caught by diffing comps against the pre-optimisation output, then fixed by replacing the
`sortBy` with an explicit comparison. The guard is now
`each_comp_is_the_genuinely_nearest_parcel_to_its_target`, which asserts **optimality** —
nothing eligible in the same tier sits closer to the target — and was confirmed to fail on the
buggy selection before being committed. The lesson generalises: a tolerance assertion is not a
correctness assertion.

### D.4 completion notes — map config endpoint

`GET /api/map-config`, served by `app/app/Http/Controllers/MapConfigController.php`, with
`app/app/Models/MapStat.php` and 7 tests in `app/tests/Feature/MapConfigTest.php`.

Exists so the UI never hard-codes deploy constants. That is not hypothetical here: the cap
changed by three orders of magnitude in B.1, minzoom moved from a guessed 12 to a measured 14
in C.5, and the colour domain moved twice. A page with those baked in would have gone quietly
wrong each time.

#### `config/map.php` restructured

Scalar `vpa_cap` and `height_k` are gone, replaced by a per-metric map. Values are split by
kind, and handled differently:

| Kind | Examples | Source |
|---|---|---|
| **Product decisions** | caps, extrusion ceiling, defaults, bounds | `config/map.php` + env |
| **Measured** | colour domain (p5–p95) | **`map_stats`**, written by the ETL |

The endpoint reads the colour domain from `map_stats` at request time and falls back to config
only when the table is empty, reporting which was used via `color_domain_source`. This is what
stops a reload from leaving the ramp stale — the alternative, twelve `MAP_*_COLOR_*` env vars,
drifts silently the first time anyone reloads the data without editing `.env`.

**`k` is derived, never configured:** `k_metric = height_ceiling_m / cap_metric`. Configuring
it by hand is exactly how it drifts from the cap — with land at 1.5M and total at 6.5M, a
shared `k` would make total extrude 4.3x taller for the same parcel. A test asserts every
metric reaches the same ceiling.

New keys also cover what Section E needs and would otherwise invent: `tiles_layer` (the MVT
layer name set by `ST_AsMVT`), `parcel_maxzoom`, `bounds`, `center`, `tiles_source`.

`/api/health` previously echoed `height_k` and `vpa_cap`, which no longer exist. It now lists
metric names only — health is a liveness probe, not a second copy of the configuration.

#### Verified

All three metrics report `color_domain_source: map_stats`, `cap * k == 3000` exactly, and
over-cap shares of 1.25% / 1.01% / 0.98%. `app/public/tile-debug.html` now reads everything
from the endpoint — cap, colour domain, tile URL, basemap, bounds, licence — and has no
constants of its own. Clicking a parcel calls the D.2 drawer and renders situs, class, acres,
all three VPAs and the comps with their ratios, which exercises C, D.2, D.3 and D.4 together.

### D.5 / D.6 completion notes — page shell, deep links, licence

**Blade + Vite**, chosen over a CDN script tag or an SPA. The scaffold was already configured
for Vite; a CDN `<script>` is a third-party runtime dependency on a *public* map, which sits
badly beside the "no Mapbox product path" constraint; and Vite gives content-hashed filenames,
which matter once Section F puts a CDN in front of the origin. v1 needs one page with no
client routing, so this is a single Blade view, not an app framework.

| File | Role |
|---|---|
| `app/resources/views/layouts/app.blade.php` | Document + licence footer |
| `app/resources/views/map.blade.php` | Map container, deep-link data attribute |
| `app/resources/js/map.js` | Map, chrome, drawer, comps, 2D/3D |
| `app/resources/js/app.js` | Entry point, boot error surface |
| `app/routes/web.php` | `/` and `/parcels/{taxpin}` |
| `app/tests/Feature/PageShellTest.php` | 8 tests |

**MapLibre 6.10** — note v6 **removed the default export**; `import maplibregl from 'maplibre-gl'`
fails to build. Named imports only. Bundle is 1.03 MB raw / 278 kB gzipped, almost entirely
MapLibre.

**The page injects no deploy constants.** Everything comes from `/api/map-config` at runtime, so
one source serves every consumer and a data reload moves the colour domain without a rebuild. A
test asserts the HTML contains no cap or colour values.

#### Deep links

`GET /parcels/{taxpin}` serves the same shell with `data-initial-parcel`; the client fetches the
drawer, jumps to the parcel's centre and selects it. Selection updates the URL via
`history.replaceState`, so any parcel is shareable. Unknown taxpins **404 server-side** rather
than rendering an empty map. Ineligible parcels resolve, consistent with the drawer API.

This required a small backend addition: the drawer had no coordinates, so nothing could fly to a
parcel. `Parcel::withCenter()` adds `lon`/`lat` via **`ST_PointOnSurface`** — not `ST_Centroid`,
which can fall outside a concave or multi-part parcel and put the marker in a neighbour's yard.
Comps carry it too, so a comp is clickable to fly to (spec E.9, arriving early).

**D.6 is now complete:** the TAD disclaimer renders in the page footer from
`config('map.license_footer')`, the same source the API `meta` uses.

#### A same-origin bug, second of its kind

`@vite` rendered asset URLs as `http://127.0.0.1:8000/build/...` — Laravel's own port, not the
proxy. Laravel builds absolute URLs from the **request Host**, and `dev-proxy.mjs` was rewriting
Host to the upstream for the Laravel route. Locally it worked by accident; behind a real origin
it would advertise a private port.

This is the same fault as Martin's TileJSON in Section C, which is why host-forwarding is now
the proxy's default for **all** routes rather than an opt-in for tiles, matching nginx's
`proxy_set_header Host $host`. Worth watching for a third instance: any upstream that builds
absolute URLs is exposed to it.

#### Build note for Section F

`app/public/build` is **gitignored**, so production must run `npm ci && npm run build` during
deploy — the built assets are not in the repository. `dev-up.sh` now prints the rebuild command,
since editing `resources/js` without rebuilding silently serves stale JS.

`app/public/tile-debug.html` is now superseded by the real shell. It is still useful as a
minimal reference, but it should be **deleted before the public deploy** in Section F.

#### Three bugs that only a browser could find

The page served HTTP 200, every endpoint it called returned correct data, all 36 tests passed —
and it rendered **completely blank, with no console error**. Worth recording because none of
these are visible from curl or PHPUnit.

**1. Tailwind's cascade layers lost to MapLibre's stylesheet.** `#map` carried
`class="absolute inset-0"` but computed to `position: relative`, so `inset-0` stopped
controlling height and the container collapsed to 0px. Cause: MapLibre ships **unlayered** CSS
(`.maplibregl-map { position: relative }`), Tailwind 4 puts utilities in `@layer`, and
**unlayered CSS beats layered CSS regardless of specificity or source order**. Fixed by
importing MapLibre's stylesheet into a low-priority layer:

```css
@layer maplibre;                                              /* declared first = lowest */
@import 'tailwindcss';
@import 'maplibre-gl/dist/maplibre-gl.css' layer(maplibre);
```

**2. MapLibre's web worker was never emitted by the build.** v6 resolves it at *runtime* by
concatenating onto `import.meta.url` — `new URL('./maplibre-gl-worker.mjs', import.meta.url)` —
which no bundler can analyse statically. Vite emitted no chunk, the request 404'd, and without
a worker MapLibre parses no tiles and never fires `load`. A `maplibreWorkerAssets()` plugin in
`vite.config.js` emits `maplibre-gl-worker.mjs` and its dependency `maplibre-gl-shared.mjs` with
exact unhashed names. **Any bundler upgrade should re-check this**; it fails silently.

**3. `MAP_HEIGHT_CEILING_M = 3000` was ~10x too tall.** Derived correctly from the caps, never
seen rendered. A $609k/ac parcel extruded to 1,219 m on a ~40 m lot: the 3D view was vertical
walls running off screen, not buildings. **Now 300 m**, which reads as a city block. This was
the last constant nobody had looked at.

#### Visual verification

Confirmed in Chrome at z15 over downtown Fort Worth: basemap plus parcels, legend fed from
`map_stats`, metric toggle repainting with no refetch, click selecting a parcel and filling the
drawer (`555 ELM ST`, all three VPAs, comps at 0.25x / 4x / 6.27x), URL updating to
`/parcels/27825---04`, and 3D extrusion reading as city blocks.

#### Open product question raised by seeing it

**Downtown is a solid black mass.** The 1.25% of parcels over the $1.5M/acre land cap are not
scattered — they are concentrated in exactly the area a visitor looks at first, so the densest,
most valuable land renders as undifferentiated black. The cap is statistically defensible (p99)
and visually the worst possible choice for the map's own thesis. Options: raise the land cap,
switch the ramp to log scale, or reserve black for a much rarer extreme. Needs a product
decision in Section G.

### Post-review revisions

Three changes after looking at the running map.

**Minzoom 14 → 13.** See the revised C.5 notes: z14 allowed no county-scale view. z12 remains
out of reach without dropping ~79% of parcels. The unused `acres` tile property was removed at
the same time (~6% off every tile, at every zoom).

**Comps carry an address and dollar values.** A comp rendered as a bare `$46,449/ac` is an
anonymous number; it now leads with its situs (`2929 MECCA ST`) and carries `values` alongside
`vpa`. Tests assert the per-acre figure agrees with the dollar figure it is displayed beside.

**The drawer shows value and per-acre side by side.** Per-acre is the map's metric, but the
appraised dollar figure is what a reader recognises, so the drawer now renders a
Metric / Value / Per acre table for land, total and appraised.

#### Two environment findings

**`php artisan serve` is single-worker.** PHP's built-in server serialises requests, which is
fine for JSON but not for a ~1 MB bundle plus MapLibre's 513 kB worker dependency plus a stream
of tiles. `dev-up.sh` now sets `PHP_CLI_SERVER_WORKERS=8`.

**MapLibre renders in `requestAnimationFrame`, which Chrome throttles in unfocused tabs.** A
backgrounded tab loads the style, fetches the worker, and then renders nothing and requests no
tiles — indistinguishable from a hang, with no console error. This cost real debugging time
during the review: the map was working and the tab simply was not focused. When a map looks
dead, **focus the tab before investigating**.

### D.7 completion notes — error handling and logging

`app/bootstrap/app.php`, with 5 tests in `app/tests/Feature/ApiErrorHandlingTest.php`.

**The API gained a stable error envelope** — `{"error": {"status", "message"}}` — because it is
public and the frontend binds to it. Laravel's default 404 body leaked the absolute controller
path and a full stack trace; a test now asserts no response contains `base_path()`, `/home/`,
`"trace"` or `vendor/laravel`, **with `APP_DEBUG` on**, which is the harder case. Debug detail is
still available under a separate `debug` key when debug is enabled, so it never mixes with the
contract.

**A database outage answers 503, not 500.** `QueryException` on an `api/*` route is logged at
`error` with the path and SQL state, and returns "The parcel database is unavailable." This lets
monitoring distinguish the map being down from a code bug, and keeps DB outages out of the 5xx
bucket that usually means a regression.

**Unknown parcels log at `info`, not `warning`.** With deep links in circulation a 404 is
expected traffic; the value of the record is spotting links that went stale after a reload.

HTML routes are untouched — a browser hitting a bad deep link still gets Laravel's own 404 page,
asserted by test.

### Post-review revision — caps raised

The p99 caps were statistically defensible and visually wrong: over-cap parcels are not
scattered, they are downtown. **Caps moved to roughly p99.95.**

| Metric | Cap before | Cap after | Downtown black | Countywide over cap |
|---|---|---|---|---|
| land | 1,500,000 | **5,000,000** | 49.2% → **1.1%** | 143 (0.02%) |
| total | 6,500,000 | **20,000,000** | 22.7% → **9.1%** | 306 (0.05%) |
| appraised | 6,500,000 | **20,000,000** | 22.5% → **9.0%** | 288 (0.04%) |

`height_ceiling_m` rose 300 m → **1000 m** at the same time: `k` is derived as `ceiling / cap`,
so tripling the cap would have flattened every ordinary parcel by the same factor. The new ratio
keeps a typical downtown parcel at the height that was checked visually.

**The remaining limit is the colour ramp, not the cap.** The domain is p5–p95
(land 71,981–807,925) while downtown's *median* land VPA is 1,383,273 — above the top of the
ramp. Downtown therefore still renders as one dark mass rather than a black one: better, because
black read as "excluded", but still undifferentiated. Fixing it properly means either extending
the domain (which washes out the other 95% of the county, median 311,356) or moving to a **log
scale**, which the skew argues for: on a log ramp from 72k to 5M the county median sits at ~34%
and downtown's median at ~70%, so both differentiate. Deferred to Section G as a product call.

---

## 7. Section E — MapLibre frontend

**Depends on:** C (tiles), D (drawer API); A for serving the page  
**Goal:** Public interactive map with dual mode, metric toggle, selection drawer, license footer.

### Tasks (broad strokes)

1. **Map bootstrap:** MapLibre map, **OpenFreeMap** basemap style, Tarrant-centered initial view/bounds.
2. **Parcel vector source:** Martin tile URL (same-origin `/tiles/...` in prod shape).
3. **Default style:** **fill** layer, data-driven color from **`land_vpa`**, **countywide** continuous (or stepped) ramp using fixed min/max from config/stats.
4. **Metric toggle:** land / total / appraised — switch MapLibre paint property to the corresponding tile attribute (no new tile fetch).
5. **Mode toggle (dual):**
   - **Color (default):** fill layer visible.
   - **3D:** `fill-extrusion` (pitch/bearing UX); height = `min(vpa, cap_metric) * k_metric`; features with VPA **> cap** use **black** color; true VPA in drawer only. See 10.2 for the per-metric constants.
6. **Apply over-cap black in 2D as well** (recommended consistency)—implement unless deliberately mode-specific.
7. **Layer minzoom:** hide parcels below agreed minzoom (coordinate with C).
8. **Click interaction:** `queryRenderedFeatures` → read `taxpin` → fetch drawer API → **selection drawer** UI (summary + 3 comps).
9. **Drawer UX:** loading/error states; comps clickable to fly-to / select comp parcel (nice-to-have in same section or G).
10. **Chrome:** metric control, mode control, legend optional (not required; if present, simple continuous $/acre bar—not quantile bins).
11. **Footer:** TAD license / informational-use notice.
12. **No turf.js**, no draw/AOI, no owner/address search in v1.

### Exit criteria

- User can pan/zoom (above minzoom), toggle metric and 2D/3D, click parcel, see drawer with 3 comps, see footer.
- Excluded parcels never appear; over-cap parcels read as black with capped height in 3D.

### E completion notes

**Section E was delivered incidentally while building the D.5 shell** — the page that hosts
MapLibre and the map itself were not worth separating for one page. All twelve tasks are done
and verified in Chrome; see the D.5 notes for the files.

| Task | Status |
|---|---|
| 1 Map bootstrap, OpenFreeMap, Tarrant bounds | Done (`view.center` / `view.bounds` from D.4) |
| 2 Parcel vector source, same-origin `/tiles/*` | Done |
| 3 Default fill, data-driven from `land_vpa`, countywide ramp | Done (p5–p95 from `map_stats`) |
| 4 Metric toggle without refetch | Done — paint-property change only |
| 5 3D mode, `min(vpa, cap) * k`, black over cap | Done (ceiling 300 m) |
| 6 Over-cap black in 2D as well | Done |
| 7 Layer minzoom | Done (13) |
| 8 Click → drawer | Done, via `parcel_id` rather than `taxpin` (C.2) |
| 9 Drawer loading/error states, comps fly-to | Done |
| 10 Chrome: metric, mode, legend | Done |
| 11 TAD footer | Done (D.6) |
| 12 No turf.js / AOI / owner search | Held |

**C.7 (pan performance) is satisfied** by the same work: tiles render and pan at z13–17 against
the full county.

Two items deliberately left open, both product decisions rather than implementation:

- **Downtown renders as a solid black mass** (see D.5 notes). The most valuable land in the
  county is undifferentiated — the cap is statistically right and visually wrong.
- **z12 is unreachable** without dropping ~79% of parcels (see C notes).

---

## 8. Section F — Production deploy & CDN

**Depends on:** C, D, E at MVP level; A for infra patterns  
**Goal:** Single GCE VM public deployment with HTTPS and cached tiles.

### Tasks (broad strokes)

1. **Provision GCE VM** sized for PostGIS + Martin + Laravel + nginx on one box (start modest; disk for DB).
2. **Install/run:** PostgreSQL/PostGIS, Martin, PHP-FPM/Laravel, nginx.
3. **Load production database** via documented ETL from B (one-shot).
4. **TLS** (e.g. managed cert or Caddy/nginx ACME).
5. **Reverse proxy:**
   - `/` → Laravel public UI  
   - `/api/*` → Laravel  
   - `/tiles/*` → Martin  
6. **Cloud CDN** in front of tile paths (and optionally static assets): long cache TTL while data is immutable; cache key = full URL (no filter params).
7. **Cache invalidation strategy (manual):** path version prefix (`/tiles/v1/...`) or CDN purge when DB reloaded later.
8. **Env/config:** production OpenFreeMap URL, Martin, DB, `k`/`cap`/color domain.
9. **Smoke tests** from public URL: tiles, drawer, HTTPS, footer.
10. **Basic monitoring/backups** (disk, Postgres dump)—lightweight for v1.

### Exit criteria

- Public URL serves map without Mapbox accounts/keys for basemap or tiles.
- Tile hits largely served from CDN after warmup; drawer always hits origin.

---

## 9. Section G — Hardening & polish

**Depends on:** E (primarily); benefits from F  
**Goal:** Performance, clarity, and operational sanity without expanding scope.

### Tasks (broad strokes)

1. **Tune** simplify tolerances and **minzoom** after full-county use.
2. **Tune `k` and `cap`** for legible 3D (product already expects later adjustment).
3. **Index review** from slow query logs (comps, identify).
4. **Drawer/comp UX polish** (fly-to comps, empty states, mobile drawer).
5. **Accessibility/perf basics:** reduce motion option?, label contrast on footer controls.
6. **Security basics for public app:** rate limit drawer API lightly; no sensitive PII; dependency updates.
7. **Document runbooks:** reload data, restart services, purge CDN.
8. **Optional backlog (explicitly not v1 unless pulled in):** aggregate layers, tile filter params, yearly refresh job, owner fields behind auth, quantile legends, AOI analysis.

### Exit criteria

- Team can operate and lightly tune the system; known backlog is written down.

---

## 10. Cross-cutting specifications (reference for all sections)

### 10.1 Lean tile properties vs drawer fields

| Concern | Tiles (Martin) | Drawer API (Laravel) |
|---------|----------------|----------------------|
| Identity | `taxpin` | `taxpin` |
| Metrics | `land_vpa`, `total_vpa`, `appraised_vpa` | Same + optional raw value components |
| Size | optional `acres` | `acres` |
| Use / situs / city | avoid if possible | yes |
| Owner | **never** | **never** (v1) |
| Comps | no | **3 comps** |
| Caching | CDN | dynamic |

### 10.2 Height / color encoding

```text
selected_vpa ∈ { land_vpa, total_vpa, appraised_vpa }

height_display = min(selected_vpa, cap_metric) * k_metric

  metric      cap          k          max height
  land        1_500_000    1/500      3_000 m
  total       6_500_000    1/2167     3_000 m
  appraised   6_500_000    1/2167     3_000 m

  caps ≈ the measured p99 per metric (B.1); k chosen so every metric
  tops out at the same 3,000 m ceiling, keeping the toggle comparable

if selected_vpa > cap → color = black
else → countywide ramp(selected_vpa)

drawer always shows true selected_vpa (and all metrics as designed)
```

### 10.3 Comp selection (summary)

1. Filter: similar acres \([0.5×, 2×]\), same city → sort \|Δ land VPA\| **DESC** → take up to 3.  
2. If &lt; 3: drop city, keep acres band.  
3. If &lt; 3: drop acres band.  
4. Cap at 3.

### 10.4 Eligibility (map)

Exclude from Martin source: parcels with unusable null/zero VPA per agreed rules (at least the metrics required to paint); parcels below the **0.005-acre floor**; parcels with no matched account. Exempt filtering is **not** applied — see B.1.

### 10.5 CRS

| Asset | CRS / rule |
|-------|------------|
| Stored `geom` | EPSG:4326 |
| `acres`, VPAs | Precomputed in ETL; not from 4326 area |
| Source package | EPSG:2276 for understanding area; convert before/during load |
| Acres source | `CALCULATED_ACREAGE`, falling back to summed `Land_Acres`, then unioned `Shape_Area`/43560 for deduped parcels |

---

## 11. Suggested implementation order (checklist view)

| Phase | Sections | Outcome |
|-------|----------|---------|
| 1 | A | Local stack runs |
| 2 | B | PostGIS filled & validated |
| 3 | C ∥ D | Tiles + drawer APIs |
| 4 | E | Usable public UI locally |
| 5 | F | Live on GCE + CDN |
| 6 | G | Tuned & operable |

---

## 12. Explicit non-goals (v1)

- Mapbox Tiling Service / Mapbox-hosted basemap (cost/vendor path)
- turf.js
- AOI draw / polygon aggregate tools
- Fuzzy owner or address search
- Quantile break legend as a requirement
- Zip/census tract (or other) aggregate tile layers
- Automated annual TAD refresh
- Authentication / private map
- Owner name on any public surface

---

## 13. Open implementation knobs (not product forks)

Set during C/E/G with measurement, not a new design debate:

| Knob | Guidance |
|------|----------|
| Exact parcel **minzoom** | Likely ~11–13 after full-county tile test |
| Simplify tolerance schedule by z | Start conservative; increase if tiles huge |
| Countywide color min/max source | ETL `map_stats` or config export |
| Over-cap black in 2D | Default **yes** |
| Comp fly-to | Polish in E or G |
| VM size / disk | Grow with PostGIS footprint |

---

## 14. Document control

| Item | Value |
|------|--------|
| Source design | Conversation freeze + `VALUE_PER_ACRE_WEBAPP.md` data semantics |
| Spec purpose | Task breakdown + dependencies for implementation |
| Next step after this doc | Execute Section A, then B; parallelize C and D |

---

*End of spec.*

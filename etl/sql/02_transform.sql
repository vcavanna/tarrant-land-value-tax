-- B.3–B.6 — staging → curated parcels.
--
-- Reads stg_parcels / stg_property (loaded by ogr2ogr, still in EPSG:2276) and
-- produces the parcels table. Order matters: acres are finalised in 2276, and
-- only then is geometry reprojected to 4326.
--
-- Two intermediate tables are kept (not TEMP) so a load can be inspected after
-- the fact: etl_parcel_geom, etl_account_agg.

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Parcel geometry: normalise keys, repair validity, dedupe TAXPIN
-- ---------------------------------------------------------------------------
-- B.1 Decision 4: 16 blank TAXPINs are discarded (all degenerate — null acreage,
-- mostly zero area, none joinable). 16 rows across 7 keys are duplicated, and
-- they are three different problems at once: exact duplicates, real polygons
-- paired with degenerate slivers, and genuine multi-part parcels. MAX(acres)
-- truncates the multi-parts; SUM(acres) triple-counts the sliver cases. Union
-- the geometry and take acres from the unioned area, which is correct for all
-- three (dupes collapse, slivers absorb, parts sum).

DROP TABLE IF EXISTS etl_parcel_geom;

CREATE TABLE etl_parcel_geom AS
WITH norm AS (
    SELECT
        nullif(btrim(taxpin), '')  AS taxpin,
        -- Invalid input would fail ST_UnaryUnion here and ST_Simplify later in
        -- the tile query; repair only what needs it.
        CASE
            WHEN ST_IsValid(geom) THEN geom
            ELSE ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
        END                        AS geom,
        calculated_acreage
    FROM stg_parcels
    WHERE nullif(btrim(taxpin), '') IS NOT NULL
      AND geom IS NOT NULL
),
counts AS (
    SELECT taxpin, count(*) AS n FROM norm GROUP BY taxpin
),
singles AS (
    SELECT
        n.taxpin,
        1::integer                    AS part_count,
        n.geom                        AS geom_2276,
        n.calculated_acreage::numeric AS acres_calc
    FROM norm n
    JOIN counts c USING (taxpin)
    WHERE c.n = 1
),
dupes AS (
    SELECT
        n.taxpin,
        count(*)::integer AS part_count,
        ST_Multi(ST_UnaryUnion(ST_Collect(n.geom)))                     AS geom_2276,
        (ST_Area(ST_UnaryUnion(ST_Collect(n.geom))) / 43560.0)::numeric AS acres_calc
    FROM norm n
    JOIN counts c USING (taxpin)
    WHERE c.n > 1
    GROUP BY n.taxpin
)
SELECT * FROM singles
UNION ALL
SELECT * FROM dupes;

ALTER TABLE etl_parcel_geom ADD PRIMARY KEY (taxpin);

-- ---------------------------------------------------------------------------
-- 2. Account roll-up: sum values once per account, pick descriptors once
-- ---------------------------------------------------------------------------
-- Values sum across accounts; acres do NOT (they would double-count the same
-- land). Descriptors come from the largest-value account, which resolves the
-- 428 multi-account parcels whose accounts disagree about City — comps group on
-- city_code, so an arbitrary pick would scatter them.

DROP TABLE IF EXISTS etl_account_agg;

CREATE TABLE etl_account_agg AS
WITH cast_rows AS (
    SELECT
        nullif(btrim(gis_link), '')   AS taxpin,
        nullif(btrim(account_nu), '') AS account_nu,
        etl_num(land_value)           AS land_value,
        etl_num(improvemen)           AS improvement_value,
        etl_num(total_valu)           AS total_value,
        etl_num(appraised_)           AS appraised_value,
        etl_num(land_acres)           AS land_acres,
        nullif(btrim(property_c), '') AS property_class,
        nullif(btrim(state_use_), '') AS state_use,
        nullif(btrim(city), '')       AS city_code,
        nullif(btrim(situs_addr), '') AS situs
    FROM stg_property
    WHERE nullif(btrim(gis_link), '') IS NOT NULL
),
ranked AS (
    SELECT
        cast_rows.*,
        row_number() OVER (
            PARTITION BY taxpin
            ORDER BY coalesce(total_value, 0) DESC, account_nu
        ) AS rn
    FROM cast_rows
)
SELECT
    taxpin,
    count(*)::integer      AS account_count,
    sum(land_value)        AS land_value,
    sum(improvement_value) AS improvement_value,
    sum(total_value)       AS total_value,
    sum(appraised_value)   AS appraised_value,
    -- Kept only as an acres fallback; never added to the parcel's own acreage.
    sum(land_acres)        AS land_acres_sum,
    min(property_class) FILTER (WHERE rn = 1) AS property_class,
    min(state_use)      FILTER (WHERE rn = 1) AS state_use,
    min(city_code)      FILTER (WHERE rn = 1) AS city_code,
    min(situs)          FILTER (WHERE rn = 1) AS situs
FROM ranked
GROUP BY taxpin;

ALTER TABLE etl_account_agg ADD PRIMARY KEY (taxpin);

-- ---------------------------------------------------------------------------
-- 3. Curated parcels: resolve acres, compute VPAs, reproject last
-- ---------------------------------------------------------------------------
-- Acres precedence (B.1): CALCULATED_ACREAGE is usable on 99.67% of parcels;
-- the summed Land_Acres fallback rescues 2,201 of the 2,262 that fail; raw
-- geometry area is the last resort.

INSERT INTO parcels (
    taxpin, parcel_id, geom, acres, acres_source, part_count, account_count,
    land_value, improvement_value, total_value, appraised_value,
    land_vpa, total_vpa, appraised_vpa,
    property_class, state_use, city_code, situs
)
SELECT
    g.taxpin,
    -- Ordered by taxpin, so the assignment is a pure function of the source set.
    row_number() OVER (ORDER BY g.taxpin),
    ST_Multi(ST_Transform(g.geom_2276, 4326))::geometry(MultiPolygon, 4326),
    r.acres,
    r.acres_source,
    g.part_count,
    coalesce(a.account_count, 0),
    a.land_value,
    a.improvement_value,
    a.total_value,
    a.appraised_value,
    round(a.land_value       / r.acres, 2),
    round(a.total_value      / r.acres, 2),
    round(a.appraised_value  / r.acres, 2),
    a.property_class,
    a.state_use,
    a.city_code,
    a.situs
FROM etl_parcel_geom g
LEFT JOIN etl_account_agg a USING (taxpin)
CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN g.acres_calc > 0      THEN g.acres_calc
            WHEN a.land_acres_sum > 0  THEN a.land_acres_sum
            ELSE nullif(ST_Area(g.geom_2276) / 43560.0, 0)::numeric
        END AS acres,
        CASE
            WHEN g.acres_calc > 0      THEN 'calculated'
            WHEN a.land_acres_sum > 0  THEN 'land_acres'
            ELSE 'geometry'
        END AS acres_source
) r;

ANALYZE parcels;

COMMIT;

\echo '02_transform: parcels populated'
SELECT
    count(*)                                        AS parcels,
    count(*) FILTER (WHERE account_count = 0)       AS unmatched,
    count(*) FILTER (WHERE part_count > 1)          AS deduped,
    count(*) FILTER (WHERE acres_source <> 'calculated') AS acres_fallback
FROM parcels;

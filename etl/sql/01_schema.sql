-- B.2 — curated target schema for the value-per-acre map.
--
-- Staging tables (stg_parcels, stg_property) are created by ogr2ogr in
-- etl/scripts/load-parcels.sh; this file owns everything downstream of them.
--
-- Run order: 01_schema → 02_transform → 03_indexes → 04_stats → 99_validate
-- Safe to re-run: every object is dropped and recreated.

\set ON_ERROR_STOP on

BEGIN;

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------------
-- Numeric casting helper
-- ---------------------------------------------------------------------------
-- TAD ships every value field as text. B.1 found zero unparseable values in the
-- 2025 package, but a refresh could introduce them, so bad input yields NULL
-- rather than aborting a six-figure-row load.

CREATE OR REPLACE FUNCTION etl_num(t text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE WHEN v ~ '^-?[0-9]+(\.[0-9]+)?$' THEN v::numeric END
  FROM (SELECT nullif(btrim(translate(t, '$, ', '')), '') AS v) s;
$$;

COMMENT ON FUNCTION etl_num(text) IS
  'Cast a TAD text value field to numeric; strips $ , and whitespace, NULL on failure.';

-- ---------------------------------------------------------------------------
-- Curated parcels — one row per taxpin
-- ---------------------------------------------------------------------------
-- Grain: parcel, after account aggregation (B.1: 98.51% of parcels carry exactly
-- one account; max observed is 494). Unmatched parcels are retained with NULL
-- values so a direct drawer lookup by taxpin still resolves; they are excluded
-- from parcels_map and therefore never reach a tile.
--
-- No exempt column: B.1 established EXEMPTSTATUS carries no usable signal.

DROP VIEW  IF EXISTS parcels_map;
DROP TABLE IF EXISTS parcels;

CREATE TABLE parcels (
    taxpin              text PRIMARY KEY,

    -- Compact surrogate for the MVT feature id. A tile carries this instead of
    -- the taxpin string: MVT varint-encodes feature ids, and measurement showed
    -- the string property costs ~41% of a dense tile (C.2). Assigned
    -- deterministically by taxpin order in 02_transform, so the same source data
    -- always yields the same ids and CDN-cached tiles stay consistent.
    parcel_id           bigint NOT NULL,

    -- Geometry stored in 4326; acres are NEVER derived from this column.
    geom                geometry(MultiPolygon, 4326) NOT NULL,

    -- Resolved denominator: CALCULATED_ACREAGE → summed Land_Acres → unioned
    -- Shape_Area/43560. See acres_source for which one won.
    acres               numeric,
    acres_source        text,
    part_count          integer NOT NULL DEFAULT 1,

    -- Account roll-up. 0 = parcel has no matching PropertyData row (B.1: 3,783).
    account_count       integer NOT NULL DEFAULT 0,

    -- Value components, summed once per account.
    land_value          numeric,
    improvement_value   numeric,
    total_value         numeric,
    appraised_value     numeric,

    -- Precomputed metrics. Tiles and APIs read these; nothing recomputes them.
    land_vpa            numeric,
    total_vpa           numeric,
    appraised_vpa       numeric,

    -- Descriptors, taken from the largest-value account on multi-account parcels.
    property_class      text,
    state_use           text,
    city_code           text,   -- raw TAD code (e.g. '026'); no lookup table in v1
    situs               text,

    -- Eligibility is stored, not just expressed in the view, so the drawer and
    -- comps queries (Section D) can filter on it without restating the rule.
    map_eligible        boolean GENERATED ALWAYS AS (
                            coalesce(
                                account_count > 0
                                AND acres >= 0.005
                                AND land_vpa > 0
                                AND land_value > 1000,
                                false
                            )
                        ) STORED,

    CONSTRAINT parcels_acres_nonneg CHECK (acres IS NULL OR acres >= 0)
);

COMMENT ON TABLE  parcels IS 'Curated parcel grain: geometry + precomputed acres/VPAs + drawer attributes.';
COMMENT ON COLUMN parcels.acres_source IS 'calculated | land_acres | geometry — which denominator was used.';
COMMENT ON COLUMN parcels.part_count IS 'Source rows unioned into this parcel; >1 only for the 7 duplicated TAXPINs (B.1).';
COMMENT ON COLUMN parcels.map_eligible IS 'Spec 10.4 eligibility, stored: joined + above the acres floor + paintable land VPA.';
COMMENT ON COLUMN parcels.city_code IS 'Raw TAD numeric city code. Display label needs TAD''s code table (deferred).';

-- ---------------------------------------------------------------------------
-- Map eligibility — the layer Martin publishes
-- ---------------------------------------------------------------------------
-- Rules (spec 10.4, as revised by B.1):
--   * must join to at least one account
--   * acres >= the 0.005 floor  (below that VPA is an artifact, not a value)
--   * land_vpa > 0              (the default paint metric must be paintable)
--   * land_value > 1000         (excludes TAD's nominal placeholders, see below)
-- No exempt filter.
--
-- The land_value floor removes ~10,332 parcels TAD carries at a nominal value
-- rather than a real one: 8,128 at exactly $1, 799 at exactly $100. They are
-- overwhelmingly class C1 (vacant residential lots, HOA common areas, drainage
-- easements) plus some public utility land. Measured land VPA jumps from $18 at
-- p1 to $9,858 at p2, so $1000 sits inside that cliff and cuts placeholders
-- without touching real land.
--
-- This matters most for comps: the spec orders them by ABS(land_vpa - subject)
-- DESC, which actively selects placeholders as the "most different" neighbours.
-- Filtering here fixes paint and comps in one place.

CREATE VIEW parcels_map AS
SELECT
    parcel_id,
    taxpin,
    geom,
    acres,
    land_vpa,
    total_vpa,
    appraised_vpa
FROM parcels
WHERE map_eligible;

COMMENT ON VIEW parcels_map IS 'Map-eligible parcels, lean property set. Source of truth for Martin tiles.';

-- ---------------------------------------------------------------------------
-- Style statistics — one row per metric
-- ---------------------------------------------------------------------------
-- Populated by 04_stats.sql, exported into MAP_* config. cap/k come from the
-- B.1 decisions: caps near the measured p99, k chosen so every metric tops out
-- at the same 3,000 m extrusion ceiling.

DROP TABLE IF EXISTS map_stats;

CREATE TABLE map_stats (
    metric          text PRIMARY KEY,   -- land | total | appraised
    eligible_count  bigint  NOT NULL,
    min_vpa         numeric,
    p5_vpa          numeric,
    p50_vpa         numeric,
    p95_vpa         numeric,
    p99_vpa         numeric,
    max_vpa         numeric,
    cap             numeric NOT NULL,
    k               numeric NOT NULL,
    over_cap_count  bigint  NOT NULL,
    computed_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  map_stats IS 'Countywide VPA distribution per metric; feeds MAP_COLOR_MIN/MAX and cap/k config.';
COMMENT ON COLUMN map_stats.k IS 'Extrusion scale: height = min(vpa, cap) * k. Set so cap * k = 3000 m for every metric.';

COMMIT;

\echo '01_schema: parcels, parcels_map, map_stats, etl_num() ready'

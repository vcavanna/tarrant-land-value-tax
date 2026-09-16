-- B.8 — indexes. Deliberately minimal; add more only when a query plan asks.

\set ON_ERROR_STOP on

-- Tile bbox lookups (Martin) — the one index the map cannot work without.
CREATE INDEX IF NOT EXISTS parcels_geom_gix ON parcels USING GIST (geom);

-- Comps tier 1: same city, acres in [0.5A, 2A]. Leading city_code narrows to
-- one of 43 buckets, acres serves the band scan.
CREATE INDEX IF NOT EXISTS parcels_city_acres_idx
    ON parcels (city_code, acres) WHERE map_eligible;

-- Comps look for the parcel NEAREST a target land VPA. Ordering by
-- abs(land_vpa - target) cannot use an index, so the action walks outward from
-- the target in both directions instead; these serve that walk. Measured effect
-- on one target: 108 ms parallel seq scan over 83,763 rows -> 0.1 ms index scan.
CREATE INDEX IF NOT EXISTS parcels_city_vpa_idx
    ON parcels (city_code, land_vpa) WHERE map_eligible;   -- tier 1
CREATE INDEX IF NOT EXISTS parcels_vpa_idx
    ON parcels (land_vpa) WHERE map_eligible;              -- tiers 2 and 3

-- Drawer lookups arrive as a feature id from the tile, not as a taxpin.
CREATE UNIQUE INDEX IF NOT EXISTS parcels_parcel_id_idx ON parcels (parcel_id);

-- taxpin lookups (drawer, direct URL) ride the primary key.

ANALYZE parcels;

\echo '03_indexes: geom GIST + (city_code, acres) created'

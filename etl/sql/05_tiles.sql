-- C.1–C.4 — the Martin tile source.
--
-- Martin auto-publishes any function shaped (z integer, x integer, y integer)
-- returning bytea, exposing it at /tiles/<function_name>/{z}/{x}/{y}. A function
-- is used rather than a plain table source because the simplification tolerance
-- has to vary with z, and a table source has no way to see the zoom.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Tolerance schedule (C.3)
-- ---------------------------------------------------------------------------
-- A tile is 4096 grid units wide regardless of zoom, but covers a different
-- amount of ground at each zoom: the world is 40,075,016.7 m across at the
-- equator, so one tile spans 40075016.7 / 2^z metres and one grid unit is that
-- divided by 4096.
--
-- Simplifying by roughly one grid unit removes detail finer than the tile can
-- represent anyway — invisible, but it drops vertex counts hard. The multiplier
-- trades crispness for bytes; 1.0 is sub-pixel, higher gets visibly ragged.

CREATE OR REPLACE FUNCTION public.tile_tolerance(z integer, multiplier double precision DEFAULT 1.0)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT (40075016.6855785 / power(2, z) / 4096) * multiplier;
$$;

COMMENT ON FUNCTION public.tile_tolerance(integer, double precision) IS
  'ST_Simplify tolerance in EPSG:3857 metres for one MVT grid unit at zoom z.';

-- ---------------------------------------------------------------------------
-- The tile source (C.1, C.2, C.4)
-- ---------------------------------------------------------------------------
-- Properties are deliberately lean (spec 10.1): identity + the three metrics the
-- client toggles between + acres. Everything descriptive (situs, class, city)
-- belongs to the drawer API, which is fetched for one parcel at a time.
--
-- Eligibility needs no restating here: parcels_map IS the rule.

CREATE OR REPLACE FUNCTION public.parcels_mvt(z integer, x integer, y integer)
RETURNS bytea
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    tile_3857  geometry;
    tile_4326  geometry;
    tolerance  double precision;
    result     bytea;
BEGIN
    -- Below the parcel minzoom the client shows basemap only. Returning NULL
    -- makes Martin answer 204 No Content, which is cheaper than an empty tile.
    --
    -- Measured, not guessed (C.5, revised). Across every tile covering the
    -- county: z13 median 213 kB, max 578 kB; z14 median 53 kB, max 194 kB.
    -- z12 is not reachable without changing what the map shows -- a z12 tile
    -- holds 30,758 parcels and stays over 1 MB even stripped and simplified;
    -- only an acreage filter brings it down, and a 0.25 ac floor would drop 79%
    -- of parcels and empty the suburbs.
    --
    -- Geometry is only ~25% of a tile's bytes, so simplifying harder barely
    -- helps (263 kB -> 261 kB at 3x tolerance): feature count is the constraint.
    IF z < 13 THEN
        RETURN NULL;
    END IF;

    tile_3857 := ST_TileEnvelope(z, x, y);

    -- The index on parcels.geom is built in 4326, so the tile bounds are brought
    -- to the data rather than the data to the bounds. Writing this the other way
    -- round -- ST_Transform(p.geom, 3857) && tile_3857 -- forces a transform of
    -- every row in the table before comparison and cannot use the index at all.
    tile_4326 := ST_Transform(tile_3857, 4326);

    tolerance := public.tile_tolerance(z, 1.0);

    -- 'pid' names the feature-id column: MVT stores it in a dedicated varint
    -- slot rather than the property dictionary. Measured at z13, carrying the
    -- taxpin string here instead cost 41% of the tile.
    SELECT ST_AsMVT(t, 'parcels', 4096, 'geom', 'pid')
    INTO result
    FROM (
        SELECT
            p.parcel_id AS pid,
            -- Whole dollars and 2dp acres: the paint cannot resolve finer, and
            -- the drawer serves true values from Postgres. Worth 23% of a tile.
            round(p.land_vpa)::int      AS land_vpa,
            round(p.total_vpa)::int     AS total_vpa,
            round(p.appraised_vpa)::int AS appraised_vpa,
            -- No acres: the client reads it from the drawer API, never from a
            -- tile feature, so carrying it here costs ~6% of every tile for
            -- nothing.
            ST_AsMVTGeom(
                ST_Simplify(ST_Transform(p.geom, 3857), tolerance),
                tile_3857,
                4096,   -- grid extent
                64,     -- buffer, in grid units, so shapes crossing the seam
                        -- are not clipped mid-stroke between neighbouring tiles
                true    -- clip to the tile
            ) AS geom
        FROM parcels_map p
        WHERE p.geom && tile_4326
    ) AS t
    -- ST_AsMVTGeom returns NULL when a shape collapses to nothing at this zoom;
    -- those rows would otherwise ride along as featureless properties.
    WHERE t.geom IS NOT NULL;

    RETURN result;
END;
$$;

-- Martin parses this comment as a TileJSON fragment, so it must be JSON rather
-- than prose (prose logs a deserialize warning and is discarded). It is also the
-- natural place for the TAD attribution the spec requires on public surfaces.
COMMENT ON FUNCTION public.parcels_mvt(integer, integer, integer) IS
  '{"description": "Tarrant County parcels by value per acre. Lean properties; ST_Simplify by zoom.",
    "attribution": "Data from Tarrant Appraisal District (TAD). Informational only; not for legal, engineering, or surveying purposes.",
    "minzoom": 13,
    "maxzoom": 20}';

\echo '05_tiles: parcels_mvt(z,x,y) + tile_tolerance(z) created'

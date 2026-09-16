-- B.10 — validation. Compares the loaded database against the B.1 profile of the
-- 2025 package. FAIL rows mean the load drifted from what profiling measured;
-- after a source refresh, re-run profile-source.py and update the expectations.

\set ON_ERROR_STOP on

\echo '=== Load validation (expectations from B.1, 2025 package) ==='

WITH checks AS (
    SELECT 'parcel count'            AS check_name,
           (SELECT count(*) FROM parcels)::text AS actual,
           '689908' AS expected,
           (SELECT count(*) FROM parcels) = 689908 AS ok
    UNION ALL
    SELECT 'map-eligible count',
           (SELECT count(*) FROM parcels_map)::text,
           '674519 (684,851 - 10,332 nominal-value placeholders)',
           (SELECT count(*) FROM parcels_map) BETWEEN 674000 AND 675000
    UNION ALL
    SELECT 'unmatched parcels retained',
           (SELECT count(*) FROM parcels WHERE account_count = 0)::text,
           '3783',
           (SELECT count(*) FROM parcels WHERE account_count = 0) = 3783
    UNION ALL
    SELECT 'deduped taxpins',
           (SELECT count(*) FROM parcels WHERE part_count > 1)::text,
           '7',
           (SELECT count(*) FROM parcels WHERE part_count > 1) = 7
    UNION ALL
    SELECT 'max accounts on one parcel',
           (SELECT max(account_count) FROM parcels)::text,
           '494',
           (SELECT max(account_count) FROM parcels) = 494
    UNION ALL
    SELECT 'acres fallback used',
           (SELECT count(*) FROM parcels WHERE acres_source = 'land_acres')::text,
           '~2201',
           (SELECT count(*) FROM parcels WHERE acres_source = 'land_acres') BETWEEN 2000 AND 2400
    UNION ALL
    SELECT 'geometry all valid',
           (SELECT count(*) FROM parcels WHERE NOT ST_IsValid(geom))::text,
           '0',
           NOT EXISTS (SELECT 1 FROM parcels WHERE NOT ST_IsValid(geom))
    UNION ALL
    SELECT 'geometry SRID',
           (SELECT DISTINCT ST_SRID(geom)::text FROM parcels LIMIT 1),
           '4326',
           NOT EXISTS (SELECT 1 FROM parcels WHERE ST_SRID(geom) <> 4326)
    UNION ALL
    SELECT 'no parcel under the acres floor is eligible',
           (SELECT count(*) FROM parcels_map WHERE acres < 0.005)::text,
           '0',
           NOT EXISTS (SELECT 1 FROM parcels_map WHERE acres < 0.005)
    UNION ALL
    SELECT 'land + improvement = total',
           (SELECT count(*) FROM parcels
             WHERE land_value IS NOT NULL AND improvement_value IS NOT NULL
               AND total_value IS NOT NULL
               AND abs((land_value + improvement_value) - total_value) > 1)::text,
           '<= 5 (TAD quirk, see B.2 notes)',
           (SELECT count(*) FROM parcels
             WHERE land_value IS NOT NULL AND improvement_value IS NOT NULL
               AND total_value IS NOT NULL
               AND abs((land_value + improvement_value) - total_value) > 1) <= 5
    UNION ALL
    SELECT 'median land VPA in the expected range',
           (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY land_vpa))::text FROM parcels_map),
           '~307478',
           (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY land_vpa) FROM parcels_map)
               BETWEEN 290000 AND 325000
    UNION ALL
    SELECT 'over-cap land parcels stay a minority',
           (SELECT count(*) FROM parcels_map WHERE land_vpa > 1500000)::text,
           '< 2% of eligible',
           (SELECT count(*) FROM parcels_map WHERE land_vpa > 1500000)
               < (SELECT count(*) * 0.02 FROM parcels_map)
    UNION ALL
    SELECT 'city codes present for comps',
           (SELECT count(DISTINCT city_code) FROM parcels WHERE map_eligible)::text,
           '42 of the 43 source codes',
           (SELECT count(DISTINCT city_code) FROM parcels WHERE map_eligible) BETWEEN 40 AND 45
    UNION ALL
    SELECT 'no nominal-value placeholder is eligible',
           (SELECT count(*) FROM parcels WHERE map_eligible AND land_value <= 1000)::text,
           '0 (the land_value > 1000 floor)',
           NOT EXISTS (SELECT 1 FROM parcels WHERE map_eligible AND land_value <= 1000)
    UNION ALL
    SELECT 'placeholders still retained in parcels',
           (SELECT count(*) FROM parcels WHERE land_value <= 1000 AND account_count > 0)::text,
           '11574 (excluded from the map, reachable by taxpin)',
           (SELECT count(*) FROM parcels WHERE land_value <= 1000 AND account_count > 0)
               BETWEEN 11000 AND 12000
    UNION ALL
    SELECT 'the $1 population specifically',
           (SELECT count(*) FROM parcels WHERE land_value = 1)::text,
           '8128+, none eligible',
           (SELECT count(*) FROM parcels WHERE land_value = 1 AND map_eligible) = 0
    UNION ALL
    SELECT 'map_eligible flag agrees with parcels_map',
           (SELECT count(*) FROM parcels WHERE map_eligible)::text,
           'equal to parcels_map',
           (SELECT count(*) FROM parcels WHERE map_eligible) = (SELECT count(*) FROM parcels_map)
)
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, check_name, actual, expected
FROM checks
ORDER BY ok, check_name;

\echo ''
\echo '=== Spot checks: worst VPA offenders should be plausible downtown land, not slivers ==='
SELECT taxpin, round(acres, 4) AS acres, land_value, land_vpa, city_code, property_class
FROM parcels WHERE map_eligible ORDER BY land_vpa DESC LIMIT 5;

\echo ''
\echo '=== Sample drawer + comps query (subject = a mid-market parcel) ==='
WITH subject AS (
    SELECT * FROM parcels
    WHERE map_eligible AND acres BETWEEN 0.2 AND 0.3 AND city_code IS NOT NULL
    ORDER BY land_vpa DESC LIMIT 1
)
SELECT 'subject' AS role, p.taxpin, p.acres, p.land_vpa, p.city_code
FROM subject p
UNION ALL
SELECT 'comp', c.taxpin, c.acres, c.land_vpa, c.city_code
FROM subject s
JOIN parcels c
  ON c.map_eligible
 AND c.taxpin <> s.taxpin
 AND c.city_code = s.city_code
 AND c.acres BETWEEN s.acres * 0.5 AND s.acres * 2
ORDER BY 1 DESC
LIMIT 4;

-- B.9 — countywide style statistics, one row per metric.
--
-- cap/k are the B.1 decisions, not measurements: caps sit near the measured p99
-- per metric, and k is set so cap * k = 3000 m for all three, keeping the metric
-- toggle visually comparable. The percentiles ARE measured, over parcels_map.

\set ON_ERROR_STOP on

BEGIN;

TRUNCATE map_stats;

INSERT INTO map_stats (
    metric, eligible_count, min_vpa, p5_vpa, p50_vpa, p95_vpa, p99_vpa, max_vpa,
    cap, k, over_cap_count
)
SELECT
    m.metric,
    count(v.vpa),
    min(v.vpa),
    percentile_cont(0.05) WITHIN GROUP (ORDER BY v.vpa)::numeric,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY v.vpa)::numeric,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY v.vpa)::numeric,
    percentile_cont(0.99) WITHIN GROUP (ORDER BY v.vpa)::numeric,
    max(v.vpa),
    m.cap,
    round(1000.0 / m.cap, 8),               -- shared 1,000 m ceiling
    count(*) FILTER (WHERE v.vpa > m.cap)
-- Source of truth for caps is app/config/map.php; these mirror it so
-- map_stats.over_cap_count reports against the caps actually in use. Keep in step.
FROM (VALUES
    ('land',       5000000::numeric),
    ('total',     20000000::numeric),
    ('appraised', 20000000::numeric)
) AS m(metric, cap)
CROSS JOIN LATERAL (
    SELECT CASE m.metric
               WHEN 'land'      THEN p.land_vpa
               WHEN 'total'     THEN p.total_vpa
               WHEN 'appraised' THEN p.appraised_vpa
           END AS vpa
    FROM parcels_map p
) v
GROUP BY m.metric, m.cap;

COMMIT;

\echo '04_stats: map_stats populated'
SELECT metric, eligible_count, p5_vpa, p50_vpa, p95_vpa, p99_vpa, max_vpa, cap, k, over_cap_count
FROM map_stats ORDER BY metric;

\echo ''
\echo 'Copy into app/.env — colour domain is the p5..p95 band (linear ramp to max is unusable):'
SELECT format('MAP_COLOR_MIN=%s   MAP_COLOR_MAX=%s   # %s', round(p5_vpa), round(p95_vpa), metric)
FROM map_stats ORDER BY metric;

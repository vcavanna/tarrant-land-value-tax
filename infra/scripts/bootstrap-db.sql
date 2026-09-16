-- One-shot local database bootstrap for tad-analysis (A.2).
-- Run as a PostgreSQL superuser, e.g.:
--   sudo -u postgres psql -v ON_ERROR_STOP=1 -f infra/scripts/bootstrap-db.sql
--
-- Creates role + database and enables PostGIS. Idempotent enough for re-runs.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'tad') THEN
    CREATE ROLE tad LOGIN PASSWORD 'tad';
  ELSE
    ALTER ROLE tad WITH LOGIN PASSWORD 'tad';
  END IF;
END
$$;

SELECT 'CREATE DATABASE tad_analysis OWNER tad'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'tad_analysis')\gexec

\connect tad_analysis

CREATE EXTENSION IF NOT EXISTS postgis;

-- App role needs create on public for migrations / ETL in dev.
GRANT ALL ON SCHEMA public TO tad;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO tad;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO tad;

-- Quick sanity
SELECT postgis_full_version() AS postgis_version;

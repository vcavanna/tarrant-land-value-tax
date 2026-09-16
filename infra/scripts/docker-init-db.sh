#!/bin/bash
# Runs once inside PostGIS container on first volume init.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'tad') THEN
    CREATE ROLE tad LOGIN PASSWORD 'tad';
  END IF;
END
$$;

GRANT ALL PRIVILEGES ON DATABASE tad_analysis TO tad;
CREATE EXTENSION IF NOT EXISTS postgis;
GRANT ALL ON SCHEMA public TO tad;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO tad;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO tad;
SQL

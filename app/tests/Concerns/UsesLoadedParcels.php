<?php

namespace Tests\Concerns;

use Illuminate\Support\Facades\DB;

/**
 * Points a test at the ETL-loaded Postgres database.
 *
 * `parcels` is owned by etl/sql, not by Laravel migrations, so there is no
 * factory — the loaded county IS the fixture. phpunit.xml pins the suite to
 * in-memory SQLite, so the pgsql connection must be configured explicitly or it
 * inherits DB_DATABASE=":memory:".
 *
 * Tests using this skip rather than fail when the database is absent, so the
 * suite still runs on a machine without it.
 */
trait UsesLoadedParcels
{
    protected function useLoadedParcels(): void
    {
        config([
            'database.default' => 'pgsql',
            'database.connections.pgsql.host' => env('TAD_DB_HOST', '127.0.0.1'),
            'database.connections.pgsql.port' => env('TAD_DB_PORT', '5432'),
            'database.connections.pgsql.database' => env('TAD_DB_DATABASE', 'tad_analysis'),
            'database.connections.pgsql.username' => env('TAD_DB_USERNAME', 'tad'),
            'database.connections.pgsql.password' => env('TAD_DB_PASSWORD', 'tad'),
        ]);
        DB::purge('pgsql');

        try {
            $loaded = DB::table('parcels')->where('map_eligible', true)->exists();
        } catch (\Throwable $e) {
            $this->markTestSkipped('Postgres not reachable: '.$e->getMessage());
        }

        if (! $loaded) {
            $this->markTestSkipped('parcels is empty — run etl/scripts/load-parcels.sh');
        }
    }
}

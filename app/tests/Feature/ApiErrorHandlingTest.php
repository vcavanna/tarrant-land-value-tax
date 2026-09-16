<?php

namespace Tests\Feature;

use PHPUnit\Framework\Attributes\Test;
use Tests\Concerns\UsesLoadedParcels;
use Tests\TestCase;

/**
 * API error contract (spec D.7). The API is public, so these responses are part
 * of the contract and must not leak internals.
 */
class ApiErrorHandlingTest extends TestCase
{
    use UsesLoadedParcels;

    protected function setUp(): void
    {
        parent::setUp();
        $this->useLoadedParcels();
    }

    #[Test]
    public function a_missing_parcel_returns_the_error_envelope(): void
    {
        $this->getJson('/api/parcels/NOPE-123')
            ->assertNotFound()
            ->assertJsonStructure(['error' => ['status', 'message']])
            ->assertJsonPath('error.status', 404);

        $this->getJson('/api/parcels/id/99999999')
            ->assertNotFound()
            ->assertJsonPath('error.status', 404);
    }

    #[Test]
    public function errors_never_leak_paths_or_stack_traces(): void
    {
        // Laravel's default 404 body carried the absolute controller path and a
        // full trace. Asserted with debug ON, which is the harder case.
        config(['app.debug' => true]);

        $body = $this->getJson('/api/parcels/NOPE-123')->assertNotFound()->getContent();

        $this->assertStringNotContainsString(base_path(), $body);
        $this->assertStringNotContainsString('/home/', $body);
        $this->assertStringNotContainsString('"trace"', $body);
        $this->assertStringNotContainsString('vendor/laravel', $body);
    }

    #[Test]
    public function debug_detail_is_omitted_when_debug_is_off(): void
    {
        config(['app.debug' => false]);

        $this->getJson('/api/parcels/NOPE-123')
            ->assertNotFound()
            ->assertJsonMissingPath('debug');
    }

    #[Test]
    public function a_database_outage_returns_503_not_500(): void
    {
        // 503 lets monitoring distinguish "the map is down" from a code bug.
        config(['database.connections.pgsql.host' => '127.0.0.1', 'database.connections.pgsql.port' => 59999]);
        \Illuminate\Support\Facades\DB::purge('pgsql');

        $this->getJson('/api/parcels/10000-10-1')
            ->assertStatus(503)
            ->assertJsonPath('error.status', 503)
            ->assertJsonPath('error.message', 'The parcel database is unavailable.');
    }

    #[Test]
    public function html_routes_keep_laravels_own_error_pages(): void
    {
        // The envelope is for api/* only; a browser hitting a bad deep link
        // should still get an HTML 404.
        $response = $this->get('/parcels/NOPE-999');

        $response->assertNotFound();
        $this->assertStringNotContainsString('"error"', $response->getContent());
    }
}

<?php

namespace Tests\Feature;

use PHPUnit\Framework\Attributes\Test;
use Tests\Concerns\UsesLoadedParcels;
use Tests\TestCase;

/**
 * Map config contract (spec D.4). Section E binds to this shape.
 */
class MapConfigTest extends TestCase
{
    use UsesLoadedParcels;

    protected function setUp(): void
    {
        parent::setUp();
        $this->useLoadedParcels();
    }

    #[Test]
    public function it_returns_the_documented_config_shape(): void
    {
        $this->getJson('/api/map-config')
            ->assertOk()
            ->assertJsonStructure([
                'data' => [
                    'default_metric', 'default_mode', 'height_ceiling_m',
                    'metrics' => ['land' => ['label', 'cap', 'k', 'color_min',
                        'color_max', 'color_domain_source', 'eligible_count',
                        'over_cap_count']],
                    'tiles' => ['url', 'source_layer', 'minzoom', 'maxzoom'],
                    'basemap' => ['style'],
                    'view' => ['center', 'bounds'],
                ],
                'meta' => ['license'],
            ]);
    }

    #[Test]
    public function every_metric_reaches_the_same_extrusion_ceiling(): void
    {
        // The reason k is derived rather than configured: with land capped at
        // 1.5M and total at 6.5M, a shared k would make total extrude 4.3x
        // taller for the same parcel and the metric toggle would mislead.
        $data = $this->getJson('/api/map-config')->assertOk()->json('data');

        foreach ($data['metrics'] as $name => $metric) {
            $this->assertEqualsWithDelta(
                $data['height_ceiling_m'],
                $metric['cap'] * $metric['k'],
                0.01,
                "metric {$name} does not reach the shared ceiling"
            );
        }
    }

    #[Test]
    public function caps_are_per_metric_not_the_retired_scalar(): void
    {
        // Regression guard for B.1: a single cap of 5000 put 98.26% of the
        // county over cap, and land/total differ by roughly 5x.
        $metrics = $this->getJson('/api/map-config')->assertOk()->json('data.metrics');

        $this->assertGreaterThan($metrics['land']['cap'], $metrics['total']['cap']);

        foreach ($metrics as $name => $metric) {
            $this->assertGreaterThan(5000, $metric['cap'], "metric {$name} still uses the old scalar cap");
        }
    }

    #[Test]
    public function the_colour_domain_comes_from_measured_stats(): void
    {
        $metrics = $this->getJson('/api/map-config')->assertOk()->json('data.metrics');

        foreach ($metrics as $name => $metric) {
            $this->assertSame('map_stats', $metric['color_domain_source'],
                "metric {$name} fell back to config — has the ETL run?");
            $this->assertLessThan($metric['color_max'], $metric['color_min']);
            // The ramp must stop well below the cap, or the domain is unusable:
            // land VPA reaches $36M against a $312k median.
            $this->assertLessThan($metric['cap'], $metric['color_max']);
        }
    }

    #[Test]
    public function over_cap_parcels_stay_a_small_minority(): void
    {
        foreach ($this->getJson('/api/map-config')->assertOk()->json('data.metrics') as $name => $metric) {
            $share = $metric['over_cap_count'] / $metric['eligible_count'];
            $this->assertLessThan(0.02, $share, "metric {$name} renders {$share} of the county black");
        }
    }

    #[Test]
    public function the_tile_url_is_same_origin_and_matches_the_measured_minzoom(): void
    {
        $tiles = $this->getJson('/api/map-config')->assertOk()->json('data.tiles');

        $this->assertStringStartsWith('/', $tiles['url']);
        $this->assertStringContainsString('{z}/{x}/{y}', $tiles['url']);
        $this->assertSame(13, $tiles['minzoom']);   // measured: z13 max tile 578 kB
        $this->assertSame('parcels', $tiles['source_layer']);
    }

    #[Test]
    public function the_default_metric_exists(): void
    {
        $data = $this->getJson('/api/map-config')->assertOk()->json('data');

        $this->assertArrayHasKey($data['default_metric'], $data['metrics']);
    }
}

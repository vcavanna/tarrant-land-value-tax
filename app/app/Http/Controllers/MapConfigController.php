<?php

namespace App\Http\Controllers;

use App\Models\MapStat;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Collection;

/**
 * Deploy constants for the frontend (spec D.4).
 *
 * Exists so the UI never hard-codes cap, k, colour domain, minzoom or the
 * basemap URL. Those values changed substantially during B.1 and C.5 — the cap
 * by three orders of magnitude — and a page with them baked in would have gone
 * quietly wrong.
 */
class MapConfigController extends Controller
{
    public function __invoke(): JsonResponse
    {
        $stats = $this->stats();
        $ceiling = (float) config('map.height_ceiling_m');

        $metrics = collect(config('map.metrics'))
            ->map(function (array $metric, string $name) use ($stats, $ceiling) {
                $stat = $stats->get($name);

                return [
                    'label' => $metric['label'],
                    'cap' => $metric['cap'],
                    // Derived, never configured: every metric reaches the same
                    // extrusion ceiling so the toggle stays comparable.
                    'k' => $metric['cap'] > 0 ? $ceiling / $metric['cap'] : 0.0,
                    // Measured p5..p95 when the ETL has run, config otherwise.
                    'color_min' => $stat?->p5_vpa ?? $metric['color_min'],
                    'color_max' => $stat?->p95_vpa ?? $metric['color_max'],
                    'color_domain_source' => $stat !== null ? 'map_stats' : 'config',
                    'eligible_count' => $stat?->eligible_count,
                    'over_cap_count' => $stat?->over_cap_count,
                ];
            });

        return response()->json([
            'data' => [
                'default_metric' => config('map.default_metric'),
                'default_mode' => config('map.default_mode'),
                'height_ceiling_m' => $ceiling,
                'metrics' => $metrics,
                'tiles' => [
                    // Same-origin; the client must not read Martin's TileJSON
                    // and follow it to a different host.
                    'url' => sprintf('%s/%s/{z}/{x}/{y}',
                        rtrim((string) config('map.tiles_url'), '/'),
                        config('map.tiles_source')),
                    'source_layer' => config('map.tiles_layer'),
                    'minzoom' => config('map.parcel_minzoom'),
                    'maxzoom' => config('map.parcel_maxzoom'),
                ],
                'basemap' => [
                    'style' => config('map.openfreemap_style'),
                ],
                'view' => [
                    'center' => config('map.center'),
                    'bounds' => config('map.bounds'),
                ],
            ],
            'meta' => [
                'license' => config('map.license_footer'),
            ],
        ]);
    }

    /**
     * @return Collection<string, MapStat>
     */
    private function stats(): Collection
    {
        try {
            return MapStat::all()->keyBy('metric');
        } catch (\Throwable $e) {
            // The endpoint must still answer before the ETL has ever run —
            // the config fallbacks cover it.
            report($e);

            return collect();
        }
    }
}

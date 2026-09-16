<?php

use App\Http\Controllers\MapConfigController;
use App\Http\Controllers\ParcelController;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;

/*
| Public JSON API (drawer/comps land in Section D).
| Health is available now for A.2 stack verification.
*/

Route::get('/health', function () {
    $db = ['ok' => false, 'driver' => config('database.default')];

    try {
        $row = DB::selectOne('select 1 as ok, postgis_version() as postgis');
        $db['ok'] = true;
        $db['postgis'] = $row->postgis ?? null;
    } catch (Throwable $e) {
        $db['error'] = $e->getMessage();
    }

    return response()->json([
        'ok' => $db['ok'],
        'app' => config('app.name'),
        'map' => [
            // Per-metric cap/k live at /api/map-config; health stays a liveness
            // probe rather than a second copy of the configuration.
            'parcel_minzoom' => config('map.parcel_minzoom'),
            'default_metric' => config('map.default_metric'),
            'default_mode' => config('map.default_mode'),
            'tiles_url' => config('map.tiles_url'),
            'metrics' => array_keys(config('map.metrics')),
        ],
        'database' => $db,
    ], $db['ok'] ? 200 : 503);
});

/*
| Map configuration (Section D.4). Deploy constants for the frontend so the UI
| never hard-codes cap, k, colour domain, minzoom or the basemap URL.
*/
Route::get('/map-config', MapConfigController::class)->name('map.config');

/*
| Selection drawer (Section D.2). Dynamic — never CDN-cached.
|
| The id route is declared first so that /parcels/id/... cannot be swallowed by
| the taxpin route. Taxpins are 4-18 chars of letters, digits, hyphens and
| spaces (no slashes anywhere in the 2025 package), so they are safe as a path
| segment once URL-encoded.
*/
Route::get('/parcels/id/{parcelId}', [ParcelController::class, 'showById'])
    ->whereNumber('parcelId')
    ->name('parcels.show.id');

Route::get('/parcels/{taxpin}', [ParcelController::class, 'showByTaxpin'])
    ->where('taxpin', '[A-Za-z0-9 .-]+')
    ->name('parcels.show');

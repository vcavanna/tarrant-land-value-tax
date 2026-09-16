<?php

use App\Models\Parcel;
use Illuminate\Support\Facades\Route;

/*
| Page shell (Section D.5). One page hosting the MapLibre app — there is no
| client-side routing in v1, so this is a Blade view rather than an SPA.
|
| Deploy constants are NOT injected into the page: the client fetches them from
| /api/map-config so one source serves every consumer.
*/

Route::get('/', fn () => view('map'))->name('map');

/*
| Deep link to a single parcel. Serves the same shell with the taxpin attached,
| so the map can open with that parcel selected and flown to. Shareable, and
| the client keeps it in sync via history.replaceState on every selection.
|
| 404s here rather than in the client so a bad link fails fast and does not
| render an empty map. Taxpins are 4-18 chars of letters, digits, hyphens and
| spaces — no slashes in the 2025 package — so they are safe as a path segment.
*/
Route::get('/parcels/{taxpin}', function (string $taxpin) {
    abort_unless(Parcel::whereKey($taxpin)->exists(), 404);

    return view('map', ['initialParcel' => $taxpin]);
})->where('taxpin', '[A-Za-z0-9 .-]+')->name('map.parcel');

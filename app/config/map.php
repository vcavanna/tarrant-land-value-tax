<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Value-per-acre map configuration (Section A.4, revised in B.1 / C.5)
    |--------------------------------------------------------------------------
    | Served to the frontend by GET /api/map-config (D.4) so the UI never hard-
    | codes deploy constants.
    |
    | Two kinds of value live here, and they are handled differently:
    |
    |   * PRODUCT decisions — caps, the extrusion ceiling, defaults — are set
    |     here and in env.
    |   * MEASURED values — the colour domain — come from the `map_stats` table
    |     the ETL writes, so a reload cannot leave them stale. The entries below
    |     are only a fallback for when map_stats is empty.
    */

    /*
    | Per-metric caps and colour domain.
    |
    | B.1 replaced a single `vpa_cap` of 5000 with these. Land and total VPA
    | differ by roughly 5x, so one cap cannot serve both: at 5000, 98.26% of the
    | county rendered black.
    |
    | Caps then sat at each metric's p99, which was statistically defensible and
    | visually wrong: the over-cap parcels are not scattered, they are downtown.
    | At a 1.5M land cap, 49.2% of downtown Fort Worth rendered black -- the most
    | valuable land in the county reduced to one undifferentiated blob.
    |
    | Caps now sit near p99.95, so black marks a genuine outlier rather than
    | describing downtown. Downtown black: land 49.2% -> 1.1%, total 22.7% ->
    | 9.1%. Countywide the land cap costs 143 parcels (0.02%).
    |
    | Colour domain fallbacks are the p5..p95 band measured over the 674,519
    | eligible parcels. A linear ramp to max is unusable — land VPA reaches
    | $36M/acre against a $312k median.
    */
    'metrics' => [
        'land' => [
            'label' => 'Land',
            'cap' => (float) env('MAP_LAND_CAP', 5_000_000),
            'color_min' => (float) env('MAP_LAND_COLOR_MIN', 71_981),
            'color_max' => (float) env('MAP_LAND_COLOR_MAX', 807_925),
        ],
        'total' => [
            'label' => 'Total',
            'cap' => (float) env('MAP_TOTAL_CAP', 20_000_000),
            'color_min' => (float) env('MAP_TOTAL_COLOR_MIN', 145_664),
            'color_max' => (float) env('MAP_TOTAL_COLOR_MAX', 3_410_433),
        ],
        'appraised' => [
            'label' => 'Appraised',
            'cap' => (float) env('MAP_APPRAISED_CAP', 20_000_000),
            'color_min' => (float) env('MAP_APPRAISED_COLOR_MIN', 133_415),
            'color_max' => (float) env('MAP_APPRAISED_COLOR_MAX', 3_353_619),
        ],
    ],

    /*
    | 3D extrusion height, in metres, for a parcel at its metric's cap.
    |
    | Raised from 300 m to 1000 m alongside the cap increase: k is derived as
    | ceiling / cap, so tripling the cap would have flattened every ordinary
    | parcel by the same factor. 1000/5M keeps a typical downtown parcel at the
    | height that was checked visually.
    |
    | `k` is NOT configured directly — it is derived per metric as
    | ceiling / cap, so every metric tops out at the same height and the metric
    | toggle stays visually comparable. Configuring k by hand is how the two
    | drift apart: with land capped at 1.5M and total at 6.5M, a shared k would
    | make total extrude 4.3x taller for the same parcel.
    |
    |   height = min(vpa, cap_metric) * k_metric      k_metric = ceiling / cap
    */
    'height_ceiling_m' => (float) env('MAP_HEIGHT_CEILING_M', 1000),

    /*
    | Parcels are hidden below this zoom; basemap only.
    |
    | Measured over every tile covering the county, not guessed: z13 has a median
    | tile of 213 kB and a worst case of 578 kB; z14 a median of 53 kB. z12 is
    | out of reach -- 30,758 parcels in one tile, over 1 MB even stripped and
    | simplified; only an acreage filter helps, and a 0.25 ac floor would drop
    | 79% of parcels.
    */
    'parcel_minzoom' => (int) env('MAP_PARCEL_MINZOOM', 13),

    'parcel_maxzoom' => (int) env('MAP_PARCEL_MAXZOOM', 20),

    'default_metric' => env('MAP_DEFAULT_METRIC', 'land'), // land|total|appraised

    'default_mode' => env('MAP_DEFAULT_MODE', 'color'), // color|3d

    /*
    | Same-origin tile base path (proxied to Martin). No filter query params in v1.
    */
    'tiles_url' => env('MAP_TILES_URL', '/tiles'),

    'tiles_source' => env('MAP_TILES_SOURCE', 'parcels'),

    /*
    | The MVT layer name inside a tile, set by ST_AsMVT in etl/sql/05_tiles.sql.
    | MapLibre needs it as `source-layer`.
    */
    'tiles_layer' => env('MAP_TILES_LAYER', 'parcels'),

    'openfreemap_style' => env(
        'MAP_OPENFREEMAP_STYLE',
        'https://tiles.openfreemap.org/styles/liberty'
    ),

    /*
    | Tarrant County. Used for the initial view and to bound panning.
    */
    'bounds' => [
        (float) env('MAP_BOUNDS_WEST', -97.553),
        (float) env('MAP_BOUNDS_SOUTH', 32.548),
        (float) env('MAP_BOUNDS_EAST', -97.031),
        (float) env('MAP_BOUNDS_NORTH', 32.994),
    ],

    'center' => [
        (float) env('MAP_CENTER_LON', -97.3308),
        (float) env('MAP_CENTER_LAT', 32.7555),
    ],

    'license_footer' => env(
        'MAP_LICENSE_FOOTER',
        'Data from Tarrant Appraisal District (TAD). Informational only; not for legal, engineering, or surveying purposes.'
    ),

];

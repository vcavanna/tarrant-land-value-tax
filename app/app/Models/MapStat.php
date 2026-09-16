<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * Countywide VPA distribution, one row per metric. Written by
 * etl/sql/04_stats.sql on every load; read by the map-config endpoint so the
 * colour domain cannot go stale when the data is reloaded.
 *
 * @property string $metric
 * @property int    $eligible_count
 * @property float  $p5_vpa
 * @property float  $p95_vpa
 * @property int    $over_cap_count
 */
class MapStat extends Model
{
    protected $table = 'map_stats';

    protected $primaryKey = 'metric';

    protected $keyType = 'string';

    public $incrementing = false;

    public $timestamps = false;

    protected function casts(): array
    {
        return [
            'eligible_count' => 'integer',
            'min_vpa' => 'float',
            'p5_vpa' => 'float',
            'p50_vpa' => 'float',
            'p95_vpa' => 'float',
            'p99_vpa' => 'float',
            'max_vpa' => 'float',
            'cap' => 'float',
            'k' => 'float',
            'over_cap_count' => 'integer',
            'computed_at' => 'datetime',
        ];
    }
}

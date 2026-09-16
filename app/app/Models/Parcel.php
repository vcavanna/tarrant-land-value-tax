<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

/**
 * A curated parcel. The table is owned by the ETL (etl/sql/01_schema.sql), not by
 * Laravel migrations — reloading data is `etl/scripts/load-parcels.sh`.
 *
 * @property string      $taxpin
 * @property int         $parcel_id
 * @property float|null  $acres
 * @property int         $account_count
 * @property float|null  $land_value
 * @property float|null  $improvement_value
 * @property float|null  $total_value
 * @property float|null  $appraised_value
 * @property float|null  $land_vpa
 * @property float|null  $total_vpa
 * @property float|null  $appraised_vpa
 * @property string|null $property_class
 * @property string|null $state_use
 * @property string|null $city_code
 * @property string|null $situs
 * @property bool        $map_eligible
 */
class Parcel extends Model
{
    protected $table = 'parcels';

    protected $primaryKey = 'taxpin';

    protected $keyType = 'string';

    public $incrementing = false;

    public $timestamps = false;

    /**
     * Owner fields are not in the curated table at all, so there is nothing to
     * hide here — but the guarded list documents the intent for future columns.
     */
    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'parcel_id' => 'integer',
            'acres' => 'float',
            'account_count' => 'integer',
            'land_value' => 'float',
            'improvement_value' => 'float',
            'total_value' => 'float',
            'appraised_value' => 'float',
            'land_vpa' => 'float',
            'total_vpa' => 'float',
            'appraised_vpa' => 'float',
            'map_eligible' => 'boolean',
        ];
    }

    /** Parcels that reach the map: joined, above the acres and land-value floors. */
    public function scopeMapEligible(Builder $query): Builder
    {
        return $query->where('map_eligible', true);
    }

    /**
     * Add a point to fly to. ST_PointOnSurface rather than ST_Centroid: a
     * centroid can fall outside a concave or multi-part parcel, which would
     * put the map marker in a neighbour's yard.
     *
     * Opt-in because geom is large and most queries do not need it.
     */
    public function scopeWithCenter(Builder $query): Builder
    {
        return $query
            ->select($query->getQuery()->columns ?: ['parcels.*'])
            ->selectRaw('ST_X(ST_PointOnSurface(geom)) AS lon')
            ->selectRaw('ST_Y(ST_PointOnSurface(geom)) AS lat');
    }
}

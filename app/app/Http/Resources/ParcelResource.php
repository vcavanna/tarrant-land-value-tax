<?php

namespace App\Http\Resources;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * The selection drawer payload.
 *
 * Deliberately NOT a dump of the row. Owner name and mailing address are absent
 * from the curated table entirely (spec 1.2: never on any public surface), and
 * nothing here should reintroduce them if columns are added later.
 *
 * @mixin \App\Models\Parcel
 */
class ParcelResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'taxpin' => $this->taxpin,
            'parcel_id' => $this->parcel_id,

            'acres' => $this->acres,
            // Which denominator produced `acres` — calculated | land_acres |
            // geometry. Exposed because it explains a surprising VPA.
            'acres_source' => $this->acres_source,

            // Number of TAD accounts rolled into this parcel. >1 means the values
            // below are sums; 496 means a condo tower.
            'accounts' => $this->account_count,

            'values' => [
                'land' => $this->land_value,
                'improvement' => $this->improvement_value,
                'total' => $this->total_value,
                'appraised' => $this->appraised_value,
            ],

            'vpa' => [
                'land' => $this->land_vpa,
                'total' => $this->total_vpa,
                'appraised' => $this->appraised_vpa,
            ],

            'classification' => [
                'property_class' => $this->property_class,
                'state_use' => $this->state_use,
            ],

            'location' => [
                'situs' => $this->situs,
                // Raw TAD code; no lookup table ships with the source data.
                'city_code' => $this->city_code,
                // [lon, lat] for deep links and fly-to. Present only when the
                // query used withCenter().
                'center' => $this->lon !== null ? [(float) $this->lon, (float) $this->lat] : null,
            ],

            // False for parcels reachable by direct URL but absent from the map:
            // unmatched, under the acres floor, or nominal-value placeholders.
            'map_eligible' => $this->map_eligible,

            // Attached by the controller via setRelation(); omitted entirely if
            // the resource is ever rendered without them.
            'comps' => ComparableParcelResource::collection($this->whenLoaded('comps')),
        ];
    }
}

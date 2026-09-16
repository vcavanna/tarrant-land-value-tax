<?php

namespace App\Http\Resources;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * A comp in the drawer. Leaner than the subject: enough to make the contrast
 * legible and to fly to it, nothing more.
 *
 * @mixin \App\Models\Parcel
 */
class ComparableParcelResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'taxpin' => $this->taxpin,
            'parcel_id' => $this->parcel_id,
            'acres' => $this->acres,
            // A comp is an argument about a real place; without the address it
            // reads as an anonymous number.
            'situs' => $this->situs,
            'city_code' => $this->city_code,
            'property_class' => $this->property_class,
            // [lon, lat] so the UI can fly to a comp.
            'center' => $this->lon !== null ? [(float) $this->lon, (float) $this->lat] : null,
            'values' => [
                'land' => $this->land_value,
                'total' => $this->total_value,
                'appraised' => $this->appraised_value,
            ],
            'vpa' => [
                'land' => $this->land_vpa,
                'total' => $this->total_vpa,
                'appraised' => $this->appraised_vpa,
            ],
            // What this comp is worth relative to the subject, measured — not the
            // multiple that was requested. A subject near the top of the county
            // cannot reach its 4x/16x targets, so target and actual diverge.
            'ratio' => $this->comp_ratio,
            // 1 = same city and acreage band, 2 = band only, 3 = neither.
            'tier' => $this->comp_tier,
        ];
    }
}

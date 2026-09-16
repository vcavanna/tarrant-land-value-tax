<?php

namespace App\Http\Controllers;

use App\Actions\FindComparableParcels;
use App\Http\Resources\ParcelResource;
use App\Models\Parcel;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

/**
 * Selection drawer (spec D.2). Dynamic by product requirement — never CDN-cached,
 * unlike tiles.
 */
class ParcelController extends Controller
{
    public function __construct(private readonly FindComparableParcels $comps) {}

    /**
     * Drawer payload by taxpin.
     *
     * Serves ANY parcel in the curated table, not only map-eligible ones: a
     * direct link to an unmatched parcel or a nominal-value placeholder should
     * resolve and say so via map_eligible, rather than 404 (spec D.2).
     */
    public function showByTaxpin(Request $request, string $taxpin): JsonResponse
    {
        return $this->drawer($request, Parcel::query()->withCenter()->find($taxpin));
    }

    /**
     * Drawer payload by parcel_id — what a map click carries, since Section C
     * moved the tile identifier to the integer surrogate for payload size.
     */
    public function showById(Request $request, int $parcelId): JsonResponse
    {
        return $this->drawer($request, Parcel::query()->withCenter()->where('parcel_id', $parcelId)->first());
    }

    private function drawer(Request $request, ?Parcel $parcel): JsonResponse
    {
        if ($parcel === null) {
            throw new NotFoundHttpException('No such parcel.');
        }

        $parcel->setRelation('comps', ($this->comps)($parcel));

        return ParcelResource::make($parcel)
            ->additional([
                'meta' => [
                    'license' => config('map.license_footer'),
                    'source' => 'Tarrant Appraisal District, 2025 parcel package',
                ],
            ])
            ->response($request);
    }
}

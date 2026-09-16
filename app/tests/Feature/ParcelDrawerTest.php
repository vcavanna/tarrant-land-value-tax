<?php

namespace Tests\Feature;

use App\Models\Parcel;
use PHPUnit\Framework\Attributes\Test;
use Tests\Concerns\UsesLoadedParcels;
use Tests\TestCase;

/**
 * Drawer endpoint contract (spec D.2). The frontend binds to this shape, so the
 * structural assertions here are the contract, not incidental detail.
 */
class ParcelDrawerTest extends TestCase
{
    use UsesLoadedParcels;

    protected function setUp(): void
    {
        parent::setUp();
        $this->useLoadedParcels();
    }

    private function eligibleParcel(): Parcel
    {
        return Parcel::query()->mapEligible()
            ->where('city_code', '026')
            ->whereBetween('acres', [0.2, 0.25])
            ->orderBy('taxpin')
            ->firstOrFail();
    }

    #[Test]
    public function it_returns_the_documented_drawer_shape(): void
    {
        $parcel = $this->eligibleParcel();

        $this->getJson("/api/parcels/{$parcel->taxpin}")
            ->assertOk()
            ->assertJsonStructure([
                'data' => [
                    'taxpin', 'parcel_id', 'acres', 'acres_source', 'accounts',
                    'values' => ['land', 'improvement', 'total', 'appraised'],
                    'vpa' => ['land', 'total', 'appraised'],
                    'classification' => ['property_class', 'state_use'],
                    'location' => ['situs', 'city_code'],
                    'map_eligible',
                    'comps' => [['taxpin', 'parcel_id', 'acres', 'situs', 'city_code',
                        'property_class', 'center',
                        'values' => ['land', 'total', 'appraised'],
                        'vpa' => ['land', 'total', 'appraised'],
                        'ratio', 'tier']],
                ],
                'meta' => ['license', 'source'],
            ]);
    }

    #[Test]
    public function it_resolves_the_same_parcel_by_taxpin_and_by_id(): void
    {
        // A map click carries parcel_id; a shared link carries taxpin.
        $parcel = $this->eligibleParcel();

        $byTaxpin = $this->getJson("/api/parcels/{$parcel->taxpin}")->assertOk()->json('data');
        $byId = $this->getJson("/api/parcels/id/{$parcel->parcel_id}")->assertOk()->json('data');

        $this->assertSame($byTaxpin, $byId);
    }

    #[Test]
    public function it_handles_taxpins_containing_spaces(): void
    {
        // 12,606 taxpins contain spaces, e.g. 'A  85-8' with two.
        $parcel = Parcel::query()->where('taxpin', 'like', '% %')->orderBy('taxpin')->firstOrFail();

        $this->getJson('/api/parcels/'.rawurlencode($parcel->taxpin))
            ->assertOk()
            ->assertJsonPath('data.taxpin', $parcel->taxpin);
    }

    #[Test]
    public function it_404s_for_an_unknown_parcel(): void
    {
        $this->getJson('/api/parcels/NOPE-123')->assertNotFound();
        $this->getJson('/api/parcels/id/99999999')->assertNotFound();
    }

    #[Test]
    public function it_serves_ineligible_parcels_by_direct_url(): void
    {
        // Product rule: a direct link to a parcel that is absent from the map
        // should resolve and say so, not 404.
        $placeholder = Parcel::query()->where('land_value', 1)->firstOrFail();

        $this->getJson('/api/parcels/'.rawurlencode($placeholder->taxpin))
            ->assertOk()
            ->assertJsonPath('data.map_eligible', false);
    }

    #[Test]
    public function an_unmatched_parcel_has_null_values_and_no_comps(): void
    {
        $unmatched = Parcel::query()->where('account_count', 0)->firstOrFail();

        $this->getJson('/api/parcels/'.rawurlencode($unmatched->taxpin))
            ->assertOk()
            ->assertJsonPath('data.accounts', 0)
            ->assertJsonPath('data.map_eligible', false)
            ->assertJsonPath('data.vpa.land', null)
            ->assertJsonCount(0, 'data.comps');
    }

    #[Test]
    public function it_never_exposes_owner_or_pii_fields(): void
    {
        // Spec 1.2: owner name never appears on any public surface. The curated
        // table has no such column, but the drawer must not regain one if the
        // ETL adds fields later.
        $body = $this->getJson('/api/parcels/'.rawurlencode($this->eligibleParcel()->taxpin))
            ->assertOk()->getContent();

        foreach (['owner', 'Owner_Name', 'mail', 'deed'] as $forbidden) {
            $this->assertStringNotContainsStringIgnoringCase($forbidden, $body);
        }
    }

    #[Test]
    public function it_carries_the_tad_licence_in_meta(): void
    {
        $this->getJson('/api/parcels/'.rawurlencode($this->eligibleParcel()->taxpin))
            ->assertOk()
            ->assertJsonPath('meta.license', config('map.license_footer'))
            ->assertJsonFragment(['source' => 'Tarrant Appraisal District, 2025 parcel package']);
    }

    #[Test]
    public function comps_carry_an_address_and_dollar_values(): void
    {
        // A comp is an argument about a real place; without the address and the
        // appraised figure it reads as an anonymous number.
        $comps = $this->getJson('/api/parcels/'.rawurlencode($this->eligibleParcel()->taxpin))
            ->assertOk()->json('data.comps');

        $this->assertNotEmpty($comps);

        foreach ($comps as $comp) {
            $this->assertArrayHasKey('situs', $comp);
            $this->assertNotNull($comp['values']['land']);
            $this->assertNotNull($comp['values']['appraised']);
            // The per-acre figure must agree with the dollar figure it is shown next to.
            $this->assertEqualsWithDelta(
                $comp['values']['land'] / $comp['acres'], $comp['vpa']['land'], 1.0
            );
        }
    }

    #[Test]
    public function the_subject_exposes_dollar_values_alongside_per_acre(): void
    {
        $data = $this->getJson('/api/parcels/'.rawurlencode($this->eligibleParcel()->taxpin))
            ->assertOk()->json('data');

        foreach (['land', 'total', 'appraised'] as $metric) {
            $this->assertNotNull($data['values'][$metric], "values.{$metric} missing");
            $this->assertEqualsWithDelta(
                $data['values'][$metric] / $data['acres'], $data['vpa'][$metric], 1.0
            );
        }
    }

    #[Test]
    public function comp_ratios_are_consistent_with_the_returned_values(): void
    {
        $data = $this->getJson('/api/parcels/'.rawurlencode($this->eligibleParcel()->taxpin))
            ->assertOk()->json('data');

        foreach ($data['comps'] as $comp) {
            $this->assertEqualsWithDelta(
                $comp['vpa']['land'] / $data['vpa']['land'],
                $comp['ratio'],
                0.01,
                "comp {$comp['taxpin']} ratio disagrees with its own land VPA"
            );
        }
    }
}

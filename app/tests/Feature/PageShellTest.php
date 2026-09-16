<?php

namespace Tests\Feature;

use App\Models\Parcel;
use PHPUnit\Framework\Attributes\Test;
use Tests\Concerns\UsesLoadedParcels;
use Tests\TestCase;

/**
 * Page shell and deep links (spec D.5), plus the licence footer on the HTML
 * surface (D.6).
 */
class PageShellTest extends TestCase
{
    use UsesLoadedParcels;

    protected function setUp(): void
    {
        parent::setUp();
        $this->useLoadedParcels();
    }

    #[Test]
    public function the_root_route_serves_the_map_shell(): void
    {
        $this->get('/')
            ->assertOk()
            ->assertViewIs('map')
            ->assertSee('id="map-root"', false)
            ->assertDontSee('data-initial-parcel', false);
    }

    #[Test]
    public function it_renders_the_tad_licence_on_the_page(): void
    {
        // D.6 on the HTML surface. The API carries it in meta; a public map has
        // to show it to a human as well.
        $this->get('/')
            ->assertOk()
            ->assertSee(config('map.license_footer'));
    }

    #[Test]
    public function it_does_not_inject_deploy_constants_into_the_page(): void
    {
        // These belong to /api/map-config. Baking them into HTML is exactly what
        // went stale three times during B.1 and C.5.
        $html = $this->get('/')->assertOk()->getContent();

        foreach (['1500000', '6500000', 'color_min', 'openfreemap'] as $constant) {
            $this->assertStringNotContainsString($constant, $html);
        }
    }

    #[Test]
    public function a_deep_link_carries_the_taxpin_to_the_client(): void
    {
        $parcel = Parcel::query()->mapEligible()->orderBy('taxpin')->firstOrFail();

        $this->get('/parcels/'.rawurlencode($parcel->taxpin))
            ->assertOk()
            ->assertViewIs('map')
            ->assertViewHas('initialParcel', $parcel->taxpin)
            ->assertSee('data-initial-parcel="'.e($parcel->taxpin).'"', false);
    }

    #[Test]
    public function a_deep_link_handles_taxpins_containing_spaces(): void
    {
        $parcel = Parcel::query()->where('taxpin', 'like', '% %')->orderBy('taxpin')->firstOrFail();

        $this->get('/parcels/'.rawurlencode($parcel->taxpin))
            ->assertOk()
            ->assertViewHas('initialParcel', $parcel->taxpin);
    }

    #[Test]
    public function a_deep_link_to_an_ineligible_parcel_still_resolves(): void
    {
        // Consistent with the drawer API: absent from the map, but reachable by
        // direct URL.
        $placeholder = Parcel::query()->where('land_value', 1)->firstOrFail();

        $this->get('/parcels/'.rawurlencode($placeholder->taxpin))->assertOk();
    }

    #[Test]
    public function a_deep_link_to_an_unknown_parcel_404s(): void
    {
        // Fails fast server-side rather than rendering an empty map.
        $this->get('/parcels/NOPE-999')->assertNotFound();
    }

    #[Test]
    public function the_shell_references_built_assets(): void
    {
        $html = $this->get('/')->assertOk()->getContent();

        $this->assertMatchesRegularExpression('#/build/assets/app-[A-Za-z0-9_-]+\.js#', $html);
        $this->assertMatchesRegularExpression('#/build/assets/app-[A-Za-z0-9_-]+\.css#', $html);
    }
}

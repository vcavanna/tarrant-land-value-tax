<?php

namespace Tests\Feature;

use App\Actions\FindComparableParcels;
use App\Models\Parcel;
use PHPUnit\Framework\Attributes\Test;
use Tests\Concerns\UsesLoadedParcels;
use Tests\TestCase;

/**
 * Integration tests for the comps ladder (spec D.8).
 *
 * The parcels table is owned by the ETL, not by Laravel migrations, so there is
 * no factory to build fixtures from — the loaded county IS the fixture. These
 * therefore run against the real pgsql connection and skip when it is absent,
 * rather than against the suite's default in-memory SQLite.
 */
class FindComparableParcelsTest extends TestCase
{
    use UsesLoadedParcels;

    private FindComparableParcels $comps;

    protected function setUp(): void
    {
        parent::setUp();

        $this->useLoadedParcels();

        $this->comps = new FindComparableParcels();
    }

    private function subject(float $minAcres = 0.2, float $maxAcres = 0.25): Parcel
    {
        return Parcel::query()->mapEligible()
            ->where('city_code', '026')
            ->whereBetween('acres', [$minAcres, $maxAcres])
            ->orderBy('taxpin')
            ->firstOrFail();
    }

    #[Test]
    public function it_returns_three_comps_for_an_ordinary_parcel(): void
    {
        $this->assertCount(3, ($this->comps)($this->subject()));
    }

    #[Test]
    public function it_never_returns_the_subject_or_duplicates(): void
    {
        $subject = $this->subject();
        $taxpins = ($this->comps)($subject)->pluck('taxpin');

        $this->assertNotContains($subject->taxpin, $taxpins);
        $this->assertSame($taxpins->unique()->count(), $taxpins->count());
    }

    #[Test]
    public function it_only_returns_map_eligible_comps(): void
    {
        // The guard that keeps TAD's nominal $1 placeholders out of the drawer.
        foreach (($this->comps)($this->subject()) as $comp) {
            $this->assertTrue($comp->map_eligible);
            $this->assertGreaterThan(1000, $comp->land_value);
        }
    }

    #[Test]
    public function it_hits_its_multiplier_targets_when_the_county_allows(): void
    {
        $subject = $this->subject();

        foreach (($this->comps)($subject) as $comp) {
            $target = $subject->land_vpa * $comp->comp_target_multiple;
            // Within 25% of target: the county is dense enough mid-range that a
            // near-exact match should always exist.
            $this->assertEqualsWithDelta($target, $comp->land_vpa, $target * 0.25);
        }
    }

    #[Test]
    public function each_comp_is_the_genuinely_nearest_parcel_to_its_target(): void
    {
        // Stronger than the delta assertion above, which a merely-close match
        // also satisfies. This asserts optimality: nothing eligible in the same
        // tier sits closer to the target. It is the regression guard for the
        // index-walk rewrite, which once returned the farther of the two sides
        // (4.83 away instead of 4.49) while still passing every other test.
        $subject = $this->subject();

        foreach (($this->comps)($subject) as $comp) {
            if ($comp->comp_tier !== 1) {
                continue;   // tiers 2-3 search a wider set; compare like with like
            }

            $target = $subject->land_vpa * $comp->comp_target_multiple;

            $closest = Parcel::query()->mapEligible()
                ->whereKeyNot($subject->taxpin)
                ->whereNotNull('land_vpa')
                ->where('city_code', $subject->city_code)
                ->whereBetween('acres', [$subject->acres * 0.5, $subject->acres * 2])
                ->orderByRaw('abs(land_vpa - ?)', [$target])
                ->orderBy('taxpin')
                ->firstOrFail();

            $this->assertEqualsWithDelta(
                abs($closest->land_vpa - $target),
                abs($comp->land_vpa - $target),
                0.01,
                "comp {$comp->taxpin} is not the nearest to the {$comp->comp_target_multiple}x "
                    ."target; {$closest->taxpin} is closer"
            );
        }
    }

    #[Test]
    public function it_returns_different_comps_for_different_subjects(): void
    {
        // The regression guard for the degenerate ABS(delta) DESC ordering, which
        // gave 40 subjects only 8 distinct comp sets.
        $sets = Parcel::query()->mapEligible()
            ->where('city_code', '026')
            ->whereBetween('acres', [0.1, 0.5])
            ->orderBy('taxpin')->limit(20)->get()
            ->map(fn (Parcel $s) => ($this->comps)($s)->pluck('taxpin')->sort()->implode('|'))
            ->unique();

        $this->assertGreaterThan(15, $sets->count());
    }

    #[Test]
    public function it_falls_back_past_tier_one_in_a_sparse_city(): void
    {
        // City 043 has 13 source rows countywide; the acreage band cannot be
        // filled from within it, so tier 2 must drop the city constraint.
        $subject = Parcel::query()->mapEligible()->where('city_code', '043')->first();

        if ($subject === null) {
            $this->markTestSkipped('no eligible parcel in city 043');
        }

        $result = ($this->comps)($subject);

        $this->assertCount(3, $result);
        $this->assertGreaterThan(1, $result->max('comp_tier'));
    }

    #[Test]
    public function it_reports_the_actual_ratio_not_the_requested_target(): void
    {
        // The county's highest-VPA parcel cannot reach its 4x or 16x targets, so
        // the displayed ratio must reflect what was really found.
        $top = Parcel::query()->mapEligible()->orderByDesc('land_vpa')->firstOrFail();

        foreach (($this->comps)($top) as $comp) {
            $this->assertEqualsWithDelta(
                $comp->land_vpa / $top->land_vpa, $comp->comp_ratio, 0.01
            );
            $this->assertLessThan(1.0, $comp->comp_ratio);
        }
    }

    #[Test]
    public function it_returns_no_comps_for_a_parcel_with_no_value(): void
    {
        // Unmatched parcels (account_count = 0) are served by the drawer via a
        // direct URL but have no land VPA to contrast against.
        $unmatched = Parcel::query()->where('account_count', 0)->firstOrFail();

        $this->assertTrue(($this->comps)($unmatched)->isEmpty());
    }

    #[Test]
    public function it_is_deterministic(): void
    {
        $subject = $this->subject();

        $this->assertSame(
            ($this->comps)($subject)->pluck('taxpin')->all(),
            ($this->comps)($subject)->pluck('taxpin')->all()
        );
    }
}

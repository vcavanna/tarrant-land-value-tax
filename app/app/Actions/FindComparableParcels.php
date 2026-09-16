<?php

namespace App\Actions;

use App\Models\Parcel;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;

/**
 * Comparable parcels for the selection drawer (spec 10.3).
 *
 * These are not real-estate comps. The point is contrast: what land of a similar
 * size is worth elsewhere, which is the argument the map is making about land use.
 * Sorting by nearest value would show near-identical neighbours and say nothing.
 *
 * The spec originally ordered by `ABS(land_vpa - subject) DESC`. Measured against
 * the loaded county that rule degenerates: land VPA is heavily right-skewed
 * (median $311k, max $36M), so `|c - V|` is maximised by the largest `c` in the
 * band for virtually every subject, regardless of V. 40 random Fort Worth
 * subjects produced only 8 distinct comp sets, one parcel appearing in 36 of them.
 * The drawer became a static "top 3 in your city" list.
 *
 * Instead each comp is drawn from a MULTIPLIER TARGET: the parcel closest to
 * 0.25x, 4x and 16x the subject's land VPA. Contrast is preserved — a quarter of
 * yours, four times, sixteen times — but the answer now moves with the subject.
 *
 * Comps always compare on LAND vpa, even when the map is painted by total or
 * appraised, until the product says otherwise.
 *
 * Each tier widens the search and fills only the slots left over:
 *   1. same city, acres within [0.5x, 2x]
 *   2. drop city, keep the acreage band
 *   3. drop acreage too — anything eligible
 *
 * Every tier runs as a single indexed query in Postgres. Candidate filtering and
 * ordering must not move into PHP: the eligible set is ~674k rows and tier 3 is
 * unbounded, so collection filtering would pull the county across the wire.
 */
class FindComparableParcels
{
    public const LIMIT = 3;

    /**
     * Value multiples to hunt for, relative to the subject's land VPA. Ordered
     * as they should read in the drawer: cheaper first, then the escalation.
     */
    public const TARGET_MULTIPLES = [0.25, 4.0, 16.0];

    /** Acreage band multipliers for tiers 1 and 2. */
    private const ACRES_MIN_FACTOR = 0.5;

    private const ACRES_MAX_FACTOR = 2.0;

    /**
     * @return Collection<int, Parcel>
     */
    public function __invoke(Parcel $subject, int $limit = self::LIMIT): Collection
    {
        // A subject with no land VPA has nothing to be different from, and one
        // with no acres cannot define a band. Both are possible via direct URL:
        // ineligible parcels are still served by the drawer.
        if ($subject->land_vpa === null || $subject->acres === null) {
            return collect();
        }

        $found = collect();
        $targets = array_slice(self::TARGET_MULTIPLES, 0, $limit);

        // One query per target, widening through the tiers until that target
        // finds a parcel. A target that can only be satisfied by a parcel
        // already chosen is skipped rather than duplicated.
        foreach ($targets as $multiple) {
            $target = $subject->land_vpa * $multiple;

            foreach ($this->tiers($subject) as $tier => $constrain) {
                $comp = $this->nearest($subject, $constrain, $found, $target);

                if ($comp !== null) {
                    $comp->setAttribute('comp_tier', $tier);
                    // Provenance: which target produced this comp.
                    $comp->setAttribute('comp_target_multiple', $multiple);
                    // What the drawer should actually display. A subject near the
                    // top of the county cannot reach its 4x or 16x target, and the
                    // nearest available parcel may be well BELOW it -- labelling
                    // that comp "16x" would be a lie. Always show the real ratio.
                    $comp->setAttribute(
                        'comp_ratio',
                        $subject->land_vpa > 0 ? round($comp->land_vpa / $subject->land_vpa, 2) : null
                    );
                    $found->push($comp);
                    break;
                }
            }
        }

        // Sorted by value so the drawer reads as an escalation regardless of which
        // targets were reachable. A subject at the very top or bottom of the
        // county simply gets fewer comps rather than duplicates.
        return $found->sortBy('land_vpa')->values();
    }

    /**
     * The tier ladder, widest constraint first.
     *
     * @return array<int, callable(Builder): Builder>
     */
    private function tiers(Parcel $subject): array
    {
        $band = fn (Builder $q): Builder => $q->whereBetween('acres', [
            $subject->acres * self::ACRES_MIN_FACTOR,
            $subject->acres * self::ACRES_MAX_FACTOR,
        ]);

        return [
            1 => fn (Builder $q): Builder => $band($q)->where('city_code', $subject->city_code),
            2 => $band,
            3 => fn (Builder $q): Builder => $q,
        ];
    }

    /**
     * The parcel whose land VPA is nearest to $target.
     *
     * Deliberately NOT `ORDER BY abs(land_vpa - target) LIMIT 1`. That expression
     * is not indexable, so Postgres had to examine every candidate: measured at
     * 108 ms per target over a parallel sequential scan of 83,763 rows, roughly
     * 325 ms of a drawer request.
     *
     * Walking outward from the target in both directions turns it into two
     * ordered index scans returning one row each — 0.1 ms — and the nearest of
     * the two is the answer. See parcels_city_vpa_idx / parcels_vpa_idx.
     *
     * @param  Collection<int, Parcel>  $exclude
     * @param  callable(Builder): Builder  $constrain
     */
    private function nearest(Parcel $subject, callable $constrain, Collection $exclude, float $target): ?Parcel
    {
        $sides = collect([['>=', 'asc'], ['<=', 'desc']])
            ->map(fn (array $side) => $this->candidates($subject, $constrain, $exclude)
                ->where('land_vpa', $side[0], $target)
                ->orderBy('land_vpa', $side[1])
                // Deterministic within ties; an Incremental Sort, so the index
                // scan is preserved.
                ->orderBy('taxpin')
                ->first())
            ->filter();

        // Explicit rather than sortBy(): a multi-criteria sortBy with a closure
        // criterion silently returned the farther of the two sides here, and a
        // two-element comparison does not need a sort anyway.
        return $sides->reduce(function (?Parcel $best, Parcel $candidate) use ($target): Parcel {
            if ($best === null) {
                return $candidate;
            }

            $delta = abs($candidate->land_vpa - $target) <=> abs($best->land_vpa - $target);

            // Equidistant above and below: fall back to taxpin so the choice is
            // stable across requests.
            return $delta < 0 || ($delta === 0 && strcmp($candidate->taxpin, $best->taxpin) < 0)
                ? $candidate
                : $best;
        });
    }

    /**
     * @param  Collection<int, Parcel>  $exclude
     * @param  callable(Builder): Builder  $constrain
     */
    private function candidates(Parcel $subject, callable $constrain, Collection $exclude): Builder
    {
        $query = Parcel::query()
            ->withCenter()
            ->mapEligible()
            ->whereKeyNot($subject->taxpin)
            // Tier 1 filters on city_code, which is NULL for parcels with no
            // account; whereKeyNot already covers the subject, but a NULL city
            // subject would otherwise match nothing and silently fall to tier 2.
            ->whereNotNull('land_vpa');

        if ($exclude->isNotEmpty()) {
            $query->whereNotIn('taxpin', $exclude->pluck('taxpin'));
        }

        return $constrain($query);
    }
}

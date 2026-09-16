# Field notes: what was hard

Written for someone who has never opened this repo. It is not a spec — the spec is
[VALUE_PER_ACRE_SPEC.md](VALUE_PER_ACRE_SPEC.md) — it is the story of the things that went
wrong, what the data actually turned out to be, and which decisions had to be made by
measurement rather than judgement.

**The project:** a public web map of all 690,000 parcels in Tarrant County, Texas, coloured by
**value per acre**. The argument it exists to make is that a small downtown lot can out-earn a
large suburban one by orders of magnitude, so you should be able to see that on a map.

**The stack:** PostGIS holds the data, [Martin](https://maplibre.org/martin/) turns it into
vector tiles, Laravel serves a JSON API, MapLibre draws it in the browser.

---

## 1. The source data is stranger than its documentation

The county ships a 596 MB Esri File Geodatabase: 689,933 parcel polygons and 716,370 appraisal
records, joined on a parcel id. Straightforward on paper. In practice:

### The "exempt" column is inert

The spec said to exclude tax-exempt parcels from the map. There is an `EXEMPTSTATUS` column, so
this looked like a one-line filter. It is `'Non-Exempt'` on **99.98%** of rows, and the remaining
145 values are nulls, blanks, and junk: `'3'`, `'.'`, `'+'`, `'r'`, `'H'`. Applying the filter
removed **zero** parcels.

The real explanation is that this package contains taxable property only — churches, schools and
government land simply are not in it. The rule was dropped rather than faked. A column existing
is not the same as a column meaning something.

### 8,164 parcels are worth exactly $1

A random spot-check surfaced a parcel with a land value of `1`. It turned out there are **8,164**
of them, plus 799 at exactly `$100` — about 1.5% of the county. They are overwhelmingly vacant
residential lots, HOA common areas and drainage easements: land the appraiser carries at a
**nominal** value rather than a real one.

The give-away is in the data. Three parcels with different addresses share an identical
`59.20644513` acres — one physical common-area tract repeated once per lot owner. The largest is
a **157-acre tract on Lake Worth carried at $1**, almost certainly city water utility land. (Note
that this is exactly the population the broken exempt column was supposed to catch.)

These matter less for colour than for the **comparables** feature, which by design looks for the
*most different* nearby parcel. A $1 placeholder is maximally different from everything, so
without a filter every drawer in the county would have shown three meaningless comps. The fix was
a `land_value > 1000` floor, chosen because measured land value-per-acre jumps from **$18 at the
1st percentile to $9,858 at the 2nd** — a cliff with junk below it and real land above.

Not filtered out: 50 parcels with genuinely low value-per-acre, mostly agricultural. Texas taxes
farmland on its *productivity* rather than market value, so 12 acres at $2,000 is a real
appraisal. Placeholders are round numbers unrelated to size; ag land scales with acreage.

### One parcel has 296 owners

The highest value-per-acre in the county is `42371C---09`, at **501 Throckmorton St, Fort
Worth**: 0.44 acres, $36M per acre. That looked like an error until we looked at the accounts —
**296** of them, nearly all condo units with addresses like `500 THROCKMORTON ST # 2612`. Unit
numbers in the 2600s mean the 26th floor.

It is a residential tower. The parcel is its footprint; every condo carries its own slice of land
value, and summing them gives $15.8M on a tenth of a city block. So the extreme outlier is not a
data error — **it is the thesis of the map**. Stack 296 homes on half an acre and the land earns
two orders of magnitude more per acre than a suburban lot.

### Sixteen rows break the primary key

`TAXPIN` is *nearly* unique: 16 blank and 16 duplicated rows across 7 keys. The duplicates are
three different problems wearing one hat:

- exact duplicate rows,
- a real polygon paired with a degenerate 0.78 sq ft sliver,
- genuinely **multi-part** parcels (one tax id, two disjoint pieces).

`MAX(acres)` truncates the multi-part ones; `SUM(acres)` triple-counts the sliver cases. The rule
that works for all three is to union the geometry and derive acres from the unioned area.

### "City" is a number

The city field is a 43-value numeric code — `026` is Fort Worth — with no lookup table shipped in
the package. Comparables group on the code correctly, but the drawer displays `026` until someone
sources the county's code table.

### Sliver parcels produce absurd values

Before any floor, the maximum land value per acre was **$1.48 billion** — a 0.000534-acre scrap
holding $792k. A **0.005-acre (218 sq ft)** floor removes 142 parcels (0.02%) and kills both
artifacts. Going higher stops paying off, because the next parcel down is legitimate downtown
commercial land.

---

## 2. Three constants that had to be measured, not chosen

### The colour cap was wrong by a factor of 300

The original design said: pick a cap, colour everything above it black. The chosen value was
**5,000**. The measured **median** land value per acre in Tarrant County is **$307,478**.

At a cap of 5,000, **98.26% of the county rendered black**. The design had been written before
anyone had the data.

Worse, one cap cannot serve all three metrics — land and total value-per-acre differ by roughly
5×. Caps became per-metric, set near each metric's 99th percentile, which put about 1% of parcels
over cap.

Then we looked at the rendered map. **The over-cap parcels are not scattered — they are
downtown.** 1.25% of the county was black, and it was the single area a visitor looks at first.
The most valuable land in Tarrant County was one undifferentiated blob. Statistically defensible,
visually the worst possible answer. Caps moved again, to roughly p99.95: downtown black fell from
**49.2% to 1.1%**.

The remaining limitation is honest and still open: the colour *ramp* spans the 5th to 95th
percentile ($72k–$808k), but downtown's median is $1.38M — above the top of the ramp. Downtown
now saturates dark rather than black. Fixing that properly means a **log scale**, because the
distribution is extremely skewed (median $311k, max $36M).

### The 3D height multiplier made walls

3D mode extrudes each parcel to `min(value, cap) × k`. `k` is not configured directly — it is
derived as `ceiling / cap`, so every metric tops out at the same height and the metric toggle
stays comparable. Configuring `k` by hand is exactly how it drifts away from the cap.

The first ceiling was **3,000 m**. Nobody had looked at it. Rendered, a $609k/acre parcel
extruded **1,219 m** on a lot about 40 m wide: the city was a set of vertical walls running off
the top of the screen. Dropped to 300 m, it read as buildings.

Then the cap tripled — and because `k = ceiling / cap`, that silently flattened every ordinary
parcel by the same factor. The ceiling had to rise to 1,000 m to keep the view that had been
approved. **Derived constants move when their inputs move**, which is an argument for deriving
them and an argument for looking again afterwards.

### Minimum zoom, and why the obvious tile isn't the biggest

Vector tiles have a budget. Show parcels too far out and each tile carries too many features.

The design guessed parcels should appear around zoom 11–13. Measuring every tile covering the
county gave: **z12 median 1.59 MB**, **z13 median 213 kB / max 578 kB**, **z14 median 53 kB**.
z14 shipped first; z13 after the map proved too restrictive in use.

**z12 is unreachable.** A z12 tile holds 30,758 parcels and stays over 1 MB even stripped to one
property and simplified three times over. The only lever is an acreage filter, and getting to a
sane size means dropping **79% of parcels** — emptying the suburbs. That is a change to what the
map *shows*, not a tuning decision, so it was left alone.

Two things surprised us:

**The densest tile is not downtown.** Suburban subdivisions beat it — many small lots rather than
a few large commercial ones. Sampling the obviously-dense spot picked the wrong number; only
sizing all 156 tiles revealed it.

**Simplifying geometry barely helps.** The spec pointed at simplification tolerance as the knob to
tune. Measured, **geometry is only ~25% of a tile's bytes** — the properties are 75%. Tripling the
simplification took a tile from 263 kB to 261 kB. The real wins were elsewhere: rounding values to
whole dollars (−23%), and moving the parcel identifier out of the properties into MVT's dedicated
**feature-id** slot, which is varint-encoded (−41% total).

---

## 3. A feature that was specified wrong

The drawer shows three "comparable" parcels. The spec ordered them by *largest difference* in
value per acre — deliberately, to show contrast rather than similarity.

Implemented and run against real data, that rule collapses. Land value is heavily right-skewed,
so "the most different parcel" is the highest-value parcel in the search area **for virtually
every subject**, regardless of what the subject is worth. Measured: **40 random Fort Worth
parcels produced only 8 distinct comparable sets**, with one parcel appearing in 36 of them. The
drawer had become a static "top 3 in your city" list.

The replacement picks the parcel nearest **0.25×, 4× and 16×** the subject's value — a quarter of
yours, four times, sixteen times. Contrast is preserved, but the answer now moves with the
subject: 40 subjects, **40 distinct sets**.

One subtlety: a parcel near the very top of the county cannot reach its 16× target, and the
nearest available parcel may be *below* it. Labelling that "16×" would be a lie, so comparables
carry both the requested multiple and the **actual** ratio, and the UI shows the actual one.

---

## 4. The map rendered blank three times, for three unrelated reasons

Every endpoint returned correct data, the page returned HTTP 200, and 36 tests passed — while the
browser showed nothing, with no error in the console. Three separate causes, each invisible from
the command line:

**1. A CSS cascade-layer collision.** The map container had `class="absolute inset-0"` but
computed to `position: relative`, collapsing it to **zero height**. MapLibre ships *unlayered*
CSS; Tailwind 4 puts its utilities in `@layer`; and **unlayered CSS beats layered CSS regardless
of specificity or source order**. Fixed by importing MapLibre's stylesheet into a low-priority
layer.

**2. A web worker that no bundler could see.** MapLibre v6 builds its worker URL at runtime by
concatenating a filename onto `import.meta.url`. That is invisible to static analysis, so Vite
emitted no such file, the request 404'd, and without a worker MapLibre parses no tiles and never
finishes loading. A small build plugin now copies the worker (and its dependency) into the output
with exact names. **This fails silently and should be re-checked after any bundler upgrade.**

**3. The browser tab was not focused.** MapLibre renders inside `requestAnimationFrame`, which
Chrome throttles in background tabs. The map loads its style, fetches its worker, and then paints
nothing and requests no tiles — indistinguishable from a hang. This cost the most time of the
three, because everything really was working.

---

## 5. Two bugs of the same shape, an hour apart

A reverse proxy sits in front of both the tile server and the app so everything is same-origin.
It was rewriting the `Host` header to the upstream address.

Both upstreams build absolute URLs from that header. Martin advertised its own private port in
the tile metadata, so the map would have fetched tiles *around* the proxy. Laravel then did the
same thing with its asset URLs. Both worked locally by accident and would have broken behind a
real domain.

The fix is one line — forward the original `Host`, as nginx does by default — but it was applied
narrowly the first time and had to be applied again. **Any upstream that builds absolute URLs is
exposed to this**, which is worth knowing before adding a third.

---

## 6. Two lessons worth carrying

**A tolerance assertion is not a correctness assertion.** An optimisation to the comparables
query — 108 ms down to 0.1 ms, by walking an ordered index outward from a target instead of
sorting by distance — silently returned the *second*-nearest parcel. Every test still passed,
because the assertion was "within 25% of target," which a merely-close answer also satisfies. It
was caught by diffing output against the pre-optimisation version. The replacement test asserts
**optimality**: nothing eligible sits closer.

**Look at it.** Roughly half the problems here were invisible to tests and curl: the cap that
blacked out downtown, the 3,000 m walls, the comparables that were identical for everyone, all
three blank-page causes. The data was verified long before anyone saw it rendered, and the
rendering is where the product decisions actually live.

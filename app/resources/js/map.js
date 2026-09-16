// MapLibre GL JS v6 removed the default export; named imports only.
import { Map as MapLibreMap, NavigationControl, ScaleControl } from 'maplibre-gl';

/**
 * Tarrant County value-per-acre map (Section E shell; D.5 hosts it).
 *
 * Every deploy constant — cap, k, colour domain, minzoom, tile URL, basemap,
 * bounds — comes from /api/map-config. Nothing here is hard-coded, because all
 * of those values have already changed at least once during the build.
 */

const LAYER = 'parcels-fill';

/** Sequential ramp; over-cap parcels are painted flat black instead. */
const RAMP = ['#fff5eb', '#fdd0a2', '#fd8d3c', '#d94801', '#7f2704'];

const money = (n) =>
    n === null || n === undefined ? '—' : '$' + Math.round(n).toLocaleString();

function fillColor(cfg, metric) {
    const { cap, color_min: min, color_max: max } = cfg.metrics[metric];
    const stops = RAMP.flatMap((color, i) => [min + ((max - min) * i) / (RAMP.length - 1), color]);

    return [
        'case',
        ['>', ['get', `${metric}_vpa`], cap], '#000000',
        ['interpolate', ['linear'], ['get', `${metric}_vpa`], ...stops],
    ];
}

function extrusionHeight(cfg, metric) {
    // height = min(vpa, cap) * k, with k derived server-side so every metric
    // reaches the same ceiling (spec 10.2).
    const { cap, k } = cfg.metrics[metric];
    return ['*', ['min', ['get', `${metric}_vpa`], cap], k];
}

export default async function boot(root) {
    const res = await fetch('/api/map-config');
    if (!res.ok) throw new Error(`map-config: HTTP ${res.status}`);
    const { data: cfg } = await res.json();

    let metric = cfg.default_metric;
    let mode = cfg.default_mode;

    const map = new MapLibreMap({
        container: 'map',
        style: cfg.basemap.style,
        center: cfg.view.center,
        zoom: cfg.tiles.minzoom + 1,
        maxBounds: [
            [cfg.view.bounds[0] - 0.3, cfg.view.bounds[1] - 0.3],
            [cfg.view.bounds[2] + 0.3, cfg.view.bounds[3] + 0.3],
        ],
    });
    // A map that fails to initialise renders as a blank page with no thrown
    // error, so surface MapLibre's own error channel.
    map.on('error', (e) => console.error('[map]', e?.error?.message ?? e));
    if (import.meta.env.DEV) {
        window.__map = map;
    }
    map.addControl(new NavigationControl({ visualizePitch: true }), 'top-right');
    map.addControl(new ScaleControl({ unit: 'imperial' }), 'bottom-right');

    const ui = buildChrome(root, cfg);

    map.on('load', () => {
        map.addSource('parcels', {
            type: 'vector',
            // Same-origin. Deliberately not Martin's TileJSON, which advertises
            // the tile server's own address.
            tiles: [location.origin + cfg.tiles.url],
            minzoom: cfg.tiles.minzoom,
            maxzoom: cfg.tiles.maxzoom,
            promoteId: undefined, // feature id is already the MVT id (parcel_id)
        });

        map.addLayer({
            id: LAYER,
            type: 'fill',
            source: 'parcels',
            'source-layer': cfg.tiles.source_layer,
            minzoom: cfg.tiles.minzoom,
            paint: {
                'fill-color': fillColor(cfg, metric),
                'fill-opacity': 0.75,
                'fill-outline-color': 'rgba(0,0,0,0.25)',
            },
        });

        map.addLayer({
            id: 'parcels-3d',
            type: 'fill-extrusion',
            source: 'parcels',
            'source-layer': cfg.tiles.source_layer,
            minzoom: cfg.tiles.minzoom,
            layout: { visibility: 'none' },
            paint: {
                'fill-extrusion-color': fillColor(cfg, metric),
                'fill-extrusion-height': extrusionHeight(cfg, metric),
                'fill-extrusion-opacity': 0.9,
            },
        });

        // Highlight for the selected parcel.
        map.addLayer({
            id: 'parcels-selected',
            type: 'line',
            source: 'parcels',
            'source-layer': cfg.tiles.source_layer,
            minzoom: cfg.tiles.minzoom,
            paint: { 'line-color': '#0ea5e9', 'line-width': 3 },
            filter: ['==', ['id'], -1],
        });

        ui.renderLegend(metric);
        wire();
        openDeepLink();
    });

    function repaint() {
        map.setPaintProperty(LAYER, 'fill-color', fillColor(cfg, metric));
        map.setPaintProperty('parcels-3d', 'fill-extrusion-color', fillColor(cfg, metric));
        map.setPaintProperty('parcels-3d', 'fill-extrusion-height', extrusionHeight(cfg, metric));
        ui.renderLegend(metric);
    }

    function setMode(next) {
        mode = next;
        const is3d = mode === '3d';
        map.setLayoutProperty(LAYER, 'visibility', is3d ? 'none' : 'visible');
        map.setLayoutProperty('parcels-3d', 'visibility', is3d ? 'visible' : 'none');
        map.easeTo({ pitch: is3d ? 55 : 0, duration: 400 });
        ui.syncMode(mode);
    }

    function wire() {
        ui.onMetric((next) => {
            // A paint change only: all three VPA columns are already in the
            // tile, so switching metric fetches nothing.
            metric = next;
            repaint();
        });

        ui.onMode(setMode);

        map.on('click', LAYER, (e) => select(e.features[0].id, { fly: false }));
        map.on('click', 'parcels-3d', (e) => select(e.features[0].id, { fly: false }));
        map.on('mouseenter', LAYER, () => (map.getCanvas().style.cursor = 'pointer'));
        map.on('mouseleave', LAYER, () => (map.getCanvas().style.cursor = ''));
    }

    async function select(parcelId, { fly = true } = {}) {
        ui.drawerLoading();
        map.setFilter('parcels-selected', ['==', ['id'], Number(parcelId)]);

        const r = await fetch(`/api/parcels/id/${parcelId}`);
        if (!r.ok) return ui.drawerError(r.status);
        const { data } = await r.json();

        ui.renderDrawer(data, metric, {
            onComp: (comp) => {
                if (comp.center) map.flyTo({ center: comp.center, zoom: 17 });
                select(comp.parcel_id, { fly: false });
            },
        });

        if (fly && data.location.center) {
            map.flyTo({ center: data.location.center, zoom: 17 });
        }

        // Deep-linkable without a reload.
        history.replaceState({}, '', `/parcels/${encodeURIComponent(data.taxpin)}`);
    }

    async function openDeepLink() {
        const taxpin = root.dataset.initialParcel;
        if (!taxpin) return;

        ui.drawerLoading();
        const r = await fetch(`/api/parcels/${encodeURIComponent(taxpin)}`);
        if (!r.ok) return ui.drawerError(r.status);
        const { data } = await r.json();

        if (data.location.center) {
            map.jumpTo({ center: data.location.center, zoom: 17 });
        }
        // Re-run through select() so the highlight and drawer match a click.
        select(data.parcel_id, { fly: false });
    }

    return { map, select };
}

/** Builds the panel and drawer; returns the handful of hooks boot() needs. */
function buildChrome(root, cfg) {
    const panel = document.createElement('div');
    panel.className =
        'absolute left-3 top-3 z-10 w-[19rem] max-w-[calc(100vw-1.5rem)] space-y-3 ' +
        'rounded-lg bg-white/95 p-3 shadow-lg backdrop-blur';
    panel.innerHTML = `
      <div>
        <h1 class="text-sm font-semibold">Tarrant County · value per acre</h1>
        <p class="text-xs text-neutral-500">Click a parcel for detail and comparable land.</p>
      </div>
      <div>
        <div class="mb-1 text-[11px] font-medium uppercase tracking-wide text-neutral-500">Metric</div>
        <div class="flex gap-1" data-metrics>
          ${Object.entries(cfg.metrics)
              .map(
                  ([key, m]) => `
            <button type="button" data-metric="${key}"
              class="flex-1 rounded border px-2 py-1 text-xs transition
                     aria-pressed:border-neutral-900 aria-pressed:bg-neutral-900 aria-pressed:text-white"
              aria-pressed="${key === cfg.default_metric}">${m.label}</button>`
              )
              .join('')}
        </div>
      </div>
      <div>
        <div class="mb-1 text-[11px] font-medium uppercase tracking-wide text-neutral-500">View</div>
        <div class="flex gap-1" data-modes>
          <button type="button" data-mode="color"
            class="flex-1 rounded border px-2 py-1 text-xs
                   aria-pressed:border-neutral-900 aria-pressed:bg-neutral-900 aria-pressed:text-white"
            aria-pressed="true">2D colour</button>
          <button type="button" data-mode="3d"
            class="flex-1 rounded border px-2 py-1 text-xs
                   aria-pressed:border-neutral-900 aria-pressed:bg-neutral-900 aria-pressed:text-white"
            aria-pressed="false">3D height</button>
        </div>
      </div>
      <div data-legend></div>
      <div data-drawer class="border-t border-neutral-200 pt-2 text-xs text-neutral-600">
        Zoom in to z${cfg.tiles.minzoom} to see parcels.
      </div>`;
    root.appendChild(panel);

    const legend = panel.querySelector('[data-legend]');
    const drawer = panel.querySelector('[data-drawer]');

    const press = (sel, attr, value) =>
        panel.querySelectorAll(sel).forEach((b) =>
            b.setAttribute('aria-pressed', String(b.dataset[attr] === value))
        );

    return {
        renderLegend(metric) {
            const m = cfg.metrics[metric];
            const pct = ((100 * m.over_cap_count) / m.eligible_count).toFixed(2);
            legend.innerHTML = `
              <div class="h-2.5 rounded border border-neutral-300"
                   style="background:linear-gradient(90deg, ${RAMP.join(',')})"></div>
              <div class="mt-1 flex justify-between text-[10px] text-neutral-500">
                <span>${money(m.color_min)}/ac</span><span>${money(m.color_max)}/ac</span>
              </div>
              <div class="text-[10px] text-neutral-500">
                black = over ${money(m.cap)}/ac (${pct}% of ${m.eligible_count.toLocaleString()})
              </div>`;
        },

        syncMode(mode) {
            press('[data-modes] button', 'mode', mode);
        },

        onMetric(fn) {
            panel.querySelectorAll('[data-metrics] button').forEach((b) => {
                b.onclick = () => {
                    press('[data-metrics] button', 'metric', b.dataset.metric);
                    fn(b.dataset.metric);
                };
            });
        },

        onMode(fn) {
            panel.querySelectorAll('[data-modes] button').forEach((b) => {
                b.onclick = () => fn(b.dataset.mode);
            });
        },

        drawerLoading() {
            drawer.innerHTML = '<span class="text-neutral-400">Loading…</span>';
        },

        drawerError(status) {
            drawer.innerHTML = `<span class="text-red-600">Could not load parcel (HTTP ${status}).</span>`;
        },

        renderDrawer(data, metric, { onComp }) {
            // Per-acre is the map's metric, but the appraised dollar figure is
            // what a reader recognises, so show both side by side.
            const rows = Object.keys(cfg.metrics)
                .map((m) => {
                    const strong = m === metric;
                    return `<div class="flex items-baseline justify-between gap-2 ${strong ? 'font-semibold text-neutral-900' : ''}">
                        <span>${cfg.metrics[m].label}</span>
                        <span class="flex-1 text-right tabular-nums text-neutral-400">${money(data.values[m])}</span>
                        <span class="w-24 text-right tabular-nums">${money(data.vpa[m])}/ac</span>
                      </div>`;
                })
                .join('');

            drawer.innerHTML = `
              <div class="space-y-2">
                <div>
                  <div class="text-sm font-semibold text-neutral-900">
                    ${data.location.situs ?? data.taxpin}
                  </div>
                  <div class="text-[11px] text-neutral-500">
                    ${data.taxpin} · ${data.classification.property_class ?? '—'}
                    · ${data.acres?.toFixed(3) ?? '—'} ac
                    ${data.accounts > 1 ? ` · ${data.accounts} accounts` : ''}
                  </div>
                </div>
                ${!data.map_eligible ? '<div class="rounded bg-amber-50 px-2 py-1 text-[11px] text-amber-800">Not shown on the map.</div>' : ''}
                <div class="space-y-0.5">
                  <div class="flex items-baseline justify-between gap-2 text-[10px] uppercase tracking-wide text-neutral-400">
                    <span>Metric</span><span class="flex-1 text-right">Value</span><span class="w-24 text-right">Per acre</span>
                  </div>
                  ${rows}
                </div>
                ${
                    data.comps.length
                        ? `<div class="border-t border-neutral-200 pt-2">
                             <div class="mb-1 text-[11px] font-medium uppercase tracking-wide text-neutral-500">
                               Comparable land
                             </div>
                             <div class="space-y-1" data-comps>
                               ${data.comps
                                   .map(
                                       (c, i) => `
                                 <button type="button" data-comp="${i}"
                                   class="block w-full rounded px-1 py-1 text-left hover:bg-neutral-100">
                                   <div class="flex items-baseline justify-between gap-2">
                                     <span class="truncate font-medium text-neutral-800">
                                       ${c.situs ?? c.taxpin}
                                     </span>
                                     <span class="shrink-0 tabular-nums font-semibold">${c.ratio}×</span>
                                   </div>
                                   <div class="flex items-baseline justify-between gap-2 text-[11px] text-neutral-500">
                                     <span>${money(c.vpa.land)}/ac land</span>
                                     <span class="text-neutral-400">${c.acres.toFixed(2)} ac</span>
                                   </div>
                                 </button>`
                                   )
                                   .join('')}
                             </div>
                           </div>`
                        : '<div class="text-[11px] text-neutral-500">No comparable land for this parcel.</div>'
                }
              </div>`;

            drawer.querySelectorAll('[data-comp]').forEach((b) => {
                b.onclick = () => onComp(data.comps[Number(b.dataset.comp)]);
            });
        },
    };
}

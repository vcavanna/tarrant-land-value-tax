import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import { bunny } from 'laravel-vite-plugin/fonts';
import tailwindcss from '@tailwindcss/vite';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * Emit MapLibre's web worker next to the bundle.
 *
 * MapLibre v6 resolves its worker at RUNTIME by concatenating a filename onto
 * import.meta.url:
 *
 *     new URL('./maplibre-gl-worker.mjs', import.meta.url)
 *
 * No bundler can analyse that statically, so Vite never emits the chunk and the
 * request 404s. Without the worker MapLibre parses no tiles and the map never
 * fires `load` — it renders as a blank page with no console error.
 *
 * The names must be exact and unhashed: the worker in turn imports
 * './maplibre-gl-shared.mjs', so both files ship side by side.
 */
function maplibreWorkerAssets() {
    const dist = resolve(import.meta.dirname, 'node_modules/maplibre-gl/dist');
    const files = ['maplibre-gl-worker.mjs', 'maplibre-gl-shared.mjs'];

    return {
        name: 'maplibre-worker-assets',
        apply: 'build',
        generateBundle() {
            for (const file of files) {
                this.emitFile({
                    type: 'asset',
                    fileName: `assets/${file}`,
                    source: readFileSync(resolve(dist, file), 'utf8'),
                });
            }
        },
    };
}

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/js/app.js'],
            refresh: true,
            fonts: [
                bunny('Instrument Sans', {
                    weights: [400, 500, 600],
                }),
            ],
        }),
        tailwindcss(),
        maplibreWorkerAssets(),
    ],
    server: {
        watch: {
            ignored: ['**/storage/framework/views/**'],
        },
    },
});

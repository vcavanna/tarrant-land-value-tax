import boot from './map';

const root = document.getElementById('map-root');

if (root) {
    boot(root).catch((err) => {
        console.error(err);
        root.insertAdjacentHTML(
            'afterbegin',
            `<div class="absolute inset-x-0 top-0 z-30 bg-red-100 p-3 text-center text-sm text-red-800">
               Could not start the map: ${err.message}
             </div>`
        );
    });
}

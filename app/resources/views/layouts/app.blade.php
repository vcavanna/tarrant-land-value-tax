<!doctype html>
<html lang="en" class="h-full">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>@yield('title', 'Tarrant County — Value per Acre')</title>
    <meta name="description" content="Tarrant County parcels coloured by appraised value per acre.">
    <link rel="icon" href="/favicon.ico">
    @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="h-full bg-neutral-100 text-neutral-900 antialiased">
    @yield('body')

    {{-- D.6: the TAD disclaimer must be present on the page itself, not only in
         API meta. Single source of truth is config/map.php. --}}
    <footer class="pointer-events-none fixed inset-x-0 bottom-0 z-20 px-3 pb-2">
        <p class="pointer-events-auto mx-auto max-w-4xl rounded bg-white/85 px-3 py-1.5
                  text-center text-[11px] leading-snug text-neutral-600 shadow-sm backdrop-blur">
            {{ config('map.license_footer') }}
        </p>
    </footer>
</body>
</html>

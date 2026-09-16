@extends('layouts.app')

@section('body')
    {{-- Deploy constants are NOT injected here: the client fetches them from
         /api/map-config (D.4) so one source serves every consumer. The only
         thing the server passes is which parcel a deep link asked for. --}}
    <div
        id="map-root"
        class="fixed inset-0"
        @isset($initialParcel) data-initial-parcel="{{ $initialParcel }}" @endisset
    >
        <div id="map" class="absolute inset-0"></div>

        <noscript>
            <div class="absolute inset-x-0 top-0 bg-amber-100 p-4 text-center text-sm">
                This map needs JavaScript. The underlying data is available at
                <code>/api/parcels/{taxpin}</code>.
            </div>
        </noscript>
    </div>
@endsection

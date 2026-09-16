<?php

use Illuminate\Database\QueryException;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withMiddleware(function (Middleware $middleware): void {
        //
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        $exceptions->shouldRenderJsonWhen(
            fn (Request $request) => $request->is('api/*'),
        );

        /*
        | Section D.7 — error handling and logging.
        |
        | The API is public, so responses get a stable envelope and never carry a
        | stack trace or filesystem path, even with APP_DEBUG on. Laravel's
        | default 404 body leaked the absolute controller path.
        |
        | Debug detail is still available locally under `debug`, but it is opt-in
        | and separate from the contract the frontend binds to.
        */
        $apiError = function (Request $request, int $status, string $message, ?\Throwable $e = null) {
            $body = ['error' => ['status' => $status, 'message' => $message]];

            if ($e !== null && config('app.debug')) {
                $body['debug'] = [
                    'exception' => $e::class,
                    'message' => $e->getMessage(),
                ];
            }

            return response()->json($body, $status);
        };

        // A database outage is not a client error. 503 lets monitoring and
        // callers tell "the map is down" from "you asked for something odd",
        // and keeps it out of the 5xx bucket that usually means a code bug.
        $exceptions->render(function (QueryException $e, Request $request) use ($apiError) {
            if (! $request->is('api/*')) {
                return null;
            }

            Log::error('Database error serving API request', [
                'path' => $request->path(),
                'sql_state' => $e->getCode(),
            ]);

            return $apiError($request, 503, 'The parcel database is unavailable.', $e);
        });

        // Unknown taxpin or parcel_id. Logged at info rather than warning: with
        // deep links in circulation these are expected, and the record is what
        // shows a link has gone stale after a reload.
        $exceptions->render(function (HttpExceptionInterface $e, Request $request) use ($apiError) {
            if (! $request->is('api/*')) {
                return null;
            }

            $status = $e->getStatusCode();

            if ($status === 404) {
                Log::info('Parcel not found', ['path' => $request->path()]);
            }

            return $apiError(
                $request,
                $status,
                $e->getMessage() !== '' ? $e->getMessage() : 'Request could not be completed.',
                $e
            );
        });
    })->create();

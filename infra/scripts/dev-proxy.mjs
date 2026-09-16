#!/usr/bin/env node
/**
 * Zero-dependency same-origin reverse proxy for local dev.
 *
 *   /tiles/*  → Martin  (default 127.0.0.1:3000), prefix stripped
 *   /*        → Laravel (default 127.0.0.1:8000)
 *
 * Env:
 *   PROXY_PORT   (default 8080)
 *   LARAVEL_URL  (default http://127.0.0.1:8000)
 *   MARTIN_URL   (default http://127.0.0.1:3000)
 */
import http from 'node:http';
import { URL } from 'node:url';

const PROXY_PORT = Number(process.env.PROXY_PORT || 8080);
const LARAVEL_URL = process.env.LARAVEL_URL || 'http://127.0.0.1:8000';
const MARTIN_URL = process.env.MARTIN_URL || 'http://127.0.0.1:3000';

function proxy(req, res, targetBase, pathOverride, { allowCompression = false } = {}) {
  const target = new URL(targetBase);
  const incoming = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  const path = pathOverride ?? (incoming.pathname + incoming.search);

  // Forward the original Host, as nginx's proxy_set_header Host $host does in
  // production. Both upstreams build absolute URLs from it: Martin for its
  // TileJSON tile template, Laravel for @vite asset tags. Rewriting it to the
  // upstream address makes both advertise a private port that bypasses this
  // proxy — which works locally by accident and breaks behind a real origin.
  const headers = { ...req.headers, host: req.headers.host ?? target.host };
  // Stripped by default to avoid broken upstream compression edge cases on some
  // stacks, but tiles must keep it: Martin gzips MVT and a z14 tile is 54 kB raw
  // against 37 kB gzipped. The response is piped through with its upstream
  // headers intact, so content-encoding reaches the client correctly.
  if (!allowCompression) {
    delete headers['accept-encoding'];
  }

  const opts = {
    protocol: target.protocol,
    hostname: target.hostname,
    port: target.port || (target.protocol === 'https:' ? 443 : 80),
    path,
    method: req.method,
    headers,
  };

  const upstream = http.request(opts, (upRes) => {
    res.writeHead(upRes.statusCode || 502, upRes.headers);
    upRes.pipe(res);
  });

  upstream.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    }
    res.end(`Bad gateway: ${err.message}\n`);
  });

  req.pipe(upstream);
}

const server = http.createServer((req, res) => {
  const url = req.url || '/';
  if (url === '/__proxy_health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, laravel: LARAVEL_URL, martin: MARTIN_URL }));
    return;
  }

  if (url === '/tiles' || url.startsWith('/tiles/')) {
    const stripped = url === '/tiles' ? '/' : url.slice('/tiles'.length) || '/';
    proxy(req, res, MARTIN_URL, stripped, { allowCompression: true });
    return;
  }

  proxy(req, res, LARAVEL_URL);
});

server.listen(PROXY_PORT, '0.0.0.0', () => {
  console.log(`[dev-proxy] http://127.0.0.1:${PROXY_PORT}`);
  console.log(`[dev-proxy]   /        → ${LARAVEL_URL}`);
  console.log(`[dev-proxy]   /api/*   → ${LARAVEL_URL}`);
  console.log(`[dev-proxy]   /tiles/* → ${MARTIN_URL} (prefix stripped)`);
});

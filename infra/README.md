# `infra/` — Runtime and deploy configuration

**Spec sections:** A (local stack), C (Martin), F (GCE + CDN)

## Purpose

Configuration and scripts for:

- **PostgreSQL / PostGIS**
- **Martin** (dynamic MVT)
- **nginx** (TLS, reverse proxy, same-origin paths)
- **Docker Compose** (local parity with single-VM production)
- Host bootstrap / deploy helpers

## Layout

| Path | Use |
|------|-----|
| `docker/` | `docker-compose.yml`, service images, volume notes |
| `martin/` | Martin config (sources, pool, etc.) |
| `nginx/` | Site config: `/` → app, `/api` → app, `/tiles` → Martin |
| `scripts/` | VM setup, health checks, cache purge notes |

## Same-origin routing (target)

```text
Client
  /          → Laravel (app)
  /api/*     → Laravel
  /tiles/*   → Martin
```

CDN sits in front of `/tiles/*` in production (Section F); no tile filter query params in v1.

## Status (A.2)

| Artifact | Role |
|----------|------|
| `scripts/dev-up.sh` / `dev-down.sh` | Start/stop Martin + Laravel + proxy |
| `scripts/dev-proxy.mjs` | Same-origin reverse proxy (:8080) |
| `scripts/bootstrap-db.sh` + `bootstrap-db.sql` | Create `tad` / `tad_analysis` + PostGIS |
| `scripts/install-martin.sh` | Download Martin → `infra/bin/` |
| `martin/config.yaml` | Martin listen settings |
| `nginx/local.conf` | Optional system nginx same-origin |
| `docker/docker-compose.yml` | Optional containerized PostGIS + Martin + nginx |

See [docs/LOCAL_DEV.md](../docs/LOCAL_DEV.md).

---
type: platform-adapter
title: NGINX 入口 Adapter
description: TLS termination, security headers, rate limiting, correlation IDs, and the blue/green vhost switch.
tags:
  - nginx
  - ingress
  - tls
timestamp: 2026-08-09T06:20:34+08:00
---

# NGINX Adapter — Local HTTPS

Implements the contract in `docs/Network.md` ("Local implementation"):

```text
devops.local / localhost
  -> local HTTPS (TLS 1.2+, mkcert-issued cert)
  -> NGINX adapter
  -> Compose service (station1-hello, or future pilots)

```

This validates routing, TLS, headers, health checks, timeout and rate limit
semantics on a single Mac. It does **not** provide real F5, CDN, DDoS
protection or VPC isolation — see `docs/Network.md` for what the local
adapter deliberately does not claim.

## File Structure

```text
platform/nginx/
├── README.md               # This file
├── nginx.conf               # Platform-level config — pilot-agnostic
├── conf.d/
│   ├── _platform-health.conf   # Internal, unpublished healthcheck listener
│   └── station1-hello.conf     # Per-pilot routing template (one file per pilot)
├── certs/                   # mkcert output — gitignored, regenerate locally
├── scripts/
│   └── generate_local_certs.sh
└── compose.yaml

```

Per `platform/README.md`'s boundary rule ("platform/ 不得依賴特定 Pilot 的業務程式"),
`nginx.conf` itself names no pilot — only files under `conf.d/<service-name>.conf`
reference a specific upstream, one file per pilot (same pattern as
`platform/observability/prometheus/prometheus.yml`'s per-service scrape job).

## Quick Start

```bash

# 1. Generate a locally-trusted TLS certificate (idempotent)

platform/nginx/scripts/generate_local_certs.sh

# 2. Start the pilot this adapter routes to

cd pilots/station1-hello && docker compose up -d --build && cd -

# 3. Start the NGINX adapter

cd platform/nginx && docker compose up -d && cd -

# 4. Verify

curl --cacert platform/nginx/certs/devops.local.crt \
  --resolve devops.local:18443:127.0.0.1 \
  https://devops.local:18443/health/ready

```

## Design Decisions (with rationale — read before modifying)

### Container listens on 8443, not 443

Binding a port below 1024 as root requires `CAP_NET_BIND_SERVICE`. This
adapter drops **all** capabilities (`cap_drop: ALL`, matching pilot security
posture in `pilots/station1-hello/compose.yaml`), so the container listens on
8443 internally and Docker publishes it to the conventional host port
`127.0.0.1:18443` — no capability needed, host-side port choice is
independent of what the container listens on.

### Container runs as non-root natively (`user: "101:101"`), not via `user nginx;`

The stock `nginx:alpine` image starts its master process as root and uses the
`user nginx;` directive to drop worker processes to uid 101 — but that drop
requires `CAP_SETUID`/`CAP_SETGID`, which `cap_drop: ALL` removes. Instead,
the **whole container** (master included) starts already as uid 101 via
Compose's `user:` key, so nginx never needs to change UID and no capability
is required. Verified: `docker run --rm nginx:1.27-alpine id nginx` →
`uid=101(nginx) gid=101(nginx)`.

### `tmpfs` mounts need `mode=1777` explicitly

`read_only: true` means NGINX's default temp directories
(`/var/cache/nginx/client_temp` etc.) must come from tmpfs. Docker's tmpfs
default mode is root-owned `0755`, which the non-root nginx user cannot
write into. **Verified locally**: `mkdir` failed with `Permission denied`
until `mode=1777` was added explicitly — this is not a hypothetical
concern, it broke the container on the first run.

### Healthcheck uses an internal, unpublished plain-HTTP listener

`conf.d/_platform-health.conf` serves `/nginx-health` on
`127.0.0.1:8080`, inside the container only (no `ports:` mapping). This
exists because `busybox wget` (the only HTTP client in `nginx:alpine`) has
**no flag to skip TLS certificate verification**, and the container has no
reason to trust its own mkcert-issued leaf cert's CA. Checking a plain-HTTP,
loopback-only endpoint sidesteps that entirely, and also decouples "is NGINX
itself alive" from "is the pilot upstream alive" — useful for rollback and
incident triage per `docs/Network.md`.

### Correlation ID

`nginx.conf` maps `$http_x_request_id` to `$request_id_final`, falling back
to NGINX's built-in auto-generated `$request_id` when the client didn't send
one. This is forwarded to the upstream via `proxy_set_header X-Request-Id`
and also logged in the JSON access log's `correlation_id` field, satisfying
`NEW_SERVICE_GUIDE.md`'s "correlation ID" requirement for the ingress hop.

## Verified End-to-End (2026-08-09)

Real output, not hypothetical — captured while `station1-hello` and this
adapter were both running:

| Check | Result |
|---|---|
| TLS handshake | TLS 1.3, `AEAD-AES256-GCM-SHA384`, cert verified against mkcert CA, HTTP/2 negotiated |
| Routing | `GET /health/ready` via NGINX → `station1-hello` → `{"status": "ready"}`, HTTP 200 |
| Security headers | `strict-transport-security`, `x-content-type-options`, `x-frame-options`, `referrer-policy` all present |
| Rate limiting | 40 rapid requests (limit `10r/s`, burst 20) → ~25× `200`, remainder `429` |
| Container healthcheck | `docker ps` → `Up ... (healthy)` |
| Published ports | Only `127.0.0.1:18443->8443/tcp` — no plain HTTP port exposed |
| Structured logs | JSON access log confirmed on `docker logs`, including `correlation_id` field |
| Loki ingestion | Queried Loki API directly (`{container="nginx-nginx-1"}`) — NGINX's JSON logs present, including the rate-limit test traffic. **Zero extra wiring required**: Alloy auto-discovers all Docker containers via the socket (`platform/observability/alloy/config.alloy`). |

## Known Gaps / Next Steps

- **No Prometheus metrics.** NGINX has no `/metrics` endpoint here (no
  `stub_status` or `nginx-prometheus-exporter` wired up). Access-pattern
  metrics currently only exist as Loki log lines, not Prometheus time series.
  Add `nginx-prometheus-exporter` as a sidecar if dashboards need it.
- **Single pilot routed.** Only `station1-hello` has a `conf.d/*.conf` file.
  Adding a new pilot means adding one more file — no changes to `nginx.conf`
  itself (see boundary rule above).
- **mkcert CA not in system trust store by default.** `mkcert -install`
  needs an interactive sudo password (macOS Keychain), which
  `generate_local_certs.sh` cannot supply non-interactively — it skips that
  step gracefully and still produces a fully functional (but
  browser-untrusted-until-you-run-`mkcert -install`-once) certificate.
- **Public URL (rathole/Cloudflare Tunnel) not wired to this adapter yet** —
  next item in `docs/Network.md`'s "Public URL experiment options".

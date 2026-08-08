# Compose Deployment Adapter — Develop Environment

Implements `Plan.md` §4 "兩環境最小隔離" (develop half) and item 6 of the
roadmap ("建立 develop / production-like deployment adapter"). Only the
**develop** environment is implemented here — production-like promotion
(blue/green, human approval gate, rollback) is a separate, not-yet-built
item; see "Known Gaps" below.

## Contract

```text
build   -> tag image with git short SHA, alias to <pilot>:dev, run CI, record evidence
deploy  -> run the already-built image (never rebuilds) in an isolated
           Compose project + network, inject environment-specific config,
           wait for healthy, record evidence
```

Per `Plan.md` §4:
- **Separate Compose project per environment** — `<pilot>-develop` gets its
  own project name, and therefore its own default Docker network
  (`<pilot>-develop_default`), automatically, with no explicit `networks:`
  block needed.
- **Separate environment config** —
  `platform/compose/environments/<pilot>/<env>.env`, injected via
  `docker compose --env-file`. This is the *only* thing that differs
  between environments; the image is never rebuilt per environment.
- **`deploy` never triggers a build** (`--no-build` explicit, and it errors
  out if `<pilot>:dev` doesn't exist yet) — build and deploy are separate,
  auditable steps, mirroring the `fmt -> validate -> plan -> apply`
  separation already used in `platform/iac/`.

## Usage

```bash
platform/compose/deploy.sh build   pilots/station1-hello
platform/compose/deploy.sh deploy  develop pilots/station1-hello
platform/compose/deploy.sh status  develop pilots/station1-hello
platform/compose/deploy.sh teardown develop pilots/station1-hello
```

`build` reuses `platform/ci/run_local_ci.sh` (lint → unit/contract test →
`docker build` → metadata) rather than reimplementing it — the only change
is tagging the image `<pilot>:<git-sha>` instead of the CI script's default
`<pilot>:ci`, plus an alias tag `<pilot>:dev` that `deploy` (and the pilot's
own `compose.yaml`) expect.

## Environment Config Injection

`pilots/station1-hello/compose.yaml` was changed from a hardcoded
`APP_VERSION: station1-dev` to `APP_VERSION: ${APP_VERSION:-station1-dev}`
— the minimal change needed to satisfy `NEW_SERVICE_GUIDE.md`'s "可由
environment configuration 注入設定" requirement without the platform
depending on pilot-specific logic (the templating lives in the pilot's own
file; the platform adapter just supplies `--env-file`).

## Verified End-to-End (2026-08-09)

Real output, not hypothetical:

| Check | Result |
|---|---|
| Build | `build_44dc095.json` written; image tagged `station1-hello:44dc095` and aliased `station1-hello:dev` |
| Deploy | Project `station1-hello-develop` created with its own network `station1-hello-develop_default`; container healthy in <5s |
| Env injection reaches the app | `curl .../version` → `{"service": "station1-hello", "version": "station1-develop"}` — not the compose.yaml default `station1-dev`, confirming `develop.env`'s `APP_VERSION=station1-develop` actually flowed through |
| Idempotent re-deploy | Running `deploy develop` again against an already-running container: no error, health re-confirmed |
| Guard rail | `deploy production-like ...` → rejected with exit 1 and an explanation, not silently run |
| Teardown | Container and network both removed cleanly (`docker network ls` confirms no leftover network) |
| Downstream integration intact after redeploy | NGINX adapter (`platform/nginx/`) still routes correctly to the new isolated-project container; Prometheus `up{job="station1-hello"} == 1` — neither needed reconfiguration, since both target the stable host-published port `18080`, not the container/project name |

## Evidence Schema

`evidence/<pilot>/build_<sha>.json` — reuses the existing schema from
`platform/ci/run_local_ci.sh` (see `evidence/station2/metadata.json` for the
original precedent).

`evidence/<pilot>/deploy_<env>_<sha>.json`:

```json
{
  "environment": "develop",
  "compose_project": "station1-hello-develop",
  "commit_sha": "44dc095",
  "image_id": "sha256:...",
  "image_digest": "station1-hello@sha256:... or null",
  "deployed_at": "2026-08-08T22:24:21Z",
  "health_status": "healthy",
  "env_file": "/absolute/path/to/develop.env"
}
```

## Known Gaps / Next Steps

- **No production-like promotion.** `deploy` rejects any environment other
  than `develop`. Building this properly needs: a gate that checks a
  `deploy_develop_<sha>.json` evidence file exists for the digest being
  promoted, a blue/green swap mechanism (likely via the NGINX adapter's
  upstream block), a human approval step (not just a ticket ID field — an
  actual pause for review, per `NEW_SERVICE_GUIDE.md` §8), and rollback.
- **No registry.** `image_digest` in evidence is `null` unless a build
  happens to produce a local `RepoDigests` entry (buildx/containerd image
  store sometimes populates this even without a push — verified this is
  real `docker image inspect` output, not fabricated, but it's not a
  guarantee). "Registry promotion 與 immutable artifact flow" is still
  listed as not-done in `Plan.md`.
- **No container security scan gate.** `platform/security/` (Trivy,
  Gitleaks, SBOM, Cosign) doesn't exist yet — `build` doesn't block on any
  vulnerability findings today.
- **Single pilot wired.** Only `platform/compose/environments/station1-hello/`
  exists. A new pilot needs its own `develop.env` (and eventually
  `production-like.env`) added under this directory — no changes to
  `deploy.sh` itself.

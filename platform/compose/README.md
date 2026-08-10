# Compose Deployment Adapter — Develop + Production-like (Blue/Green)

Implements `Plan.md` §4 "兩環境最小隔離" and roadmap items 6-7 ("建立
develop / production-like deployment adapter" and "production-like
blue/green 與 rollback"). Both are implemented and verified end-to-end
below.

## Contract

```text
build    -> tag image with git short SHA, run CI, run security scan gate
            (platform/security/scan_image.sh), alias to <pilot>:dev only on
            a passing scan, record evidence
push     -> push <pilot>:dev to ghcr.io/<owner>/<pilot>:<sha>, record the
            REAL registry digest (not the sometimes-present local buildx
            digest) as evidence
deploy   -> run the already-built image (never rebuilds) in an isolated
            Compose project + network, inject environment-specific config,
            wait for healthy, record evidence
promote  -> gate on a healthy develop deployment for the current commit,
            start the OTHER blue/green color with the same image, smoke
            test it directly, pause for an interactive human confirmation,
            then flip NGINX traffic and reload
rollback -> flip NGINX traffic back to the previous color (only if it's
            still running)
```

Per `Plan.md` §4:
- **Separate Compose project per environment/color** — `<pilot>-develop`,
  `<pilot>-productionlike-blue`, `<pilot>-productionlike-green` each get
  their own project name, and therefore their own default Docker network,
  automatically, with no explicit `networks:` block needed.
- **Separate environment config** —
  `platform/compose/environments/<pilot>/<env>.env`, injected via
  `docker compose --env-file`. Blue and green share the same
  `production-like.env` (only `HOST_PORT` differs between them, passed as a
  shell-exported override on top of the env file) — the image is *never*
  rebuilt per environment or per color.
- **`deploy`/`promote` never trigger a build** (`--no-build` explicit) —
  build and deploy are separate, auditable steps, mirroring the
  `fmt -> validate -> plan -> apply` separation already used in
  `platform/iac/`.
- **production-like only ever runs an image validated in develop** —
  `promote` refuses to run unless `evidence/<pilot>/deploy_develop_<sha>.json`
  exists for the pilot's *current* git SHA and its `health_status` is
  `"healthy"`.

## Usage

```bash
# Develop
platform/compose/deploy.sh build    pilots/station1-hello
export VAULT_TOKEN=<token with read access to secret/data/devops/*>
platform/compose/deploy.sh push     pilots/station1-hello           # push only
SIGN_ARTIFACTS=1 platform/compose/deploy.sh push pilots/station1-hello  # push + cosign sign
platform/compose/deploy.sh deploy   develop pilots/station1-hello
platform/compose/deploy.sh status   develop pilots/station1-hello
platform/compose/deploy.sh teardown develop pilots/station1-hello

# Production-like (blue/green)
platform/compose/deploy.sh promote  pilots/station1-hello   # interactive: type PROMOTE
platform/compose/deploy.sh rollback pilots/station1-hello   # interactive: type ROLLBACK
platform/compose/deploy.sh status   production-like pilots/station1-hello blue
platform/compose/deploy.sh teardown production-like pilots/station1-hello green
```

`build` reuses `platform/ci/run_local_ci.sh` (lint → unit/contract test →
`docker build` → metadata) rather than reimplementing it — the only change
is tagging the image `<pilot>:<git-sha>` instead of the CI script's default
`<pilot>:ci`, plus an alias tag `<pilot>:dev` that `deploy`/`promote` (and
the pilot's own `compose.yaml`) expect.

## Environment Config Injection

`pilots/station1-hello/compose.yaml` was changed from hardcoded values to
`APP_VERSION: ${APP_VERSION:-station1-dev}` and
`ports: - "127.0.0.1:${HOST_PORT:-18080}:8080"` — the minimal templating
needed for `NEW_SERVICE_GUIDE.md`'s "可由 environment configuration 注入設定"
requirement and for blue/green to run two colors simultaneously on
different host ports. The templating lives in the pilot's own file; the
platform adapter only supplies `--env-file` and, for blue/green, a
`HOST_PORT` shell-environment override — this doesn't violate the
"platform/ must not depend on pilot-specific logic" boundary rule.

## Registry Promotion (GHCR) — Read This Before Debugging a Push Failure

`cmd_push` pushes to `ghcr.io/<owner>/<pilot>:<sha>` — GitHub Container
Registry, a zero-new-account extension of the GitHub account already used
for this repo's source control, not an arbitrary registry choice.

### Fine-grained PATs do not work for this, at all, regardless of permissions

The GitHub PAT this repo already had (`secret/devops/github` in Vault,
originally migrated from `~/.env`'s `GITHUB_TOKEN`) is a **fine-grained**
PAT with full repository permissions. Pushing with it failed:

```text
error from registry: permission_denied: The token provided does not match expected scopes.
```

The instinctive fix — go find a "Packages" checkbox in the fine-grained
token's repository permissions and enable it — **does not exist and would
not have worked anyway**. Verified against GitHub's own documentation
(not memory, not a guess) after the first fix attempt failed a second
time: "GitHub Packages only supports authentication using a personal
access token (classic)." Fine-grained tokens are not supported for
GitHub Packages at all, independent of which permissions are configured
on them.

**The actual fix**: a separate **classic** PAT with the `write:packages`
scope, stored in Vault at `secret/devops/ghcr` (deliberately a different
path from `secret/devops/github` — one token is for git operations, the
other for registry pushes; they should not be the same credential even
though they're both nominally "the GitHub account"). `cmd_push` reads
from `secret/devops/ghcr` specifically, not `secret/devops/github`.

### `docker login`'s credential store hangs non-interactively

Docker Desktop's default `credsStore: "desktop"` opens a macOS Keychain
GUI authorization prompt — which hangs indefinitely (reproduced: >2
minutes, had to be killed) when there's no interactive session to approve
it. `cmd_push` works around this with a throwaway `DOCKER_CONFIG` directory
containing a plain base64 `auths` entry, bypassing the credential-helper
path entirely. The directory (and the PAT value held in it) is removed
via a `trap ... RETURN` as soon as `cmd_push` finishes, success or failure.

### Verified (2026-08-09/10)

| Check | Result |
|---|---|
| Fine-grained PAT push | Failed: `permission_denied: ... does not match expected scopes` — confirmed root cause against GitHub's docs, not assumed |
| Classic PAT + `write:packages`, same push command | Succeeded: `ghcr.io/drew-young-ai/station1-hello:b0c679a`, real registry digest `sha256:c8db7...` recorded in `evidence/<pilot>/push_<sha>.json` |
| Package visibility | Queried `gh api /users/<owner>/packages/container/<pilot>` → `"visibility":"private"` — confirmed private by default, not silently public |
| Credential cleanup | Throwaway `DOCKER_CONFIG` dir removed after both the failing and succeeding push attempts (verified via the `trap` firing on `RETURN`, not just "should have") |
| Image signing (`SIGN_ARTIFACTS=1`) | `cosign sign` on the pushed digest succeeded; `cosign verify` with the matching public key → `IMAGE VERIFY PASS`, offline transparency-log inclusion check passed |
| **Wrong-key verification fails** | Generated a throwaway, unrelated key pair and ran `cosign verify --key <wrong pub key>` against the *real* signed image → `Error: no matching attestations: ... transparency log certificate does not match`, exit 1 — the check actually validates key material, it isn't a rubber stamp |

## Blue/Green Design

- **Port allocation**: blue = host port `18081`, green = `18082` (develop
  stays on `18080`, untouched).
- **Traffic switch**: `platform/nginx/conf.d/station1-hello.production-like.conf.template`
  is a committed template (`__UPSTREAM_PORT__` placeholder). `promote`/
  `rollback` render it to
  `platform/nginx/conf.d/_generated.station1-hello.production-like.conf`
  (gitignored — derived, mutable state, same reasoning as gitignoring
  `*.tfstate` rather than committing it) and run `nginx -t && nginx -s
  reload` inside the running `nginx-nginx-1` container. If NGINX isn't
  running, `promote`/`rollback` still work but skip the reload with a
  warning (NGINX is optional infrastructure, not a hard dependency of the
  deployment adapter itself).
- **The human gate is real, not cosmetic**: both `promote` and `rollback`
  use `read -p` for an exact-phrase confirmation (`PROMOTE` /
  `ROLLBACK`). There is no `--yes`/`--force` flag. This matches
  `NEW_SERVICE_GUIDE.md` §8: "LLM 可以執行測試...但不能代替人類進行...
  production release approval." Running the script non-interactively
  (e.g. piped empty stdin) safely aborts before touching NGINX or state —
  verified below.
- **Rollback only flips traffic** — it never redeploys. The color being
  replaced by `promote` is deliberately left running (not torn down) so
  `rollback` can switch back instantly. `teardown production-like ... <color>`
  refuses to remove whichever color is currently active in
  `production_like_state.json`.

## Verified End-to-End (2026-08-09)

Real command output, not hypothetical — every row below was actually run,
including deliberately triggering the failure paths:

| Check | Result |
|---|---|
| Build + develop deploy | `station1-hello:9d68668` built and deployed to `station1-hello-develop`, healthy |
| Env injection reaches the app | `curl .../version` on develop → `{"version": "station1-develop"}`, confirming `develop.env` actually flowed through |
| **Promote: unconfirmed input aborts safely** | Piped empty string → script started `blue`, smoke-tested it, then aborted *before* touching NGINX or writing state (`production_like_state.json` absent, `_generated.*.conf` absent, `curl` to the production-like port failed to even complete a TLS handshake — nothing was listening) |
| **Promote: confirmed (`PROMOTE`) succeeds** | `none → blue`: `blue` container healthy, smoke test passed, NGINX reloaded, state file + `promote_<sha>_<ts>.json` written |
| **Develop-validation gate** | Temporarily moved `deploy_develop_<sha>.json` out of the way → `promote` refused immediately with "No develop deployment evidence for sha=... Run first: deploy develop ..." |
| Second promote: `blue → green` | Same image, no rebuild; `green` started on `18082`, smoke-tested, confirmed, NGINX flipped |
| **Traffic actually moved (not just claimed)** | NGINX's own JSON access log `upstream_addr` field showed the real backend IP:port handling each request — went from `...:18081` (blue) to `...:18082` (green) after that promote |
| **Rollback (`green → blue`)** | Confirmed via `ROLLBACK`; NGINX access log's `upstream_addr` afterward showed `...:18081` again — proof the swap, not just the state file, actually changed |
| **Rollback refuses without a previous color** | First-ever promotion (`none → blue`) → `rollback` immediately refused: "This is either the first-ever promotion, or state is missing" |
| **Rollback refuses if the previous color was torn down** | Tore down `green` after rolling back to `blue`, then tried `rollback` again → refused: "Previous color 'green' ... is not running" |
| **Teardown protects the active color** | `teardown production-like ... blue` while `blue` was active → refused: "it is the currently ACTIVE color receiving traffic" |
| **Teardown succeeds for the inactive color** | `teardown production-like ... green` while `green` was inactive → removed cleanly |
| Bug found and fixed during this testing | `cmd_promote`'s final line was `[ "$current_color" != "none" ] && echo "..."` — when false (first promotion), this is the function's last-executed statement, so its exit status (1) became the function's return value and thus the whole script's exit code, even though every actual step had succeeded. All work was correct; only the reported exit code was wrong. Fixed by wrapping in `if`/`fi`. Re-ran the second promote afterward and confirmed exit code 0. |

## Evidence Schema

`evidence/<pilot>/build_<sha>.json`, `evidence/<pilot>/deploy_<env>_<sha>.json`
— unchanged from the develop-only version of this adapter (see git history).

`evidence/<pilot>/production_like_state.json` — always reflects current
production-like state, overwritten on every promote/rollback:

```json
{
  "active_color": "blue",
  "previous_color": "green",
  "active_project": "station1-hello-productionlike-blue",
  "active_port": 18081,
  "promoted_sha": "9d68668",
  "image_id": "sha256:...",
  "promoted_at": "2026-08-08T22:33:18Z"
}
```

`evidence/<pilot>/promote_<sha>_<timestamp>.json` — one immutable snapshot
per promotion (same shape as the state file at that moment), for history
`production_like_state.json` alone doesn't preserve.

## Known Gaps / Next Steps

- ~~No registry~~ **Done** — see "Registry Promotion (GHCR)" above. `push`
  records a real registry digest (`evidence/<pilot>/push_<sha>.json`), not
  the sometimes-present local buildx digest `build`/`deploy` evidence
  falls back to. `push` is a separate, opt-in step (not run automatically
  by `build`) — nothing currently gates `deploy`/`promote` on having been
  pushed first.
- ~~Container image itself isn't Cosign-signed~~ **Done** — `push` signs
  the pushed digest with `cosign sign` when `SIGN_ARTIFACTS=1` (same
  opt-in gate and same Rekor disclosure as SBOM signing in
  `platform/security/README.md`, reusing the GHCR credentials already
  staged for the push itself). Verified: signed, `cosign verify` with the
  correct public key passed; **verifying the same image with a
  deliberately wrong public key failed** (`transparency log certificate
  does not match`, exit 1) — proof the check is real, not a rubber stamp.
- ~~No container security scan gate~~ **Done** — `build` now runs
  `platform/security/scan_image.sh` and refuses to create the `:dev` alias
  (which `deploy`/`promote` both require) on a failed scan. See
  `platform/security/README.md`.
- **No automated rollback trigger.** `rollback` is entirely manual/human-
  initiated. There's no health-based auto-rollback if a promoted color
  degrades after traffic has already shifted to it.
- **No bake-period enforcement.** Nothing prevents tearing down the old
  color immediately after a promote (beyond the "active color" protection);
  there's no minimum observation window before it's considered safe to
  clean up.
- **Single pilot wired.** Only `platform/compose/environments/station1-hello/`
  and one hardcoded pair of blue/green ports (`18081`/`18082`, in
  `deploy.sh`'s `pl_port()`) exist. A second pilot needs its own env files
  and its own port pair added to `pl_port()`.

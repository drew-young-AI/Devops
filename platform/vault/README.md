# Vault Adapter — Secret Management

Implements the "已鎖定決策" in `Plan.md`/`docs/IaC.md`: **HashiCorp Vault
Community**; `.env` only as a migration source, never the real secret
store. This closes the last still-open P0 item from `Plan.md` §6
("Secret migration 與硬體/resource baseline").

## Why file storage + real init/unseal, not `vault server -dev`

`-dev` mode is in-memory (all secrets lost on restart), auto-unsealed, and
runs with a fixed, publicly-documented root token — none of that validates
the actual init/unseal/policy lifecycle a real deployment needs. File
storage with a genuine `vault operator init` is the closest local
equivalent without needing a cloud KMS auto-unseal mechanism (out of scope
until there's an actual cloud adapter — see `docs/Network.md`'s Public URL
section for the same "don't fake production capability" principle applied
here).

## Quick Start

```bash
cd platform/vault && docker compose up -d && cd -
platform/vault/scripts/init_and_unseal.sh
```

The second command is your **one-time** setup: it runs `vault operator
init` (5 key shares, threshold 3), writes the unseal keys and root token to
`platform/vault/.init-output.json` (chmod 600, gitignored — **move its
contents to a password manager and delete the file**), then unseals using
3 of the 5 keys. Re-running it later (e.g. after `docker compose restart`)
detects Vault is already initialized and just unseals again using the same
file.

## Design Decisions (with rationale — read before modifying)

### No `user:` override, no `cap_drop: ALL`

Every other hardened container in this platform (`platform/nginx/`,
`pilots/station1-hello/`) runs as a fixed non-root UID with all capabilities
dropped. Vault's official image works differently on purpose: its
`docker-entrypoint.sh` starts as root specifically so it can `chown -R
vault:vault` its bind-mounted `/vault/config`, `/vault/logs`, and
`/vault/file` paths to the built-in `vault` user (uid 100), then
self-demotes via `su-exec vault vault server ...` before the actual server
process ever runs. That's the vendor's own least-privilege pattern — root
only for the brief startup dance, then permanently non-root.

**Verified locally, twice, by reproducing the actual failures**:
- Storage path had to be `/vault/file`, not an arbitrary path like
  `/vault/data` — the entrypoint's chown logic only covers that exact path
  (and `/vault/config`, `/vault/logs`). Using `/vault/data` left it
  root-owned and unwritable (`touch: Permission denied`, reproduced with
  `docker run --user 100:1000 ...` before understanding why).
- `cap_drop: ALL` breaks the same self-demotion this pattern breaks in
  `platform/nginx/`'s `user nginx;` directive — `su-exec` needs
  `CAP_SETUID`/`CAP_SETGID`, and the chown steps need `CAP_CHOWN`, none of
  which a fully-capability-dropped root process has.

### `VAULT_ADDR` set explicitly in the container environment

The `vault` CLI's own default address is `https://127.0.0.1:8200`.
Without `VAULT_ADDR=http://127.0.0.1:8200` in the container's environment,
both the Docker `HEALTHCHECK` (which can't take a `docker exec -e`
override) and any bare `docker exec ... vault ...` command fail with a
TLS/HTTP scheme mismatch against this adapter's `tls_disable = true`
listener. **Verified locally**: healthcheck reported `unhealthy` with
`"server gave HTTP response to HTTPS client"` until this was added, then
flipped to `healthy` immediately after redeploying with the fix.

### Healthcheck uses `vault status`, and "unhealthy while sealed" is correct, not a bug

`vault status` exits 2 when sealed. Docker's healthcheck only cares about
zero vs. non-zero, so a freshly-initialized (but not yet unsealed) Vault
correctly shows `unhealthy` — it genuinely cannot serve secrets yet. This
was verified as the actual observed behavior (not just documented
intent): the container showed `unhealthy` immediately post-init and
flipped to `healthy` within one healthcheck interval of running
`init_and_unseal.sh`.

### TLS is off at Vault's own listener

Published only to `127.0.0.1:18200`, matching the same posture already
used for Prometheus/Loki/Grafana in `platform/observability/` — internal
platform tooling that's never reached from outside this Mac doesn't
duplicate the NGINX adapter's TLS termination. If Vault ever needs to be
reachable through the ingress layer, terminate TLS in
`platform/nginx/`, not here.

## What Was Actually Migrated

`secret/devops/github` — GitHub PAT, migrated from `~/.env`'s
`GITHUB_TOKEN`, as a proof-of-concept of the migration contract in
`NEW_SERVICE_GUIDE.md` ("Secret 只保存 Secret Manager reference"). This is
a demonstration of the mechanism, not a rewiring of every place this
session used `~/.env` directly (e.g. `git push` in this repo's own commit
history still reads `~/.env` — deliberately left alone; forcibly cutting
over an already-working, low-risk flow for marginal benefit wasn't worth
the regression risk. See "Known Gaps" below).

**No plaintext secret value ever appears in this repo, in evidence files,
or in command output that got logged** — verified by comparing byte
lengths before/after migration (93 chars both sides) instead of ever
printing the value; see `evidence/vault/setup_verification.json`.

## Least-Privilege Policy

`platform/vault/policies/devops-readonly.hcl` grants `read` on
`secret/data/devops/*` and `read`+`list` on `secret/metadata/devops/*` —
nothing else. A token scoped to this policy was created and tested against
**four** real requests, not just written and assumed correct:

| Test | Expected | Actual |
|---|---|---|
| Read `secret/devops/github` | Allowed | `200`, 93 bytes returned |
| List all secrets engines (`vault secrets list`) | Denied | `403 permission denied` |
| Create a new policy (`vault policy write`) | Denied | `403 permission denied` |
| Read a path outside the granted prefix (`secret/other-team`) | Denied | `403 permission denied` |

This is the actual difference between "wrote a policy file" and "verified
least privilege" — three of these four requests are the kind of thing that
silently succeeds if the policy path glob is wrong, and none of them would
have been caught by just reading the HCL.

## Verified End-to-End (2026-08-09)

- `docker compose up -d` → container starts, no chown errors, config loads
  correctly (`storage: file`, TLS disabled as configured)
- Fresh state confirmed: `vault status` → `Initialized: false, Sealed: true`
  before running `init_and_unseal.sh`
- `init_and_unseal.sh` → 5-share/3-threshold init succeeds, unseal succeeds,
  `Sealed: false` confirmed
- KV v2 enabled at `secret/`
- Secret migrated and round-trip verified by length (93 == 93), not by
  re-printing the value
- Least-privilege policy created and all 4 boundary tests above passed
- **Persistence across restart**: recreated the container
  (`docker compose up -d` again) — `Cluster ID` matched before and after,
  confirming the named volume (`vault-file`) actually persisted state
  rather than silently starting fresh
- Healthcheck: `unhealthy` while sealed (correct), `healthy` within one
  interval of unsealing

## Secret Rotation

`scripts/rotate_secret.sh` and `scripts/check_rotation_due.sh` close the
"Secret rotation policy" item from `Plan.md`. Full details, including the
human-in-the-loop steps for actually rotating the GitHub PAT (generating a
new one and revoking the old one both require GitHub itself, not
something Vault or this script can do), are in
`runbooks/rotate_github_token.md`.

The short version: rotation is "write a new KV v2 version" — old versions
stay readable (real rollback, not just claimed; verified by reading back
version 2 after rotating to version 3) until someone explicitly destroys
them. `rotated_at`/`previous_version` land in the secret's
`custom_metadata` on every rotation, and `check_rotation_due.sh` compares
that against a policy interval (default 90 days, matching
`platform/iac/variables.tf`'s `secret_rotation_interval_days`) to report
whether a secret is overdue.

**Tested against a throwaway secret** (`secret/devops/test-rotation`,
created and deleted within this session), not the real GitHub token —
this session needed to keep using that token for its own `git push`
commands, so the actual rotation runbook was validated mechanically
without executing it for real. See `runbooks/rotate_github_token.md`
"Verified" section for the specific test results and one real bug found
(`vault kv metadata get` doesn't support `-field` in this Vault version —
only `vault kv get` does; fixed by switching to `-format=json` + Python).

## Known Gaps / Next Steps

- **Only one secret migrated, as a proof of concept.** `station1-hello`
  itself has no secrets today (it's stateless), so there was nothing
  pilot-specific to migrate yet. When a future pilot needs a database
  password or API key, it should land under `secret/<pilot-name>/*` with
  its own least-privilege policy, following this exact pattern.
- **No auto-unseal.** Every `docker compose restart`/host reboot requires
  manually re-running `init_and_unseal.sh` (or at least the unseal half).
  A real deployment would use a cloud KMS auto-unseal — deferred along
  with the rest of the cloud adapter work (`docs/Network.md`'s "Public URL
  experiment", not yet built).
- ~~No secret rotation~~ **Done** — see "Secret Rotation" above and
  `runbooks/rotate_github_token.md`. The mechanism (rotate + check-due) is
  built and tested; the real GitHub PAT itself hasn't actually been
  rotated yet (no need to — it isn't due, and doing so would have broken
  this session's own `git push` commands mid-session).
- ~~No Gitleaks history scan~~ **Done** — see `platform/security/README.md`
  (`scan_secrets.sh`), which scanned this repo's full commit history:
  no leaks found.
- **`.env`-reading tooling from this session (e.g. `git push` using
  `GITHUB_TOKEN` from `~/.env`) was not rewired to read from Vault.** That
  would be a meaningful behavior change to an already-working flow outside
  this repo's scope (`~/.env` is the user's global credential file, not
  something `platform/vault/` owns) — noted here rather than done silently.

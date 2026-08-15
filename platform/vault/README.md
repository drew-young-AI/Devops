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

`secret/devops/github` — GitHub PAT (fine-grained, repo-scoped), migrated
from `~/.env`'s `GITHUB_TOKEN`, as a proof-of-concept of the migration
contract in `NEW_SERVICE_GUIDE.md` ("Secret 只保存 Secret Manager
reference"). This is a demonstration of the mechanism, not a rewiring of
every place this session used `~/.env` directly (e.g. `git push` in this
repo's own commit history still reads `~/.env` — deliberately left alone;
forcibly cutting over an already-working, low-risk flow for marginal
benefit wasn't worth the regression risk. See "Known Gaps" below).

`secret/devops/ghcr` — a **separate** classic GitHub PAT with
`write:packages` scope, added when `platform/compose/deploy.sh push`
needed to authenticate to GitHub Container Registry. Deliberately not the
same credential as `secret/devops/github`: GHCR only supports classic
PATs (fine-grained tokens fail outright, confirmed against GitHub's docs
— see `platform/compose/README.md`'s "Registry Promotion (GHCR)"), and
the two tokens authorize genuinely different things (git operations vs.
registry push) even though both are nominally "the same GitHub account."

**No plaintext secret value ever appears in this repo, in evidence files,
or in command output that got logged** — verified by comparing byte
lengths before/after migration (93 chars both sides for the git PAT)
instead of ever printing the value; see
`evidence/vault/setup_verification.json`.

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

## DataOps Namespace (2026-08-13)

Per `docs/Future-DataOps.md`'s repo-boundary decision (a future DataOps/MLOps
repo consumes this platform as a service, doesn't share code), the
`secret/dataops/*` namespace was built and verified **before** any real
DataOps repo or pilot exists — same reasoning as building `deploy.sh`'s
blue/green mechanism ahead of a second pilot: prove the platform capability
generically, don't wait for a specific consumer.

`platform/vault/policies/dataops-readonly.hcl` mirrors
`devops-readonly.hcl` exactly (`read` on `secret/data/dataops/*`,
`read`+`list` on `secret/metadata/dataops/*`), created in the running Vault
via `vault policy write dataops-readonly -` (stdin, not `docker cp` — this
container's rootfs is read-only, `docker cp` into it fails by design).

**Verified with a throwaway secret** (`secret/dataops/test-placeholder`,
created and deleted within this session — no real DataOps secret exists
yet), a token scoped only to `dataops-readonly`, and the same 4 boundary
tests as the devops policy, plus a 5th that specifically checks
cross-namespace isolation:

| Test | Expected | Actual |
|---|---|---|
| Read `secret/dataops/test-placeholder` | Allowed | `200`, value returned |
| List all secrets engines (`vault secrets list`) | Denied | `403 permission denied` |
| Create a new policy (`vault policy write`) | Denied | `403 permission denied` |
| Read `secret/devops/github` (**cross-namespace**) | Denied | `403 permission denied` |

The fourth test is the one that matters most here: it proves a
`dataops`-scoped token cannot reach into the `devops` namespace's secrets
(and by the same policy shape, a `devops`-scoped token can't reach into
`dataops`'s) — the two tenants are genuinely isolated, not just
conventionally separated by path naming.

Throwaway secret and its token were deleted/revoked after the test; the
`dataops-readonly` policy itself is the real, persistent deliverable and
remains in Vault, ready for the first real `secret/dataops/*` value.

## Identity: Human RBAC and Workload Identity (2026-08-14)

`scripts/setup_identity.sh` (idempotent) + `scripts/verify_identity.sh`
(14 boundary assertions, all passing).

Human RBAC and workload identity are **one mechanism with two kinds of
subject**, not two systems. Both answer the same question — *how does this
subject prove who it is, and what may that identity do* — and both resolve
to a token whose capabilities come from the same `policies/*.hcl` files.
Splitting them into separate systems is how the two drift apart until
nobody can answer "who can read this secret" without checking two places.

| Subject | Proves identity via | Vault auth method |
|---|---|---|
| human | username + password | `userpass` |
| workload | `role_id` + `secret_id` | `approle` |

### The RBAC matrix

| Role | Subject | May | May not |
|---|---|---|---|
| `platform-operator` | human | read devops + pilot secret values | create policies, enable auth methods |
| `platform-viewer` | human | read secret **metadata** (existence, versions, rotation dates) | read any secret **value** |
| `platform-admin` | human | `default` only — see note | anything privileged |
| `workload-station1-hello` | machine | read `secret/pilots/station1-hello/*` | any other path |
| `workload-dataops` | machine | read `secret/dataops/*` | cross into `devops` |
| `ci-pipeline` | machine | read `secret/devops/ghcr` only | read the git PAT |

`platform-admin` is deliberately created with the `default` policy, not
root. A standing root-equivalent human account is precisely what this
mechanism exists to remove; elevating it belongs with the break-glass and
audit design, which is still open (it depends on the auditing body).

### `platform-viewer` is the load-bearing role

It makes one distinction real and enforceable: **"can see that a secret
exists and when it was last rotated" is a different privilege from "can read
it"**. KV v2 splits these into separate API paths — `secret/metadata/*`
versus `secret/data/*` — so this is not a convention or a UI setting, it is
two paths with two capabilities, checked by Vault.

That is the tier a data owner, auditor, or manager needs: they can run
`check_rotation_due.sh` and answer "is this credential overdue?" without
ever being able to read the credential. Verified: the viewer token reads
`kv metadata get secret/devops/github` successfully and is denied
`kv get secret/devops/github` with a permission error.

### Verified (14/14, real tokens, real requests)

A policy file is a claim; `verify_identity.sh` is the evidence. Every case
mints a real token through the real auth method, because the failure mode of
an access-control policy is not an error — it is a silent success by the
wrong subject.

- AppRole login works end-to-end (mint `secret_id` → login → token)
- Workload reads its own path; **denied** another pilot's path, the devops
  namespace, and `policy list`
- Workload token TTL is 1199s — short-lived identity today, without waiting
  for dynamic secrets
- `ci-pipeline` reads the GHCR credential; **denied** the git PAT. This is
  the payoff for keeping the two GitHub credentials at separate paths:
  separate paths are what make separate grants possible
- Operator reads secret values; **denied** `policy write` and `auth enable`
- Viewer reads metadata; **denied** every secret value

### Dynamic secrets: seam kept, not enabled

Long-lived static credentials remain in use — a decision, not an oversight:
there is no database to issue dynamic credentials against yet. The seam is
reserved in `policies/workload-station1-hello.hcl`, and the point is what
does *not* change on the day it is enabled: the AppRole, the workload's
identity, how it authenticates, and who administers it all stay put. Only
the path it may read changes, from static `secret/data/...` to dynamic
`database/creds/...`.

That asymmetry is the reason to build identity first and credentials
second — **identity is the expensive thing to retrofit, credential lifetime
is a dial.**

## Audit Trail (2026-08-14)

```bash
platform/vault/scripts/setup_audit.sh          # idempotent, self-verifying
platform/vault/scripts/audit_query.sh --help   # auditor-facing view
```

Until this existed, the platform could **enforce** access control but could
not **evidence** it. Every boundary in `verify_identity.sh` proves what is
*possible*; only an audit log records what actually *happened*. To an
auditing body those are different questions, and the second is the one they
ask.

### Read this before enabling: audit devices are FAIL-CLOSED

If every enabled audit device fails to write, **Vault stops serving requests
entirely** — it will not perform an operation it cannot record. Correct
security posture, and a genuine availability hazard: a full disk on the
audit volume becomes a total Vault outage, which here also stops deploys.

Two deliberate mitigations:

1. **Two devices, not one.** Vault proceeds if at least one device accepts
   the record, so a single failing sink degrades instead of halting.
   - `file/` → `/vault/logs/audit.log` on the `vault-logs` volume. The
     durable record of truth, included in `platform/backup/`.
   - `stdout/` → Docker logs → Alloy → Loki. Queryable alongside every other
     platform log, and the second sink that keeps one failure from halting
     Vault.
2. **A real volume, not the tmpfs that used to be there.** See below.

`audit_query.sh` surfaces the log size on every invocation rather than
hiding it behind a check nobody runs, and warns past 100MB.

### The tmpfs that would have failed in the worst possible way

`/vault/logs` was a 4MB tmpfs, justified by "not used — Vault logs to stdout
by default". True until the moment an audit device was enabled.

Left alone, the audit trail would have been **capped at 4MB and erased on
every restart, while `vault audit list` still reported a healthy device**.
An audit log that evaporates is worse than no audit log, because it looks
like coverage. Now a named volume (`vault-logs`), and in the backup set —
it is the one record here that cannot be reconstructed from anything else:
git can be re-cloned and evidence re-generated, but nobody can re-derive who
read a secret last Tuesday.

### Secret values are HMAC'd — verified, not assumed

Vault HMAC-SHA256s sensitive values before writing, so the log records
*that* a secret was read without recording the secret. `setup_audit.sh`
checks this for real: it reads a known secret, then greps the audit log for
that literal value and **fails the setup** if it appears.

`log_raw=true` disables the protection and must never be set — it would turn
the audit trail into the largest plaintext secret store in the platform.

### What it produced immediately

Three identities, one secret, one query:

```
userpass-platform-operator  read  allowed  secret/data/devops/github
userpass-platform-viewer    read  DENIED   secret/data/devops/github
userpass-platform-viewer    read  allowed  secret/metadata/devops/github
```

The audit trail independently confirms the RBAC boundary that
`verify_identity.sh` asserts — evidence that the viewer role was *actually
refused in production*, not merely that a test says it would be.

`audit_query.sh --denied` is the query an auditor reaches for first.

### Why a query tool, not just the log

The raw log is one ~2KB JSON object per request with every interesting value
HMAC'd. Handing an auditor `tail audit.log` is not an audit capability, it is
a pile of bytes that happens to contain the answer. `audit_query.sh` reduces
it to who / when / allowed-or-denied, with `--path`, `--actor`, `--denied`
and `--json` filters.

Reading it requires access to the Vault container, deliberately narrower
than the `platform-viewer` role: **seeing who read what is a higher
privilege than seeing that a secret exists.**

### Known gaps

- **No rotation or archival.** The log grows without bound, and fail-closed
  means an unbounded log is an outage waiting for a full disk. Size is
  reported; nothing acts on it yet.
- **No alert on audit-device failure.** Vault is not a Prometheus scrape
  target, so a device that stops writing is invisible until Vault starts
  refusing requests.
- **No tamper protection.** The log is a file; anyone with root on the host
  can rewrite it. Genuine non-repudiation needs WORM storage or an external
  sink, which is the same gap `docs/System-State.html` tracks under B.
- **Retention is undefined.** How long audit records must be kept is an
  auditing-body decision that has not been made, so nothing has been deleted
  and no policy has been guessed at.

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

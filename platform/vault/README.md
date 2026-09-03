---
type: platform-adapter
title: Vault 機密、身分與稽核
description: Secret storage, rotation, the unified human-RBAC and workload-identity mechanism, and the fail-closed audit trail.
tags:
  - vault
  - secrets
  - identity
  - audit
timestamp: 2026-08-15T19:56:31+08:00
---

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
[`runbooks/rotate_github_token.md`](runbooks/rotate_github_token.md).

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
  sink -- the same gap `docs/Backlog.md` §5 tracks (offsite backup, awaiting a destination decision).
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
- **No secret rotation~~ **Done** — see "Secret Rotation" above and
  `runbooks/rotate_github_token.md`. The mechanism (rotate + check-due) is
  built and tested; the real GitHub PAT itself hasn't actually been
  rotated yet (no need to — it isn't due, and doing so would have broken
  this session's own `git push` commands mid-session).
- **Credential Location Reference:** For operational troubleshooting, note that:
  - Vault Root Token and human role passwords (platform-admin, platform-operator, platform-viewer) are stored in:
    - `/Users/drew/ENV/Devops/platform/vault/.init-output.json` (root token)
    - `/Users/drew/ENV/Devops/platform/vault/.identity-output.json` (human role passwords)
  - Grafana admin credential (username: admin) is synchronized from Vault secret `secret/devops/grafana-admin` to:
    - `/Users/drew/ENV/Devops/platform/observability/.grafana.env` (gitignored, disposable)
  - These files are intentionally gitignored and should be managed via a password manager. Never commit them.
- ~~No Gitleaks history scan~~ **Done** — see `platform/security/README.md`
  (`scan_secrets.sh`), which scanned this repo's full commit history:
  no leaks found.
- **`.env`-reading tooling from this session (e.g. `git push` using
  `GITHUB_TOKEN` from `~/.env`) was not rewired to read from Vault.** That
  would be a meaningful behavior change to an already-working flow outside
  this repo's scope (`~/.env` is the user's global credential file, not
  something `platform/vault/` owns) — noted here rather than done silently.

## Dynamic database credentials（2026-08-18）

最後一項未兌現的 Vault 機制。接縫在 `workload-station1-hello.hcl` 留了很久，
在此之前一直用長期靜態密碼——這是決定，不是疏漏：當時沒有資料庫可以簽發。
station2-twin 改變了這一點。

```bash
platform/vault/scripts/setup_database_secrets.sh station2-twin
platform/vault/scripts/verify_database_secrets.sh station2-twin

```

**身分模型完全沒有改變。** 同一套 AppRole、同樣的認證、同樣的管理方式。
只有 workload 讀取的**路徑**變了：靜態的 `secret/data/...` 變成動態的
`database/creds/...`。這正是當初「先建身分、後建憑證」的論據——而那個論據
成立了。

| | 靜態密碼 | 動態憑證 |
|---|---|---|
| 誰在用 | 共用，稽核記錄無法歸屬 | 每個 workload 自己的資料庫使用者 |
| 撤銷 | 換一次要重啟全部 | 撤銷單一 lease，其他不受影響 |
| 洩漏 | 永久有效 | TTL 到期自動失效 |
| 權限 | 連 schema owner 權限一起拿到 | 只有 SELECT / INSERT / UPDATE |

### Verified

| 注入條件 | 結果 |
|---|---|
| 讀取 `database/creds/station2-twin` | 可連線、讀到 109,907 列 |
| 連續讀兩次 | **產生兩個不同的使用者**，非共用 |
| 以該憑證 INSERT | 允許（應用程式需要） |
| 以該憑證 `DROP TABLE` | **拒絕** — least privilege 成立 |
| 以該憑證 `DELETE` | **拒絕** — 未授予即不可用 |
| **撤銷 lease 後再用同一組憑證** | **被 postgres 拒絕** |
| 服務實際運行 | `pg_stat_activity` 顯示 `v-approle-station2-...` |
| 撤銷服務正在用的 lease 後重啟 | 自動取得新憑證，`mode=vault` |

最後一列之前的每一項，在「dynamic 只是裝飾」的系統上都會照樣通過。
**撤銷測試是唯一能分辨真假的一項。**

### 一個安靜失敗，值得記錄

第一版的 revocation statements 用了標準寫法
`REASSIGN OWNED BY` → `DROP OWNED BY` → `DROP ROLE`。它**失敗的方式最糟糕**：

- `vault lease revoke` 回報 `All revocation operations queued successfully!`
- HTTP 202
- 憑證**繼續可用**
- Vault 在背景無限重試，只有 server log 說得出原因

```
permission denied to reassign objects (SQLSTATE 42501)
Only roles with privileges of role "v-..." may drop objects owned by it

```

PostgreSQL 16 要求「繼承的」成員資格才算擁有該 role 的權限，而 `vault_admin`
是刻意設為 `NOINHERIT`——為了讓它「是 schema owner 的成員」不等於「就是
schema owner」。為了讓 `DROP OWNED` 能跑而放寬這一點，是拿真實的權限邊界
換方便。

改法：**明確撤銷當初授予的東西**。`vault_admin` 是授予者，撤銷不需要繼承
任何權限；而產生的 role 本來就不可能擁有任何物件（它沒有 DDL 權限），
`DROP OWNED BY` 從頭到尾只是在失敗而已。

### 已知限制

- **沒有實作持續續約（lease renewal）**。connection pool 的 `max_lifetime`
  設得比憑證 TTL 短，所以連線會回收並重新取得憑證。續約迴圈是第二個更難
  察覺的出錯點，而這個 pilot 的目的是證明機制，不是實作 Vault client。
- **`secret_id` 目前沒有 TTL**（`secret_id_ttl=0`）。正式環境應設定期限並
  搭配 response-wrapping 交付。

---

## AppRole 必須被「送達」，不能假設它在操作者的 shell 裡（2026-09-01）

`pilots/station2-twin/compose.yaml` 從環境變數取 AppRole：

```yaml
VAULT_ROLE_ID: ${VAULT_ROLE_ID:-}
VAULT_SECRET_ID: ${VAULT_SECRET_ID:-}
```

空的時候應用會退回靜態資料庫密碼。**那個 fallback 是刻意的**——
pilot 必須在沒有 Vault 的情況下也跑得起來，而 `/health/ready` 會回報
實際生效的是哪一種模式。設計是對的。

**出問題的是它有多容易「不小心」發生。**

### 實際發生的事

宿主休眠，所有容器一起停。`recover.sh` 從當下那個 shell 執行
`docker compose up`——而那個 shell 沒有 export AppRole。於是：

| 副本 | 恢復後 |
|---|---|
| Compose（develop） | `mode: static` ← **悄悄降級** |
| K8s | `mode: vault` |

**兩份副本的憑證模型和當天早上完全對調了。** 早上是 K8s 那份比較弱，
修好之後換成 Compose 那份比較弱，而中間沒有任何人做過任何決定。

唯一發現它的，是幾小時前才寫下的
`test_migration_observed.sh`「兩份副本的 `credentials.mode` 必須相同」。

### `.gitignore` 早就為它留了位置，然後沒有人接上

```
# AppRole secret_id delivered to the pilot container. Regenerable from
# Vault; never committed.
pilots/station2-twin/.env.vault
```

這段存在數週。**沒有東西寫它，也沒有東西讀它。** 慣例被宣告、被寫進註解、
從未接上——又一個「登記為存在，但不會執行」。

### 修法：與 K8s 那邊同一個原則

讓啟動路徑**擁有自己的前置條件**：

```
platform/vault/scripts/write_pilot_approle_env.sh
  .station2-twin-approle.json  →  pilots/station2-twin/.env.vault (mode 600)

platform/recover.sh
  先呼叫上者，然後 docker compose --env-file ...
  沒有 AppRole 時：大聲說出後果，並回傳非零
```

`secret_id` 全程不進 argv（`ps` 在這台機器上是全域可讀），
檔案以 **umask 建立而非事後 chmod**——chmod 會留下一個檔案已存在、
且任何人都讀得到的時間窗。

**靜態密碼模式仍然受支援。不知不覺走到那裡則不受支援。**

### 守衛（三層，因為它們可以各自壞掉而不被彼此發現）

| 檢查 | 位置 | 驗證什麼 |
|---|---|---|
| 接線 | `test_static.sh` tier 1 | 恢復流程有傳 `--env-file` |
| 行為 | `test_approle_env.sh` tier 1 | 寫入器真的產出檔案、模式 600、不印出 secret、缺欄位就拒絕 |
| 結果 | `test_migration_observed.sh` tier 3 | 兩份**執行中**的副本 mode 相同 |

突變測試（四個，全部被抓，兩個檔案還原後皆逐位元相同）：
缺 AppRole 改成 exit 0、umask 改成 000、確認訊息印出 secret_id、
恢復流程拿掉 `--env-file`。

### 一個關於守衛本身的教訓

「恢復流程有傳 `--env-file`」這條檢查，**第一版是錯的**：它 grep 整個
`recover.sh` 找 `--env-file` 字串，而我寫在上面幾行的說明註解裡就有這個字串。
突變把真正的參數刪掉，檢查依然是綠的。

同一個 session、同一個檔案，這是**第二次**——前一次是
「有東西提到 `.env.vault`」被當成「有東西寫 `.env.vault`」。

> 基於 grep 的檢查，必須先被告知哪些行才是程式碼。

---

## 輪替相關的可執行腳本（2026-09-02 補上索引）

這四支是**人要跑的**，但在 2026-09-02 之前它們**沒有出現在任何從 README 連得到的文件裡**——
只被其他腳本呼叫。**被程式呼叫不等於找得到**：下一個人（或下一隻 agent）找不到，就會再寫一支。

| 腳本 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`scripts/setup_rotation_check.sh`](scripts/setup_rotation_check.sh) | **一次性** | 發出只讀 metadata 的 AppRole，讓排程的 `rotation` job 不必用高權限身分 | 跑完之後該 job 才會停止回報「not configured」；**排程檢查用的身分只該讀得到 metadata，不該讀得到 secret 本身** |
| [`scripts/set_rotation_policy.sh`](scripts/set_rotation_policy.sh) | 每新增一個 secret | 設定**單一** secret 的輪替週期，或記錄它為豁免 | **週期是資料不是常數**——寫死在腳本裡的週期，改的時候會漏掉某一個；豁免必須具名記錄 |
| [`scripts/rotation_drill.sh`](scripts/rotation_drill.sh) | 定期演練 | 證明憑證**真的換得掉**，端到端 | 與 `restore_drill.sh` 對備份的論證相同：**沒演練過的輪替政策，和沒有輪替政策的差別只在文件上** |
| [`scripts/check_rotation_sweep.sh`](scripts/check_rotation_sweep.sh) | 排程 `rotation` | 掃過每一個 secret 比對輪替週期 | **全部豁免時回 rc 2 `ROTATION VACUOUS`**——在空集合上「每一個都合規」是恆真句，不是驗證結果 |

守衛：`platform/tests/test_static.sh` 斷言 `set_rotation_policy.sh` 的週期表與實際 secret 對得起來；
`platform/docs/capability_graph.py` 斷言以上每一支都被這張表描述到。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。
**只寫一句「見某腳本」不算描述**——那句話說不出何時跑、做什麼、保證什麼。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`scripts/init_and_unseal.sh`](scripts/init_and_unseal.sh) | **一次性**，全新 Vault | 初始化並解封 | 產出的 unseal key 與 root token 是這個 Vault 所有 secret 的主鑰，寫進 gitignore 的 `.init-output.json`，不進 repo |
| [`scripts/setup_identity.sh`](scripts/setup_identity.sh) | 一次性，之後改權限時 | 建立身分機制：人的 RBAC 與工作負載身分 | **兩種主體共用同一套 policy、同一個稽核面、同一套管理**——拆成兩套會讓其中一套先腐爛 |
| [`scripts/verify_identity.sh`](scripts/verify_identity.sh) | 每次改 policy 後 | 對每一條邊界發出**真實**請求並斷言允許／拒絕 | policy 檔是主張，這支是證據。存取控制的失效模式是**看起來被設定了**，只有真的發請求才分得出來 |
| [`scripts/setup_audit.sh`](scripts/setup_audit.sh) | 一次性 | 開啟稽核裝置 | 從「能執行存取控制」升級成「能舉證」：誰讀了哪個 secret、何時、成功與否 |
| [`scripts/audit_query.sh`](scripts/audit_query.sh) | 稽核時 | 把每筆 ~2KB、值被 HMAC 的原始 JSON 整理成人看得懂的視圖 | 把 `tail audit.log` 那堆位元組變成真的能回答問題的稽核能力 |
| [`scripts/rotate_audit_log.sh`](scripts/rotate_audit_log.sh) | 排程 | 輪替稽核 log | **這不是清潔工作**：Vault 稽核裝置是 fail-closed，全部寫不進去時 Vault 會**拒絕所有請求**——secret、身分、部署一起停 |
| [`scripts/setup_database_secrets.sh`](scripts/setup_database_secrets.sh) | 一次性 | 啟用 database secrets engine，發短期憑證 | 取代長期靜態密碼；每個程序一組帳密、TTL 1200s、被拒即重建連線池 |
| [`scripts/rotate_secret.sh`](scripts/rotate_secret.sh) | 需要換某個 secret 時 | 寫入新版本並記錄 `rotated_at` | **完全依賴 KV v2 原生版本控制做回滾**，不刪不銷毀舊版本——刪除是另一個刻意的動作 |
| [`scripts/check_rotation_due.sh`](scripts/check_rotation_due.sh) | 排程 / 手動 | 依 `rotated_at` 判斷單一 secret 是否逾期 | 週期預設 90 天，可由 `set_rotation_policy.sh` 覆寫 |
| [`scripts/write_pilot_approle_env.sh`](scripts/write_pilot_approle_env.sh) | Pilot 重啟前 | 把 AppRole 寫進 compose 讀的 env 檔 | AppRole 必須**被送達**，不能假設它在操作者的 shell 裡——沒送達時 Pilot 會靜默退回靜態密碼 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`scripts/verify_database_secrets.sh`](scripts/verify_database_secrets.sh) | 動態憑證機制變更後 | **證明動態憑證真的是動態的** | 「憑證短期且可撤銷」用嘴說一文不值。**撤銷後還能用的憑證，是一個加了戲的靜態密碼** |

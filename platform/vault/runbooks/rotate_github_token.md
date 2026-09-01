---
type: runbook
title: 輪替 GitHub Token
description: Human-in-the-loop procedure for rotating the GitHub PAT, including the steps only GitHub itself can perform.
tags:
  - runbook
  - vault
  - rotation
timestamp: 2026-08-09T22:29:55+08:00
---

# Runbook: Rotate the GitHub PAT in Vault

**When**: every 90 days (`rotation_policy_days` custom_metadata on
`secret/devops/github`, matching `platform/iac/variables.tf`'s
`secret_rotation_interval_days` default), or immediately if the token may
have been exposed.

**Check whether it's due**:

```bash
export VAULT_ADDR=http://127.0.0.1:18200
export VAULT_TOKEN=<root token, from platform/vault/.init-output.json>
platform/vault/scripts/check_rotation_due.sh devops/github

```

## Why this is a runbook, not a script

Generating a new GitHub PAT and revoking the old one both require
interacting with GitHub itself (web UI, or the GitHub CLI with an
*already-authenticated* session) — there's no way to fully automate "get a
brand new credential" without either an existing valid credential to
bootstrap from, or a human in the loop. This runbook is the human-in-the-
loop half; `rotate_secret.sh` is the automatable half (writing the new
value into Vault safely, with rollback capability via KV v2 versioning).

## Steps

1. **Generate a new PAT** (fine-grained, minimum scope needed — see
   `docs/Security.md` "不使用長期 access key" / minimal-scope principle):
   - GitHub → Settings → Developer settings → Personal access tokens
   - Set an expiration (do not create a non-expiring token)
   - Copy the new value — you will only see it once

2. **Write the new value into Vault** (never as a CLI argument, never
   echoed to a terminal that gets logged):

   ```bash
   export VAULT_ADDR=http://127.0.0.1:18200
   export VAULT_TOKEN=<root token>
   read -rs NEW_PAT   # paste, does not echo to terminal
   echo -n "$NEW_PAT" | platform/vault/scripts/rotate_secret.sh devops/github token
   unset NEW_PAT

   ```

   This creates a new KV v2 version, records `rotated_at` in
   `custom_metadata`, and verifies the round-trip by length comparison —
   the plaintext value is never printed by the script.

3. **Update anywhere that reads the old value directly from `~/.env`**
   (not from Vault) — see `platform/vault/README.md`'s "Known Gaps": this
   session's own `git push` commands read `GITHUB_TOKEN` from `~/.env`
   directly, not from Vault. Update `~/.env` with the new value too, or
   migrate that flow to read from Vault (`platform/vault/scripts/`
   currently has no "read for shell export" helper — would be a
   reasonable follow-up if `~/.env` usage is fully retired).

4. **Verify the new token actually works** before revoking the old one:

   ```bash
   GITHUB_TOKEN=<new value> gh auth status

   ```

5. **Revoke the old PAT** on GitHub (Settings → Developer settings →
   Personal access tokens → the old one → Delete). Only after step 4
   confirms the new one works — revoking first and discovering a problem
   second would lock out any tooling still using the old value with no
   fallback.

6. **Do not delete the old Vault KV version immediately.** It's harmless
   to leave (it's already revoked on GitHub's side, so it's not a live
   credential anymore — just historical record). If you do want to prune
   it later: `vault kv metadata delete -versions=<N> secret/devops/github`
   deletes a specific version's data while keeping the version-number
   slot (soft delete, recoverable); `destroy` removes it permanently.

## Verified (2026-08-09)

The Vault-side mechanics (`rotate_secret.sh` and `check_rotation_due.sh`)
were tested end-to-end against a throwaway test secret
(`secret/devops/test-rotation`, created and deleted within this session —
never against the real GitHub token, which this session needed to keep
using for its own `git push` commands):

| Check | Result |
|---|---|
| Rotate | version 1 → 2 → 3, each write recorded `rotated_at`/`previous_version` in `custom_metadata` |
| Round-trip verification without printing the secret | Length comparison only (21 == 21) |
| **Old version still readable after rotation** | `vault kv get -version=2 ...` succeeded — real rollback capability, not just claimed |
| `check_rotation_due.sh`, just-rotated | `OK: 90 days remaining`, exit 0 |
| `check_rotation_due.sh`, never rotated | Correctly reports "no rotation record" (tested against the real `secret/devops/github`, which has a `migrated_at` timestamp but no `rotated_at` — accurate: it really hasn't been rotated since migration), exit 2 |
| `check_rotation_due.sh`, forced-overdue (`interval_days=0`) | `ROTATION DUE`, exit 1 |

A real bug was found and fixed during this testing: `rotate_secret.sh`
originally used `vault kv metadata get -field=current_version`, but this
Vault version's `metadata get` subcommand doesn't support `-field` at all
(`flag provided but not defined: -field`) — only `vault kv get` (the data
read, not metadata read) supports that flag. Fixed by switching to
`-format=json` and parsing with Python, matching the pattern
`check_rotation_due.sh` already used correctly.

## Known Gaps

- No automated reminder/paging when a secret becomes overdue —
  `check_rotation_due.sh` has to be run manually or wired into some
  external scheduler (cron, GitHub Actions on a schedule trigger) to
  actually notify anyone.
- Only `secret/devops/github` has rotation metadata conventions
  established. A new secret should get the same `migrated_at`/
  `rotation_policy_days` custom_metadata treatment when it's first
  created, not left implicit.
- No automatic Vault-write privilege separation for rotation. This
  runbook uses the root token because `devops-readonly`
  (`platform/vault/policies/devops-readonly.hcl`) deliberately has no
  write capability — correct for routine automation, but means a real
  team would want a dedicated, narrowly-scoped "rotator" policy/token
  instead of reaching for root every time. Not built this session.

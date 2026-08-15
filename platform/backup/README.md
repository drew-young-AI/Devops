---
type: platform-adapter
title: 備份與還原演練
description: "Backup adapter and the restore drill that proves recoverability: what is backed up, what is deliberately excluded, and why the unseal keys are not in the archive."
tags:
  - backup
  - restore
  - disaster-recovery
timestamp: 2026-08-15T19:57:20+08:00
---
# Backup Adapter

```bash
platform/backup/backup.sh          # take a backup
platform/backup/restore_drill.sh   # prove the newest one is restorable
```

## The distinction this adapter is built around

"We have backups" is a claim about files existing. "We can restore" is a
different and much stronger claim, and it is the only one that matters at
3am. Everything here is arranged so that the second claim is the one being
made — `backup.sh` is half the mechanism, `restore_drill.sh` is the other
half, and a backup that has never been through the drill is not counted.

## What is backed up, and what is not

| Volume | Backed up | Why |
|---|---|---|
| `vault_vault-file` | yes | irreplaceable — every secret, policy, auth method |
| `observability_grafana-data` | yes | users, orgs, API keys, annotations |
| `observability_alertmanager-data` | yes | silences; losing them re-floods every alert |
| `observability_prometheus-data` | **no** | 24h retention, regenerable by scraping |
| `observability_loki-data` | **no** | 24h–7d retention, regenerable telemetry |

The two exclusions are decisions, not omissions: both hold short-retention
telemetry that is worthless a week later, and including them would multiply
backup size for no recovery value. **If retention is ever extended for
compliance reasons, that decision must revisit this list** — the reason they
are excluded is precisely the property that would stop being true.

## The property that is easy to get wrong

Vault's file storage is encrypted at rest. So the archive is safe to hold —
and **useless on its own**. Restoring it requires the unseal keys in
`platform/vault/.init-output.json`, which the backup deliberately does *not*
include.

Backing up data and backing up the ability to read it are two different
things. Putting both in one archive would convert a safe backup into a
single file that hands over every secret in the platform. The manifest
records this dependency explicitly so a future restorer discovers it before
an incident rather than during one.

## The drill

Three rules, each one closing a way that restore procedures usually fail:

1. **Never restore over the live system.** Everything happens in a scratch
   container on port 18299 with a throwaway volume. A restore procedure
   whose only rehearsal destroys production is not a procedure, it is a
   threat — so it never gets rehearsed, so it never works.
2. **Verify integrity before restoring.** The manifest's sha256 is checked
   against the archive on disk first. Silent corruption between backup and
   restore is caught, not faithfully restored.
3. **Prove the data is usable, not merely present.** Extracting a tar proves
   nothing about Vault. The drill unseals the restored Vault with the real
   unseal keys and reads back a real secret. If that fails, the backup was
   worthless no matter how clean the tar was.

### Verified 2026-08-14 — 9/9

| Check | Result |
|---|---|
| sha256 matches manifest (3 archives) | pass |
| archive extracts into scratch volume | pass |
| restored Vault reports `initialized=true` | pass — real state, not an empty volume |
| restored Vault unseals with the real keys | pass |
| secret read back matches live | pass — 93 chars, value never printed |
| identity model survived (8 policies) | pass |
| auth methods survived (approle present) | pass |
| live Vault untouched throughout | pass |

The `initialized=true` and policy-count checks exist because a naive drill
passes too easily: a root token reading a secret from a half-restored Vault
would look fine while every policy and auth method had silently been lost.

### One real bug the drill found

The unseal loop applied the first key and then exited, leaving Vault sealed
at 1/3 **with no error printed anywhere**. Cause: `docker exec -i` attaches
the caller's stdin, so inside a `while read` loop it consumed the remaining
two unseal keys from the loop's own input.

This is the exact shape of bug the drill exists to catch — a restore
procedure that looks correct, runs without error, and silently produces an
unusable system. Fixed by redirecting `</dev/null` on the exec and reading
keys into an array first.

## Known gaps

- **No offsite copy.** Archives live on the same disk as the volumes they
  back up, so a disk failure loses both. Fixing this needs a destination
  decision (external drive, object storage) that has not been made.
- **No schedule.** Backups are manual. Automating them should wait until the
  offsite question is answered, since a scheduled backup to the same disk
  mostly produces confidence rather than recoverability.
- **No retention/pruning for archives.** They accumulate.
- **Grafana and Alertmanager archives are only integrity-checked, not
  restore-drilled.** Only Vault gets the full usability drill. Extending the
  drill to Grafana would mean standing up a scratch Grafana and asserting a
  known dashboard and user survive.

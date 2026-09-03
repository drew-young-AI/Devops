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

## Offsite (2026-08-16)

```bash
BACKUP_OFFSITE_DEST=/Volumes/Backup/devops platform/backup/sync_offsite.sh
BACKUP_OFFSITE_DEST=... platform/backup/sync_offsite.sh --prune-local 7

```

**It refuses to run unless the destination is on a different device.**

That check is the whole point. Archives and their source lived on one disk,
so the disk failing lost both -- meaning the integrity manifests, the restore
drill and its ten passing assertions protected against nothing that actually
threatened them. The danger was never "we forgot to copy elsewhere"; it was
that copying to another folder on the same disk would *look* like the fix.
`stat -f %d` compares device ids and declines with an explanation rather than
performing theatre.

**No default destination.** These are complete copies of platform state, and
where they go is a decision with consequences. `BACKUP_OFFSITE_DEST` must be
set explicitly; the script otherwise prints the candidate destinations with
the trade-off each carries and exits.

**Copies are re-hashed at the destination** against the manifest recorded at
backup time. Trusting `cp` is the same mistake as trusting an unrestored
backup: a truncated copy still leaves a plausible-looking directory. A copy
that fails verification is deleted rather than left looking good.

**Pruning only removes what is verified elsewhere.** Local archives grow
~22 MB/day (~7.8 GB/year), so pruning is necessary -- but deleting the only
copy of something because the far end *should* have it is how backups become
fiction.

### Verified

| Injected condition | Result |
|---|---|
| no `BACKUP_OFFSITE_DEST` | refused, with the options and their trade-offs |
| destination on the same device | **refused** -- the check that matters |
| genuine second device (mounted image) | 6 sets synced and re-hashed |
| one byte altered at the destination | digest mismatch detected |
| manifest referencing a missing file | sync failed, target removed, **and the local set was KEPT** |
| prune with a verified copy present | removed locally, oldest first |

One bug found doing it: the prune loop used `head -n -N`, which is a GNU
extension that BSD `head` on macOS rejects outright. The substitution came
back empty and the loop silently did nothing while reporting "pruned 0". It
failed in the safe direction this time, but a prune that never prunes is a
disk that fills anyway with nothing saying so.

## Remote offsite: Google Drive (2026-08-16)

`sync_offsite.sh` handles filesystem destinations. `sync_remote.sh` handles
cloud ones, and carries the equivalent refusal for a different failure:

**It refuses to upload unencrypted platform state to a third party.**

Only the Vault archive is encrypted at rest. The rest is not -- ~22 MB of
Grafana data (users, API keys, sessions), the audit trail (every secret path,
policy name and token accessor), Alertmanager silences. Sending that to
Google readable is a disclosure, not a backup. So the destination must be an
rclone `crypt` remote, and a plain one is declined.

```bash
platform/backup/setup_rclone.sh                      # one-time, opens a browser
RCLONE_REMOTE=gdrive-crypt: platform/backup/sync_remote.sh

```

**Credentials never reach the platform.** `rclone authorize` starts a local
callback listener, you sign in to Google in your own browser, and Google
returns an OAuth token. No password is typed into anything here, and none
has to be shared with anyone -- including the agent that wrote the script.

**Scope is `drive.file`, not `drive`.** That grants access only to files the
application itself created; the token cannot read anything already in the
user's Drive. A backup destination never needs to, and a credential that
sits on a laptop for years should be able to do only its one job.

### Configured is not the same as encrypted

The cheap check reads `type = crypt` from `rclone.conf`. That confirms what
was asked for, not what happens. So before every upload, a probe writes a
file containing a unique marker through the crypt remote, then reads the
stored object back **through the underlying remote**, bypassing decryption,
and confirms the marker is not in it.

This is not theoretical. rclone has a `no_data_encryption` option that
encrypts filenames but stores content in the clear -- and such a remote still
reports `type = crypt`. The config check passes it. The probe does not.

### Verified

| Injected condition | Result |
|---|---|
| no `RCLONE_REMOTE` | exit 78 (EX_CONFIG), not a failure |
| no config file | exit 78, points at `setup_rclone.sh` |
| pre-migration single-file config | exit 78, points at the migration |
| non-crypt remote (`type = local`) | **refused** before any upload |
| correct crypt remote | probe pass, filename + content encrypted |
| `no_data_encryption=true` (**still `type = crypt`**) | **leak detected**, refused |
| leaking remote, full sync run | aborted **before** upload -- 0 files written |

### Two bugs found running it

The first version drove `rclone config`'s interactive wizard, which meant it
needed a TTY and could only run from a separate Terminal window. It did not
need one: `rclone authorize` blocks on an HTTP callback, and the only human
step -- clicking Allow -- was never a terminal operation.

Worse, it mounted `rclone.conf` as a **single file**. rclone saves config by
renaming a temp file over it, which is impossible across a single-file bind
mount: it fails with `device or resource busy`, logs the error, prints the
remote it believes it created, and **still exits 0**, leaving a zero-byte
config. The entire browser authorisation would have been spent for nothing,
and the follow-up check would have reported the remote as simply missing.
Fixed by mounting the directory; the config now lives in `.rclone/`.

## Known gaps

- **The upload path is unverified against real Google Drive.** Everything
  above was verified against a local crypt remote, which exercises the same
  code paths but not Drive's API, quotas or token refresh. Until the OAuth
  authorisation is completed, the offsite job correctly reports
  `not-configured` rather than claiming success.
- **`BACKUP_OFFSITE_DEST` (local second device) is still unset.** Drive
  covers losing the machine; a local second device covers restoring quickly.
  They are complements, not substitutes.
- **Token expiry is not yet observed.** Google refresh tokens for an
  unpublished OAuth app can expire after 7 days of inactivity. If the daily
  job starts failing with an auth error, re-run `setup_rclone.sh`.
- **Grafana and Alertmanager archives are only integrity-checked, not
  restore-drilled.** Only Vault gets the full usability drill. Extending the
  drill to Grafana would mean standing up a scratch Grafana and asserting a
  known dashboard and user survive.


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。
**只寫一句「見某腳本」不算描述**——那句話說不出何時跑、做什麼、保證什麼。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`pvc_archive.sh`](pvc_archive.sh) | 由 `backup.sh` 呼叫 | 把單一 Kubernetes PVC 封存成本機檔案 | **PVC 不能當 docker volume 備份**：k3d 經 local-path-provisioner 寫進節點的 `/var/lib/rancher/k3s/storage`，那條路徑背後是**匿名** docker volume |
| [`sync_offsite.sh`](sync_offsite.sh) | 排程 | 把已驗證的備份複製到第二個位置，**並證明那真的是第二個** | 拒絕寫到同一個實體裝置——備份與來源同碟時，整套備份機制（完整性清單、還原演練）保護的是同一次故障 |
| [`sync_remote.sh`](sync_remote.sh) | 排程 | 經 rclone 同步到雲端 remote | `sync_offsite.sh` 的姊妹版，對 remote 帶等價的拒絕條件 |
| [`setup_rclone.sh`](setup_rclone.sh) | **一次性** | 設定 Google Drive 備份目的地 | **你授權，這裡永遠看不到你的密碼**：rclone 開瀏覽器登入頁，Google 回一個 OAuth token |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`backup.sh`](backup.sh) | 排程 | 備份有狀態的平台 volume | **哪些備、哪些刻意不備都是決定**：Vault 檔案與稽核軌無可取代，一定備；可重建的東西不備 |
| [`restore_drill.sh`](restore_drill.sh) | 排程 | **證明備份真的還原得回來** | 「我們有備份」是關於檔案存在的宣稱；這支是「那些檔案能變回一個能動的系統」的證據，**是完全不同、而且強得多的主張** |

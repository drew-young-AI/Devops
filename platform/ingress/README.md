---
type: platform-adapter
title: Ingress（Tailscale）
description: "Exposing a local service off this machine through Tailscale, with a per-target exposure ceiling and verification by observation."
tags:
  - platform
  - ingress
  - tailscale
  - network
timestamp: 2026-08-17T15:58:00+08:00
---

# Ingress

```bash
platform/ingress/ingress.sh --status
platform/ingress/ingress.sh --serve  station1-hello-develop   # tailnet only
platform/ingress/ingress.sh --funnel station1-hello-develop   # public internet
platform/ingress/ingress.sh --off    station1-hello-develop
platform/ingress/ingress.sh --reset

```

## What this closed

`Plan.md` carried **"Public URL — blocked, needs a human to choose a cloud
provider"** as the last open item for weeks. It did not need one.

Every service on this machine binds `127.0.0.1`. Tailscale already runs on
the host and reaches loopback directly, so `tailscale serve` publishes a
service without opening a router port, without an inbound firewall rule, and
without traffic transiting a provider account nobody has created. The blocker
was a assumption about how ingress has to work, not a missing decision.

## Two levels, and the difference is not cosmetic

| | reach |
|---|---|
| `serve` | devices signed into this tailnet |
| `funnel` | the entire public internet, no account required |

They differ by one word on the command line and by everything in blast
radius. So: the default action is always `serve`; `funnel` must be named
explicitly **and** confirmed by typing `PUBLISH`; and every target carries a
ceiling in `targets.conf` that `funnel` cannot exceed.

## The refusal

Ceilings are set by **what authenticates the service**, not by how sensitive
its name sounds.

| target | ceiling | why |
|---|---|---|
| `station1-hello-develop` / `-prod` | funnel | Stateless pilot, fixed JSON, nothing at rest. This is what a public URL is *for*. |
| `grafana` | tailnet | Has a real login, but its dashboards enumerate every service, job and metric — a map of the estate. |
| `prometheus` | **never** | No authentication at all. Reads every metric; the admin API deletes series. |
| `alertmanager` | **never** | No authentication, and `/api/v2/silences` is a **write** endpoint — reaching it is enough to switch monitoring off quietly. |
| `loki` | **never** | No authentication. Redaction at write time is a mitigation, not a guarantee. |
| `vault` | **never** | Secrets. Listed explicitly so "not in the file" can never be read as "nobody considered it". |

A `never` target is declined, not warned about. Putting an unauthenticated
admin surface on the tailnet is not a smaller version of publishing it — it
is the same disclosure with a smaller audience, and the audience grows every
time a device is enrolled.

## Verification is by observation

`tailscale serve` exiting 0 means a proxy was configured, not that the right
service answers on it. After configuring, this fetches the exposed URL *and*
the local port and compares the bodies. On any mismatch — different status,
different bytes, dead backend — the exposure is **torn down** rather than
left half-working.

## Verified

| Injected condition | Result |
|---|---|
| `--serve vault` / `prometheus` / `alertmanager` / `loki` | **refused**, exit 1, nothing exposed |
| `--funnel grafana` (ceiling is tailnet) | **refused**, exit 1 |
| unknown target | exit 2, prints the target list |
| `--funnel` with tailnet HTTPS disabled | exit 78 (EX_CONFIG) + the exact admin-console steps |
| `--serve station1-hello-develop` | exposed, and **byte-identical** to `127.0.0.1:18080` |
| backend port dead | **torn down**, `No serve config` afterwards |
| refusals as a side-effect check | `tailscale serve status` still clean |

## Two bugs found running it

**`tailscale funnel … off` blocks forever** on a tailnet where funnel is not
enabled — measured at 25s and still going when killed. It sat in the cleanup
path, so the one routine whose entire job is undoing a bad exposure was the
routine that could hang, leaving the caller believing teardown had run.
Funnel is now only torn down when `serve status` shows it actually up.

**`curl -w '%{http_code}' … || echo 000` produced `000000`.** curl already
prints `000` when it cannot connect, so the fallback appended a second one.
The result never equalled `000`, so the "local service is dead" branch could
not fire and a dead backend was misreported as a status mismatch. The
teardown still happened; only the diagnosis was wrong — which is the kind of
error that sends someone debugging the wrong layer.

## Known gaps

- **Funnel is unavailable on this tailnet.** HTTPS certificates are not
  enabled, so public exposure is blocked at the prerequisite. `--funnel`
  reports this as exit 78 with the two admin-console steps rather than
  failing obscurely. Tailnet exposure works today and needs neither.
- **Serve config survives reboot.** It lives in tailscaled's state, not in
  this repo, so an exposure outlives the container it points at. `--status`
  is the only thing that will tell you; `recover.sh` does not manage it.
- **Not represented in the DAG.** An exposure is currently invisible to
  `statusdag`, so "what is reachable from outside" is not part of the
  platform verdict.


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`ingress.sh`](ingress.sh) | 需要對外開放某個服務時 | 經 Tailscale 把單一服務刻意地開出去 | **白名單制**：`vault` / `prometheus` / `alertmanager` / `loki` 一律拒絕、exit 1、什麼都不開。這關掉了 `Plan.md` 掛最久的那一項，而且不需要雲端供應商 |

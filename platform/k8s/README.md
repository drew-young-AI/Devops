---
type: platform-adapter
title: Kubernetes 叢集（k3d 開發 / k3s 生產）
description: The two clusters, their differing CPU architectures, and what a single node cannot test.
tags:
  - kubernetes
  - k3s
  - multi-arch
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/k8s — the two clusters, and why there are two

## What this directory is for

Kubernetes is where the pilot is deployed and where blue/green promotion is
verified. Since 2026-08-31 there are **two** clusters, on two machines, with
**different CPU architectures**. That last fact is not a detail; it is the
thing most likely to bite anyone reading this.

| | Mac (`k3d-devops-lab`) | Ubuntu box (`ubu`) |
|---|---|---|
| Role | **dev + SIT + UAT** | **prod** |
| Substrate | k3d — nodes are Docker containers inside a Linux VM | k3s — a systemd service on bare metal |
| Arch | `linux/arm64` (Apple Silicon) | `linux/amd64` (Intel i7-6700HQ) |
| Nodes | 1 server + 2 agents | 1 server, single node |
| Built by | `create_cluster.sh` | `bootstrap_k3s.sh` |
| Reached as | `kubectl --context k3d-devops-lab` | `kubectl --context ubu` |

## Start here

```bash
# the Mac practice cluster (dev/SIT/UAT)
platform/k8s/create_cluster.sh
platform/k8s/verify_cluster.sh

# the Ubuntu production cluster -- idempotent, safe to re-run
platform/k8s/bootstrap_k3s.sh
kubectl --context ubu get nodes
```

## The one thing that will bite you: architecture

Every image built on the Mac is **arm64 only**. Sending one to the Ubuntu
cluster fails, and it fails *late and quietly*:

```
docker save        -> succeeds
ctr images import  -> "saved", exit 0
ctr images ls      -> the image is listed, with a size
kubectl apply      -> accepted, Deployment created
kubelet            -> ErrImageNeverPull
containerd (in a log line nobody reads)
                   -> no match for platform in manifest: not found
```

This was proven by doing it, on 2026-08-31, not inferred. It is the same shape
as this platform's other recurring defect: **something registers as present but
cannot execute** (`promtool check rules` reporting SUCCESS on a rule that fails
every evaluation cycle; `tofu apply` reporting "10 resources created" while
creating nothing).

The guard is `platform/tests/test_image_arch.sh`. It asserts every own-built
image deployed to a cluster carries a build for that cluster's architecture,
and it reports **VACUOUS** rather than PASS for a cluster with no own-built
images — because "every image matches" is trivially true of an empty set, and a
green line meaning "nothing was examined" is the failure the guard exists for.

Do not fix an architecture mismatch by emulating. The build must happen on a
machine of the target architecture, or in CI on a runner of that architecture.

## Why the Ubuntu cluster is a single node

There is one physical machine. A second node would be a second k3s process on
the same kernel, sharing the same RAM and the same disk — the same failure
domain — so it would test nothing that one node does not, while costing a
control plane's worth of overhead. This would be the right choice at 64 GB too.

**What single-node therefore cannot test, and must never be claimed as tested:**

- node drain / cordon and the rescheduling that follows
- pod anti-affinity *across nodes*
- eviction on node failure

Blue/green, rolling updates and PodDisruptionBudget `minAvailable` **are**
testable here, because they are pod-level behaviours.

## Why Traefik is disabled on the Ubuntu cluster

The k3d cluster has no ingress controller either. Keeping the two substrates
identical except for the single variable under test — containers-in-a-VM versus
systemd on metal — is what makes a behavioural difference attributable to that
variable. Ingress is a later step with its own verification, not something that
arrives by default and is therefore never examined.

## Files

| File | What it does |
|---|---|
| `create_cluster.sh` | Rebuilds the k3d practice cluster on the Mac, with a registry wired in at creation time. Produces an empty, reachable cluster and stops. |
| `bootstrap_k3s.sh` | Installs k3s on the Ubuntu box over SSH, merges its kubeconfig into `~/.kube/config` as context `ubu`, and verifies reachability **from the Mac**. Idempotent. |
| `verify_cluster.sh` | Asserts the cluster is usable, not merely present. |
| `station2-twin/` | The pilot's manifests, blue/green promotion, and network policy. |
| `station2-twin/metrics-service.yaml` | A NodePort that makes the in-cluster copy reachable by the Prometheus outside it. It carries the same `color` selector as the traffic Service, so the metrics describe the copy that is actually serving. |

Neither bootstrap script deploys a workload, deliberately. Bundling substrate
and workload makes a failure ambiguous between the two.

## Known gaps (as of 2026-08-31)

1. **The Ubuntu cluster has no workload yet.** `test_image_arch.sh` reports it
   VACUOUS, which is the honest state.
2. **The pilot's K8s copy on the Mac runs on a static database password**
   (`PGPASSWORD=twin-bootstrap`), not Vault dynamic credentials — while the
   Compose copy does use Vault. The board's "migrated to K8s" claim is
   therefore true of the deployment and not of the credential path.
   *(The other half of this — the K8s copy being unscraped — was closed on
   2026-09-01: see `station2-twin/metrics-service.yaml` and
   `platform/tests/test_migration_observed.sh`.)*
3. **The Ubuntu box was unreachable at the time of writing** (SSH and 6443 both
   timed out while its NIC still answered ARP — consistent with suspend).
   A host that suspends is not yet a production host; that must be settled
   before the `prod` label means anything.

---

## 憑證：K8s 那份副本不再帶密碼（2026-09-01）

在此之前 `deployment-template.yaml` 帶著這一行：

```yaml
- { name: PGPASSWORD, value: "twin-bootstrap" }
```

而**同一個 pilot 的 Compose 副本自 2026-08-19 起就是動態 Vault 憑證**。
要被推上生產的，是憑證模型比較弱的那一份。

現在兩份都回報 `credentials.mode = vault`，各自持有獨立、會過期、可撤銷的 lease。

| 元件 | 角色 |
|---|---|
| `sync_vault_secret.sh` | 把 AppRole 寫進 Secret `station2-twin-vault`（`role_id` / `secret_id`） |
| `deploy.sh` | 每次部署自動呼叫上者——讓部署自己擁有它的前置條件 |
| `deployment-template.yaml` | `VAULT_ROLE_ID` / `VAULT_SECRET_ID` 走 `secretKeyRef`；**沒有 PGPASSWORD** |
| `networkpolicy.yaml` | 新增 `allow-host-vault`（/32＋單一 port 18200） |

### 三個刻意的決定

**一、不保留 static fallback。** Vault 連不上時 Pod readiness 失敗、被移出 Service
endpoints，藍綠因此無法把一份拿不到憑證的副本推上線。悄悄退回共用密碼的 Pod
和拿到 lease 的 Pod，從外面看完全一樣——失敗閉合才是重點。

**二、Secret 由 `deploy.sh` 同步，不是獨立的手動步驟。** Secret 缺席時 Pod 會以
`no AppRole configured` 失敗，那讀起來像應用程式的 bug，實際是缺前置條件。
讓部署擁有自己的前置條件，整類誤判就消失了。

**三、`allow-host-vault` 是獨立政策，不是在 postgres 那條上加一個 port。**
既有註解寫得很清楚：「『說不定之後會用到』就是預設拒絕悄悄變成預設允許的方式」。
一個目的地一條政策，`kubectl get netpol` 才讀得出一份「有正當理由的例外清單」。
把 18200 加進 postgres 那條，會產生一條**名字不再描述它准了什麼**的政策——
而沒人讀得懂的規則就沒人稽核。

### default-deny 在這裡證明了自己

移除靜態密碼之後 Pod 起不來，錯誤是 `Vault unreachable ... Connection refused`。
這正是預設拒絕遇到新相依時該有的樣子：**在邊界上被擋下，而且說得出名字**。
排查過程中順帶確認了：同樣發佈在 `127.0.0.1` 的 15432 通、18200 不通，
從一個全新的 docker 容器兩個都通——所以那不是 Docker Desktop 的路由問題，
是政策在生效。

### 還沒解決：secret zero

`secret_id` 現在在 k8s Secret 裡，那是 base64、不是加密。這是把
**共用、永不過期的資料庫密碼**，換成**範圍受限、可撤銷、可輪替、且只能用來換取
短期資料庫憑證的啟動憑證**——爆炸半徑變小，不是歸零。

終局是 Vault 的 `kubernetes` auth method（Pod 的 ServiceAccount token 就是身分，
不必配發任何 secret）。需要動到 pilot 應用與叢集的 token reviewer 綁定，
列為下一步，見 `docs/Backlog.md` §1。

### 守衛

| 層 | 檢查 |
|---|---|
| 1 | 任何 k8s manifest 都不得指派字面憑證值（突變驗證過：把密碼放回去 → 轉紅） |
| 3 | 兩份副本 `credentials.mode` 必須相同，且 K8s 那份必須是 `vault` |
| 3 | `test_bluegreen.sh` 8/8，含 green——證明兩個顏色都拿得到 Secret |

只比對 `mode` 不比對使用者名稱是刻意的：**使用者名稱本來就該不同**（各自的 lease），
mode 不該。對「必須相同的東西」斷言相同、同時讓「必須不同的東西」自由不同，
才是真的檢查，不是套套邏輯。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。
**只寫一句「見某腳本」不算描述**——那句話說不出何時跑、做什麼、保證什麼。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`station2-twin/deploy.sh`](station2-twin/deploy.sh) | 每次發版 | 部署**一個顏色**，**不切流量** | 分開才有意義：deploy 同時 promote 就沒有那個「新版本正在跑、連得到、但還沒服務流量」的檢查時刻 |
| [`station2-twin/promote.sh`](station2-twin/promote.sh) | 驗過新顏色之後 | 把流量切到某個顏色，**但只在它真的在服務時** | 切換本身只是一行 Service patch；**閘門才是全部的重點**——切之前檢查 Deployment 真的就緒、endpoint 真的有 pod |
| [`station2-twin/sync_vault_secret.sh`](station2-twin/sync_vault_secret.sh) | AppRole 更新時 | 把 AppRole 放進叢集 Secret | 讓 K8s 那份不再帶靜態資料庫密碼；role_id／secret_id 走 stdin manifest，**不進 argv**（`ps` 全機可讀） |
| [`station2-twin/verify_networkpolicy.sh`](station2-twin/verify_networkpolicy.sh) | 改 NetworkPolicy 後 | 證明網路政策**真的擋住東西** | `kubectl get netpol` 只證明 manifest 被接受。**CNI 若忽略 NetworkPolicy，每一份 manifest 都是裝飾品**，而看起來一模一樣 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`create_cluster.sh`](create_cluster.sh) | 需要重建練習叢集時 | 重建 k3d 叢集，補上舊叢集缺的兩樣（真 StorageClass、registry） | 舊叢集是**殭屍**：k3d CLI 沒裝、API server 沒在監聽，而它「看起來設定正確」。**刪掉重建而不是調整**才有辦法確定它是活的 |
| [`verify_cluster.sh`](verify_cluster.sh) | 每次建叢集後 | 證明叢集**能用**，不是證明它**被設定過** | PVC 真的綁定並寫入、映像真的推送並由節點拉取——**舊叢集設定完全正確而完全不能用**，兩者從設定檔上看一模一樣 |
| [`bootstrap_k3s.sh`](bootstrap_k3s.sh) | ubu 生產節點初次建置 | 從 Mac 把生產型 k3s 叢集拉起來在 Ubuntu 上 | **k3s 不是更多的 k3d**：k3d 把節點跑成 Docker 容器，而那個 Docker daemon 自己又在 VM 裡——三層間接，生產節點不該有 |

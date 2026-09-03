---
type: explanation
title: Kubernetes 從「未來 adapter」改為目標執行環境，發行版以 k3s 為先
description: "The plan said Kubernetes was not being adopted while a cluster had been carrying the pilot's blue/green for three weeks. This records the reversal as a decision rather than editing the old one away."
tags:
  - decision
  - kubernetes
  - k3s
  - platform
timestamp: 2026-09-02T00:00:00+08:00
decision:
  id: 10
  status: accepted
  date: 2026-09-02
  measured: true
  rerun: platform/k8s/verify_cluster.sh
  supersedes: []
---

# 0010 Kubernetes 從「未來 adapter」改為目標執行環境，發行版以 k3s 為先

## 決定

**Kubernetes 是這個平台的目標執行環境**，不是 `Plan.md` 原本寫的「未來 deployment adapter」。
發行版**以 k3s 為先**：

| 角色 | 機器 | 執行環境 | 說明 |
|---|---|---|---|
| dev / SIT / UAT | `mac.local` | **k3d**（k3s in Docker） | 開發便利層。k3d 跑的就是 k3s，不是另一套 API |
| prod | `ubu.local` | **k3s** | 目標形態 |

Docker Compose **不是被廢止**，它仍然是可觀測性堆疊、Vault 與 nginx 的執行方式。
改變的是**方向**：新的 Pilot 工作負載預設往 K8s 走，Compose 不再是預設終點。

## 為什麼這要寫成一筆決策，而不是把舊句子改掉

因為舊句子曾經是對的，而且是**有理由**地對。

`Plan.md` 第 130 行寫「Kubernetes：未來 adapter，目前不導入」，第 139 行寫
「不要先安裝 Kubernetes、Argo CD、Kubeflow 或 Airflow」，而根 README 曾宣告
`Plan.md` 是「權威現況，衝突時以它為準」。**照那條規則走，會得出「不導入」——
而 k3d 叢集當時已經承載 station2-twin 的藍綠三個星期了。**

就地把字改掉會讓這個 repo 失去「當時為什麼那樣判斷」，
而那正是三個月後唯一還有價值的部分。所以原句留著、就地標註反轉、理由寫在這裡。

## 原本四條「不導入」的理由，現在各自怎麼樣

`docs/Plan-detail.md` §0E 列了四條。逐條誠實對照：

| 原本的理由 | 現在 |
|---|---|
| 只有一個低負荷 Pilot，不足以證明 Kubernetes 的必要性 | **仍然成立**。但這條是關於「值不值得」，不是「能不能」。轉向的依據不是負載變大，是**目標環境確定**——要落地的醫院端環境是 K8s，那麼在 Compose 上把控制鏈練到完美，練到的東西有一半搬不過去 |
| Mac 上的 Kubernetes 通常需要額外 Linux VM，會稀釋 MLX 與 Docker 的資源預算 | **實測不成立**。k3d 把 k3s 跑在 Docker Desktop 既有的那個 VM 裡，沒有第二個 VM。`verify_cluster.sh` 8/8 在這台機器上通過 |
| 測試結果會混入 Kubernetes 配置問題，降低可診斷性 | **真的發生了，而且那是收穫**。Pilot 連不到 Vault 花了不少時間，最後是 `default-deny` 的 NetworkPolicy 只放行 15432。那不是雜訊，那正是 Compose 上永遠練不到的東西 |
| Argo CD 只解 Kubernetes GitOps，不會取代 CI、掃描、Prometheus、Grafana、Loki | **仍然成立，Argo CD 仍不導入**。這條理由與 Kubernetes 的取捨無關，不隨這筆決策放寬 |

**只有 Kubernetes 一項反轉。** Argo CD、Kubeflow、Airflow、ELK 都不跟著鬆綁——
「順手一起放寬」正是 §0E 那份清單存在的目的。ELK 另見
[0011](0011-loki-not-elk.md)。

## 為什麼是 k3s，不是完整的 kubeadm 叢集

| 面向 | k3s | 完整 Kubernetes |
|---|---|---|
| 安裝 | 單一 binary，內建 containerd、flannel、traefik、local-path、CoreDNS | 元件各自安裝與版本對齊 |
| 記憶體足跡 | control plane 數百 MB 量級 | 明顯較高 |
| ARM64 | 官方原生 | 需自行確認每個元件 |
| API 相容性 | **是通過 CNCF 認證的 Kubernetes**——manifest、Helm chart、kubectl 全部一樣 | — |

最後一列是重點：**選 k3s 不是選一個「簡化版」，是選一個發行版。**
學到的東西與寫下的 manifest 在任何 CNCF 認證環境上都成立。
這台是 MacBook（被動散熱、無 ECC、無備援電源），把 control plane 的資源
花在 etcd 高可用上，對這個平台的目的沒有任何回報。

## 什麼跟著這筆決策改變

1. **`docs/Plan-detail.md` §0F「Docker 到 Kubernetes 的可搬遷契約」從未來式變現在式。**
   契約本身不改——它寫得對——但它不再是「未來有 Kubernetes 時」的準備，是現在的驗收條件。
2. **§0E 的「導入 Kubernetes 的明確門檻」作廢。** 門檻已跨過，留著會讓讀者以為還沒開始。
3. **`Plan.md` 第 528 行「不做清單」中的 Kubernetes 一項移除**，Argo CD／Kubeflow／Airflow 留著。
4. **跨架構是連帶條件，不是選項**：mac 是 `linux/arm64`、ubu 是 `linux/amd64`，
   見 [0008](0008-two-machines-two-architectures.md)。往 k3s 走就必須同時處理映像架構。

## 哪些是量測、哪些是判斷

- **量測**：k3s 這個底座在這台機器上可用。`platform/k8s/verify_cluster.sh` 8/8 端到端
  （PVC 實際綁定並寫入、映像實際推送並由節點拉取、Deployment／Service selector／
  readinessProbe／Job／Secret／StatefulSet 逐項實測，k3s v1.35.5）。**重跑那支就會再得到一次。**
- **量測**：NetworkPolicy 的 default-deny 確實擋掉了 Pilot 到 Vault 的 egress，
  修法是一條窄的 `allow-host-vault`（`platform/k8s/station2-twin/networkpolicy.yaml`）。
- **判斷，無法量測**：「目標環境是 K8s，所以現在就該往那邊練」。這是策略，依據是落地端的環境形態，
  不是這台機器上的任何數字。**不要把它當量測結果引用。**

## 觸發重審

- 落地端確定不是 Kubernetes（那麼這筆決策的前提消失，`Plan.md` 原本的判斷會重新變成對的）
- ubu 上的 k3s 實際跑起來後，若 amd64／arm64 的映像成本高過 K8s 帶來的可搬遷性

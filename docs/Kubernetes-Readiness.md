---
type: explanation
title: Kubernetes 轉移評估
description: "What the current Compose-based platform carries over to Kubernetes unchanged, what gets replaced, and which requirements it has never touched."
tags:
  - kubernetes
  - architecture
  - migration
  - assessment
timestamp: 2026-08-18T11:20:00+08:00
---

# Kubernetes 轉移評估

即將接手的範疇：**多節點叢集部署、Pod 調度優化、資源管理、Namespace 控制**，
結合 **Kubeflow、Helm、Ingress、Prometheus/Grafana**。

這份文件回答一個問題：現有平台有多少帶得走。

---

## 1. 已經是 K8s 形狀的（意外的最大收穫）

**station2-twin 的健康檢查設計，字面上就是 K8s probe 語意。**

```
/health/live   →  livenessProbe    失敗 = kubelet 重啟這個容器
/health/ready  →  readinessProbe   失敗 = 從 Service endpoints 移除

```

這不是巧合帶來的小便利，而是最容易做錯、也最貴的一件事。K8s 上最常見的
有狀態服務事故就是**把 readinessProbe 的條件寫進 livenessProbe**：資料庫
一抖，kubelet 同時重啟所有 replica，可復原的依賴故障變成全面停機。

現有實作已經明確拒絕這件事（Docker healthcheck 只打 `/health/live`，且有
測試斷言它不含 `health/ready`），而且 readiness 會分辨四種原因：

| 狀態 | K8s 上的意義 |
|---|---|
| `ready` | Pod 進入 Service endpoints |
| `db_unreachable` | 移出 endpoints，**不重啟** |
| `schema_missing` | migration Job 還沒跑完 |
| `schema_mismatch` | **這版程式碼配錯 schema——rollout 會自己卡住** |

最後一項在 K8s 上比在 Compose 上更有價值：Deployment rolling update 會等
新 Pod 就緒才繼續，所以 schema 不符會讓 rollout **自動停在第一個 Pod**，
舊 ReplicaSet 完全不受影響。這是免費得到的安全網。

**其他直接轉移的機制**（實作換、規則不換）：

| 現有 | K8s 對應 |
|---|---|
| migration gate（checksum、expand/contract、單一 transaction） | Helm hook / Job，規則完全相同 |
| 備份覆蓋率檢查（每個 volume 必須被分類） | 同樣邏輯套在 PVC 上 |
| ingress ceiling（依「靠什麼驗證」決定暴露程度） | NetworkPolicy + Ingress + OPA/Kyverno |
| SBOM + Cosign 簽章 | 升級成 admission 階段驗章（policy-controller） |
| evidence chain、真人 promote gate | 不變 |
| deterministic 雙向驗證的文化 | 不變，且更重要 |

---

## 2. 會被整個換掉的

| 現有 | 換成 | 備註 |
|---|---|---|
| `platform/compose/deploy.sh` blue/green（629 行） | Deployment rolling update / Argo Rollouts | **不要重構它**，是即將被取代的程式碼 |
| launchd scheduler（10 個 agent） | CronJob | `StartCalendarInterval` 那組教訓在 CronJob 上不存在 |
| NGINX vhost 產生 | Ingress resource | |
| `docker volume` tar 備份 | Velero / CSI snapshot | pg_dump 的判斷仍然對 |
| Tailscale serve/funnel | Ingress controller（或 Tailscale K8s Operator） | 政策帶走，實作不帶 |

---

## 3. 完全沒碰過的（職缺要求的核心）

這是誠實的缺口清單。以下每一項，現有平台**零經驗**。

### 多節點調度

單機 Compose 沒有「節點」這個概念。需要建立的實務：
`nodeAffinity` / `podAntiAffinity`（讓 replica 不要全擠在同一節點）、
`taints/tolerations`（GPU 節點隔離）、`topologySpreadConstraints`、
`PodDisruptionBudget`（drain 節點時不要一次砍光）。

### 資源管理

**最容易踩、也最難察覺的一項。** requests 與 limits 的差別決定 QoS class
（Guaranteed / Burstable / BestEffort），而它決定 OOM 時誰先被殺。

特別注意 **CPU limit 造成的 throttling**：設了 CPU limit 的 Pod 在達到上限
時不會被殺，而是被節流——表現出來是「應用程式變慢」，不是「資源不足」。
查錯的人會去看應用程式，而問題在 cgroup。這是典型的「症狀指向錯誤的層」，
和本平台已經記錄過的多起事故同一種形狀。

### Namespace 控制

RBAC（per-namespace Role/RoleBinding）、`ResourceQuota`、`LimitRange`、
**NetworkPolicy 預設拒絕**。

⚠️ **NetworkPolicy 有一個安靜失敗的陷阱**：它由 CNI 執行，而 kind 預設的
kindnet **完全不執行 NetworkPolicy**。套用 policy 會成功、`kubectl get` 看
得到、`describe` 一切正常——**但沒有任何流量被擋**。必須換 Calico 或
Cilium，並且用「從不該通的 Pod 實際 curl 過去」來驗證，而不是看 policy
存在與否。這正是本平台反覆遇到的「檢查通過但機制沒作用」。

### Kubeflow

GPU 排程、Notebook controller、Pipelines、Training Operator。
⚠️ **完整 Kubeflow 在單機上很重**（多個 controller + Istio + Dex，實務上
需要 16GB+ 給叢集本身）。建議先只上 **Kubeflow Pipelines standalone**，
它輕得多且是最常實際用到的部分。

### Helm

chart 版本管理、values 分層、**secret 不能進 values.yaml**（要接 External
Secrets Operator 或 SOPS）、chart provenance 簽章。

---

## 4. 在一台 M5 上怎麼做「多節點」

可行，而且是真的多節點——不是模擬。

| 工具 | 適用 |
|---|---|
| **kind** | 多節點（每個節點一個容器）。CI 友善，最接近上游 K8s |
| **k3d** | k3s in Docker，更輕，開得更快 |
| **Colima** | 已有 Docker 的話可直接開 k3s |

建議 **kind + Calico**（不是預設 kindnet，理由見上）：三節點 control-plane
+ 2 worker 可以真實練到 affinity、taint、drain、quota、NetworkPolicy、
rolling update、PDB。

**它證明不了的**（不要在履歷或報告上宣稱）：真實節點硬體故障、跨機網路
分區、儲存 failover、跨實體機的 kernel 級隔離。這些需要真的多台機器。

---

## 5. 建議的落地順序

1. **kind 三節點 + Calico**，把 station2-twin 原樣搬上去。它已經是 K8s 形狀，
   應該只需要 Deployment + Service + Ingress + PVC，是最低風險的第一步。
2. **migration 改成 Helm pre-upgrade hook Job**，驗證 schema_mismatch 會讓
   rollout 自動卡住（這是現有機制在 K8s 上變強的證明）。
3. **kube-prometheus-stack**（Helm）取代現有 Prometheus/Grafana。
   ⚠️ 告警規則的 `up{}` 語意會變——blue/green 的
   `sum(up{...}) == 0` 那個修正在 K8s 上不適用，改由 Deployment 管理副本。
4. **ResourceQuota + LimitRange + NetworkPolicy 預設拒絕**，逐一用實際流量驗證。
5. **Kubeflow Pipelines standalone**，再視需要擴。

**先不要做**：把 Compose 的 blue/green 或 launchd scheduler 移植過去。它們
在 K8s 上有原生對應，移植等於把兩套錯的東西合成一套。

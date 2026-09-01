---
type: explanation
title: 兩台機器兩種指令集：Mac 是 dev/SIT/UAT，Ubuntu 是 prod，映像檔在目標架構上建置
description: "The platform now spans arm64 and amd64, so images must be built for the target architecture and never emulated."
tags:
  - decision
  - kubernetes
  - multi-arch
timestamp: 2026-08-31T00:00:00+08:00
decision:
  id: 8
  status: accepted
  date: 2026-08-31
  measured: true
  rerun: platform/tests/test_image_arch.sh
---

# 0008 兩台機器兩種指令集

## 決定

| 環境 | 機器 | 叢集 | 架構 |
|---|---|---|---|
| dev / SIT / UAT | MacBook Pro M5 | k3d `devops-lab` | `linux/arm64` |
| prod | Ubuntu 26.04 LTS（i7-6700HQ） | k3s `ubu`，單節點 | `linux/amd64` |

三條規則：

1. **映像檔在目標架構的機器上原生建置**，或在該架構的 CI runner 上建置。
   **不使用 QEMU 交叉編譯。**
2. **部署 pin digest，不 pin tag。** tag 可以指向錯的架構；digest 在部署當下就爆。
3. **每個被送到叢集的自建映像檔，必須帶有該叢集架構的 manifest**，由
   `platform/tests/test_image_arch.sh` 執法。

## 為什麼

### 這個失敗是靜默的，而且靜默到最後一刻

2026-08-31 實測：把 Mac 建的 arm64 映像檔搬到 amd64 的 Ubuntu 叢集上跑。

```
docker save        -> 成功
ctr images import  -> "saved"，exit 0
ctr images ls      -> 列得出來，顯示 856 B
kubectl apply      -> 接受，Deployment 建立
kubelet            -> ErrImageNeverPull
containerd         -> no match for platform in manifest: not found   ← 唯一的真話
```

每一個人會看的步驟都回報成功。這是這個平台最老的缺陷換一件衣服：
**登記成功不等於能執行**。同樣形狀的前例：`promtool check rules` 對一條每次評估都
失敗的規則回報 SUCCESS（[ADR-0007](0007-verify-by-evaluation.md)）；`tofu apply`
回報「10 resources created」而實際建立零個基礎設施。

### 為什麼不用 buildx + QEMU

CLAUDE.md 禁止 x86 模擬。除了規則之外，模擬建置慢、且產出的二進位沒有在目標架構上
被執行過——它把「能不能跑」這個問題推遲到部署當下，正是上面那張表要避免的事。

### 為什麼 prod 是單節點

只有一台實體機。第二個節點會是同一顆 kernel 上的第二個 k3s process，共用同一份記憶體
與磁碟——**同一個故障域**。它測不到任何跨故障域的行為，只多付一份 control plane 的成本。
即使有 64 GB 記憶體，答案仍然是單節點。

**因此不可宣稱測過**：node drain／cordon 後的重新排程、跨節點 pod anti-affinity、
節點失效驅逐。**仍然測得到**：blue/green、rolling update、PDB `minAvailable`——
這些是 pod 層級行為。

## 代價與已知缺口

1. **兩條映像檔血緣**（arm64 給 dev、amd64 給 prod）。同一份 Dockerfile，不同建置主機，
   各自記錄 digest。這是誠實的 dev/prod 區隔，但也是兩個要維護的產物。
2. **效能基準不可移植。** DuckDB 的 331×–425×（[ADR-0001](0001-analytical-mirror-duckdb.md)）
   是 M5 實測。Ubuntu 是 2016 年的 i7-6700HQ。**任何從 Mac 數字推出的門檻，禁止套用到 prod。**
3. **數值可重現性未驗證。** BLAS 在 arm64 與 amd64 可能有末位差異。MLOps 的發布閘門
   靠數字比較決定贏輸；若模型在 Mac 訓練、在 Ubuntu 評分，勝負可能因為架構而翻面。
   任何 determinism 宣稱必須記錄測量時的架構。
4. **prod 尚無工作負載。** `test_image_arch.sh` 對 `ubu` 回報 VACUOUS，這是誠實狀態。
5. **Ubuntu 那台會休眠。** 撰寫當下 SSH 與 6443 皆逾時，而網卡仍回應 ARP。
   **會休眠的機器還不是生產主機**，這件事必須先解決，`prod` 這個標籤才有意義。

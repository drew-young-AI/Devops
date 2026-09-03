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

## 執法狀態（2026-09-03 更新）

第 1、3 條原本就有執法；**第 2 條在 2026-09-03 之前只是文字**。

| 規則 | 執法者 | 狀態 |
|---|---|---|
| 1. 原生建置，不用 QEMU | `.github/workflows/pilot-image.yml` — `ubuntu-latest`(amd64) 與 `ubuntu-24.04-arm`(arm64) 兩個原生 runner，各自斷言 `dpkg --print-architecture` 與映像檔自報架構 | ✅ **2026-09-03 首次執行成功**（run 33770464457） |
| 2. pin digest 不 pin tag | `platform/k8s/station2-twin/deploy.sh` 對非本機 lab 的 context **拒絕 tag** | ✅ 執法中，含三個合成控制 |
| 3. 映像檔要有目標架構的 manifest | `platform/tests/test_image_arch.sh` | ✅ 執法中；ubu context 目前回報 `VACUOUS` |

第 2 條為什麼只對非 lab 的 context 執法：本機只有一種架構、registry 在同一台主機上，
而藍綠流程每次部署都會改寫那個 tag。digest 在那裡買不到任何東西，
卻會讓「同一個顏色換一版重新部署」變成不可能。**兩座叢集真正相遇的地方才是風險所在。**

## 正面終於被量到了（2026-09-03）

2026-08-31 量到的是**反面**：Mac 建的 arm64 映像搬到 amd64 叢集，
每個人會看的步驟都回報成功，只有 containerd 說了實話
（`no match for platform in manifest`）。

2026-09-03 量到正面，全鏈：

```
CI 原生建置        runner reports: amd64   image reports: linux/amd64
                   runner reports: arm64   image reports: linux/arm64
推 ghcr（by digest） amd64 → sha256:6c191ed8...
                   arm64 → sha256:543fdf20...
組裝 manifest list  ok linux/amd64   ok linux/arm64
                   sha256:a07378130521b1e44abd13d8ae58c55f8b9f84724f2498886bb884ab86e01602
ubu 節點拉取並執行   machine: x86_64   python: 3.12.14
                   imageID = ...@sha256:a073781305...（digest，不是 tag）
```

用一次性 Job 證明，不是 Deployment：pilot 在 ubu 上還沒有 Vault 與資料庫，
一個永遠 NotReady 的 Deployment 會變成這個 repo 整場在移除的那種永久紅。
Job 完成後即刪除，ubu 的叢集回到空的。

**ghcr 套件是公開可讀的**——未帶任何認證的 `imagetools inspect` 就解析得到，
所以原本標記的「prod 叢集需要 imagePullSecret」不成立。這是量出來的，不是假設。

`test_image_arch.sh` 對 ubu 仍然回報 `VACUOUS`，而那是對的：
它問的是「部署在那裡的自建映像」，而 Job 不是 Deployment。
**空集合就該說是空集合。**

## 這條 ADR 訂了三天沒有人檢查另一邊（2026-09-03 記）

ADR 從 2026-08-31 就說這個平台橫跨兩種指令集與兩個作業系統。
**ubu 一開機、第一次真的在 Linux 上跑 tier 1，就找到三個已經推上去的缺陷：**

| 缺陷 | 為什麼 Mac 上看不到 |
|---|---|
| `host_disk_metrics.sh` 寫死 `/System/Volumes/Data` | macOS 專屬路徑；Linux 上 `df` 直接失敗，CI 因此連紅四次 |
| `lib.sh` 與兩個套件用 `sed -i ''` | BSD 專屬寫法。GNU sed 把 `''` 當腳本、真正的腳本當**檔名**，於是**每個突變靜默地什麼都沒改**，輸出卻寫「mutant survived」——那是關於規則的宣稱，實際上是關於測試的宣稱 |
| `source_frequency_check.py` 直接呼叫 `docker` | Linux 上沒有 docker，未捕捉的 `FileNotFoundError` 讓可攜性事實變成假缺陷 |

第四個是這次的檢查自己第一次跑就找到的：`test_loki_coverage.sh` 的合成控制項在
Loki 活著時複製**真實**指標、不活著時複製一個空檔案（shell 重導向即使指令失敗也會建檔，
所以 `||` fallback 永遠不執行）。**Mac 上全綠、其他地方六個紅。
一個輸入取決於環境的控制項不是控制項。**

所以新增 `platform/tests/run_on_ubu.sh`：推之前先在 Linux 節點上跑一次 CI 那一層。
**它不取代 CI**——只是把「四個 commit 之後被 CI 告知」變成「推之前就知道」。

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

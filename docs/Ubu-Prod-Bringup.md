---
type: runbook
title: Ubuntu 生產節點接手手冊
description: "How to bring the amd64 production cluster up, what is already done, and the three things that must be settled before it earns the name prod."
tags:
  - kubernetes
  - production
  - runbook
timestamp: 2026-08-31T00:00:00+08:00
---

# Ubuntu 生產節點接手手冊

**狀態（2026-09-03 更新）：機器已開機，叢集 Ready 且從 Mac 可達。**
**平台現在知道它存在（板面新增 `prod 叢集 (ubu/amd64)` 節點）。**
**建置鏈 2026-09-03 首次執行成功；amd64 映像已實測能在 ubu 上執行（`machine: x86_64`）。**
**叢集刻意維持空的：pilot 還缺 Vault 與資料庫，一個永遠 NotReady 的部署是永久紅。**

## 一、已經完成的（不需重做）

| 項目 | 狀態 | 證據 |
|---|---|---|
| SSH 金鑰認證 | ✅ | `~/.ssh/id_ed25519_ubu`，別名 `ssh ubu`（`~/.ssh/config`） |
| k3s v1.36.4+k3s1 | ✅ 單節點 server | `systemctl is-active k3s` → active |
| kubeconfig 合併 | ✅ context `ubu` | `kubectl --context ubu get nodes` 曾回 Ready |
| 從 Mac 跨主機可達 | ✅（當時） | `bootstrap_k3s.sh` 最後一步就是這個驗證 |
| 架構事實已量測 | ✅ | Ubuntu 26.04 / **amd64** / 8 邏輯核心 / 7.1 GiB / 磁碟剩 84 G |
| 架構不相容已實證 | ✅ | arm64 映像檔在 amd64 上 `no match for platform in manifest` |

重跑指令（冪等，機器開機後直接執行）：

```bash
platform/k8s/bootstrap_k3s.sh
kubectl --context ubu get nodes
```

## 二、機器連不上時的判讀順序

實際遇到的情況：**ARP 表裡還看得到網卡，但 22 與 6443 都逾時**。

```bash
arp -a | grep 192.168.1.144      # 有記錄 → 網卡有電，機器休眠
nc -z -G 5 ubu.local 22          # 逾時 → 系統沒在跑
ping -c 2 192.168.1.1            # 路由器通 → 不是本機網路問題
```

**mDNS 也可能單獨失效**：`ubu.local` 解析不到但 IP 直連正常。這個平台已經因為
`70.local` 停在一個不解析的名字上吃過一次虧，所以：**任何自動化不要寫死 IP，
但診斷時一定要用 IP 交叉驗證。**

註：IP 是 `192.168.1.144`，不是最初以為的 `.143`。

## 二之二、2026-09-03 這一輪做了什麼

| 項目 | 結果 |
|---|---|
| 連通性 | SSH 22 與 k3s 6443 皆通，mDNS `ubu.local` 解析正常 |
| 叢集 | `kubectl --context ubu get nodes` → Ready，v1.36.4+k3s1，amd64，8 核 / 7.1GiB / 83G 可用 |
| **平台知道 ubu 存在了** | `dag.py` 新增 `prodk8s` 節點。**空叢集回報 WARN 不是 OK**——「叢集就緒但沒有任何工作負載」，因為一個什麼都沒跑的叢集只證明 API server 會回應 |
| 架構守衛第一次對真實第二座叢集評估 | `test_image_arch.sh` → `VACUOUS context ubu (linux/amd64)`，誠實地說「沒有自建映像部署在這裡，所以什麼都沒驗證到」 |
| **amd64 建置鏈** | `.github/workflows/pilot-image.yml`：`ubuntu-latest`(amd64) 與 `ubuntu-24.04-arm`(arm64) 兩個**原生** runner，無 QEMU，合併成 manifest list 推 ghcr.io |
| **ADR-0008 第二條規則開始執法** | `deploy.sh` 對非本機 lab 的 context **拒絕 tag、只收 digest**。原本這條規則只寫在文件裡 |
| 磁碟匯出器可攜化 | `host_disk_metrics.sh` 原本寫死 macOS 的 `/System/Volumes/Data`，**CI 在 Linux 上因此紅了四次**。已改成依 OS 選擇掛載點，並在 ubu 上實測通過 |
| `sed -i ''` 可攜性 | BSD 專屬寫法在 GNU sed 上會把腳本當檔名，**每個突變靜默地什麼都沒改**，輸出卻寫「mutant survived」。新增 `lib.sh::sed_i` 與靜態規則＋合成控制 |

### 手冊原本寫錯的兩件事（已更正）

第四節列的兩個「必須一起修的缺口」，查證後**都已經修好了**：

- K8s 那份**已經**用 Vault AppRole（`VAULT_ROLE_ID` / `VAULT_SECRET_ID` 在 deployment env 裡），不是靜態密碼。
- K8s 那份**已經**有 scrape job（`prometheus.yml` 的 `station2-twin-k8s`，目標 18091，現在是 up）。

這份手冊寫於 2026-08-31，那兩句在寫下時是對的。**沒有標日期的現況描述會退化成信念**——
與 `service-health.yml` 那段「沒有 node-exporter」是同一個形狀。

## 三、在它成為 prod 之前必須解決的三件事

1. **會休眠的機器不是生產主機。**
   需要停用 suspend／hibernate：`systemctl mask sleep.target suspend.target
   hibernate.target hybrid-sleep.target`，筆電還要處理闔蓋行為
   （`/etc/systemd/logind.conf` 的 `HandleLidSwitch=ignore`）。
   **未執行——需要你操作，ubu 上沒有免密碼 sudo。** 指令：

   ```bash
   ssh ubu
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
   sudo systemctl restart systemd-logind
   ```

2. **IP 需要固定——但理由在 2026-09-04 更正過。**
   原本寫「DHCP 換約會讓 kubeconfig 的 SAN 失效」。**前半是錯的**：
   kubeconfig 指向 `https://ubu.local:6443`（名字，不是 IP），
   而今天連得上本身就證明 k3s 的憑證 SAN 已涵蓋 `ubu.local`。
   **DHCP 換約不會弄壞 kubectl。**

   固定 IP 仍然要做，理由是另外兩個：本手冊第二節的診斷指令寫死
   `192.168.1.144`（那正是機器出事時要用的東西），以及
   **mDNS 可以單獨失效**（`70.local` 那次教訓）——沒有固定 IP 就沒有第二條路。
   分析見 [`docs/Backlog.md`](Backlog.md) §26。**未執行，需要使用者操作路由器。**

3. ~~**amd64 建置鏈還不存在。**~~ **已寫好，尚未跑過（2026-09-03）。** 目前沒有任何映像檔可以在這台上跑。
   兩條路（見 [ADR-0008](decisions/0008-two-machines-two-architectures.md)）：
   - GitHub Actions 用 `ubuntu-latest`（amd64）與 `ubuntu-24.04-arm`（arm64）
     兩個原生 runner 建置，合併成 manifest list 推 ghcr.io。**不需要 QEMU。**
   - 或在 ubu 上原生建置，走本機 registry。
   採用前者。`.github/workflows/pilot-image.yml` 已建立：
   - `ubuntu-latest`（amd64）與 `ubuntu-24.04-arm`（arm64）兩個原生 runner，**不用 QEMU**
   - 每個 runner 都**斷言自己的架構**（`dpkg --print-architecture`）與**映像檔自報的架構**
     （`docker image inspect`），因為 runner 標籤是一個請求不是一個保證
   - 各自 smoke test（無資料庫時 `/health/live` 必須回 200——已在 Mac 上先驗證過這個假設）
   - `imagetools create` 只做**組裝**不做編譯，並斷言索引裡兩個架構都在
   - 把要 pin 的 digest 印進 job summary

   **2026-09-03 首次執行成功**（run 33770464457）。要 pin 的 digest：

   ```
   ghcr.io/drew-young-ai/station2-twin@sha256:a07378130521b1e44abd13d8ae58c55f8b9f84724f2498886bb884ab86e01602
   ```

   **套件是公開可讀的**——未帶認證的 `imagetools inspect` 就解析得到，
   所以不需要 imagePullSecret。這是量出來的，原本那句「預設私有」是假設。

   已在 ubu 上以一次性 Job 實測：節點拉的是 digest、跑起來 `machine: x86_64`。

## 四、接下來的順序

1. 機器開機 → `platform/k8s/bootstrap_k3s.sh` 確認仍 Ready
2. 停用休眠 + 固定 IP（上面第 1、2 項）
3. amd64 建置鏈（第 3 項）
4. pilot 上 prod，同時修掉兩個既有缺口：
   - K8s 那份目前用靜態密碼 `PGPASSWORD=twin-bootstrap`，不是 Vault 動態憑證
   - K8s 那份沒有任何 Prometheus scrape job（Compose 那份才有）
   **兩個都要修**，只修一個就是重演 station1 退役時那個「監控盯著錯的副本」的缺陷
5. IaC 換掉 10 個 `null_resource`，驗收條件是**漂移偵測**：
   `kubectl scale` 製造漂移後 `tofu plan` 必須看得到

## 五、Vault 的決定

**兩台都放**（使用者決定）。因此 Mac 的 Compose pilot 繼續用 Mac 上的 Vault，
Ubuntu 的 prod pilot 用 Ubuntu 上的 Vault。代價是兩份 AppRole 與兩份輪替設定，
好處是任一台關機不會讓另一台失去憑證來源。**尚未在 ubu 上安裝 Vault。**

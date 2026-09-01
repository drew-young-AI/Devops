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

**狀態：叢集已建好並驗證過，但機器目前連不上（休眠）。工作暫停於此。**

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

## 三、在它成為 prod 之前必須解決的三件事

1. **會休眠的機器不是生產主機。**
   需要停用 suspend／hibernate：`systemctl mask sleep.target suspend.target
   hibernate.target hybrid-sleep.target`，筆電還要處理闔蓋行為
   （`/etc/systemd/logind.conf` 的 `HandleLidSwitch=ignore`）。
   **未執行。**

2. **IP 需要固定。** DHCP 換約會讓 kubeconfig 的 SAN 與所有診斷失效。
   路由器保留位址，或在 ubu 上設固定位址。**未執行，需要使用者操作路由器。**

3. **amd64 建置鏈還不存在。** 目前沒有任何映像檔可以在這台上跑。
   兩條路（見 [ADR-0008](decisions/0008-two-machines-two-architectures.md)）：
   - GitHub Actions 用 `ubuntu-latest`（amd64）與 `ubuntu-24.04-arm`（arm64）
     兩個原生 runner 建置，合併成 manifest list 推 ghcr.io。**不需要 QEMU。**
   - 或在 ubu 上原生建置，走本機 registry。
   使用者傾向前者（雲端 CI 編譯）。**待 GitLab/GitHub 方案定案。**

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

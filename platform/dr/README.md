---
type: how-to
title: 異地還原：把別人家的那份副本，變回這裡跑得起來的服務
description: "The off-site restore drill that is also the production bring-up: pull from the encrypted remote, ship to the other machine, load, and check the result against what the manifest says it holds."
tags:
  - backup
  - disaster-recovery
  - kubernetes
timestamp: 2026-09-20T09:00:00+08:00
---

# 異地還原

`verify`：`platform/dr/offsite_restore.sh --preflight-only`

## 這支跟 `restore_drill.sh` 差在哪

`platform/backup/restore_drill.sh` 證明的是「封存檔可以變回一個資料庫」——
在**做出那份封存的同一台機器**上、用**本機那份副本**、在拋棄式容器裡。

它因此證不到三件事，而災難發生時要的正是這三件：

1. **異地那份取得回來嗎。** crypt 遠端從來沒有被完整讀回過一次。
2. **換一台機器、換一種架構還原得起來嗎**（arm64 → amd64，ADR-0008）。
3. **還原完的資料庫，答得出問題嗎。** 載入沒報錯而查不到東西，那不是復原。

所以這支跑真正的路徑：從異地拉回 → 驗 sha256 → 搬到 ubu → 載入 prod 叢集 →
比對清單說的內容 → 用平台自己的查詢驗證。

## 六個階段，失敗停在哪就從哪續跑

| 階段 | 問什麼 | 失敗退出碼 |
|---|---|---|
| `preflight` | 目標主機在不在、是什麼平台、有沒有容量、上面現在有什麼 | 10 |
| `fetch` | 從**異地**（不是本機副本）取回，sha256 對不對 | 11 |
| `ship` | 搬到目標主機之後，sha256 還對不對 | 12 |
| `restore` | 建立（或沿用）生產資料庫，單一交易載入 | 13 |
| `confirm` | 還原出來的 schema 版本與列數，和清單說的一致嗎 | 14 |
| `verify` | 還原出來的資料庫答得出平台自己的查詢嗎 | 15 |

```bash
platform/dr/offsite_restore.sh                 # 全部
platform/dr/offsite_restore.sh --preflight-only
platform/dr/offsite_restore.sh --from restore  # 從某一階段續跑
platform/dr/offsite_restore.sh --force         # 允許覆蓋已有資料的 prod-db
```

任一階段失敗會發一則**指名階段**的通知（`emit_event.sh offsite-restore failed`）。
只說「還原失敗」是能說的最沒用的真話：遠端不回應、資料回來得不完整、目標主機沒空間，
這三件事要做的下一步完全不同。

## 三個刻意的設計

**清單自帶內容。** `backup.sh` 在 pg_dump 成功時，把 schema 版本與兩張事實表的列數
寫進 `manifest.json` 的 `contents`。還原端因此不需要回去問來源機器——
而災難演練的前提正是那台機器不在。沒有 `contents` 的舊備份集會被明講成
**UNVERIFIED**，不會假裝比對過。

**拒絕資料目錄的 tar。** `fetch` 階段只接受 `.dump`（pg_dump 格式）。
PostgreSQL 的資料目錄不保證能跨平台還原，而這支腳本的存在意義就是跨平台。
在這裡拒絕，理由講得清楚；讓它走到載入才失敗，錯誤訊息會變成 page header 的亂碼。

**不會毀掉你要復原的目標。** `prod-db` 已經有資料時，沒有 `--force` 就拒絕。
一個失敗形態是「把你正要救回來的東西弄壞」的復原工具，不是復原工具。

## 能力表（何時跑／做什麼／保證什麼）

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`offsite_restore.sh`](offsite_restore.sh) | 想知道「異地那份備份到底能不能用」的時候；prod 叢集第一次要資料時（兩者是同一個動作） | 從加密遠端取回 → 驗 sha256 → 搬到另一台機器 → 載入 prod 資料庫 → 比對清單內容 → 用平台自己的查詢驗證 | **六個階段各有自己的退出碼與通知**，失敗停在哪就從哪 `--from` 續跑；拒絕資料目錄的 tar（不能跨架構）；prod 有資料時沒有 `--force` 就拒絕，而且問不出列數時也拒絕（失敗要往安全側倒）；清單沒有內容欄位時**明說 UNVERIFIED**，不會用「通過驗證」的字眼帶過 |

## 憑證

bootstrap 密碼在**叢集內**產生，不經過這台機器的檔案，也不印出來。
它只是 bootstrap：動態憑證要等 ubu 上的 Vault 建好，而那把 unseal key
只有平台擁有者能持有（B 類，見 `../../docs/Backlog.md`）。

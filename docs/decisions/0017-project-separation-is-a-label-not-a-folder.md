---
type: explanation
title: 多專案的區隔用標籤，不用資料夾
description: "A second project must not double the dashboards, the alert rules or the exporters. Discipline decides the folder; project decides the label. Measured against the alternative on the numbers this repo already has."
tags:
  - decision
  - platform
  - observability
  - multi-project
timestamp: 2026-09-09T00:00:00+08:00
decision:
  id: 17
  status: accepted
  date: 2026-09-09
  measured: true
  rerun: platform/tests/dashboard_audit.py
  supersedes: []
---

# 0017 多專案的區隔用標籤，不用資料夾

## 決定

**Grafana 的資料夾依「學科」分，不依「專案」分；專案是一個 `project` 標籤與一個
下拉變數。** 同一條規則往下貫穿：

| 維度 | 表現形式 | 為什麼 |
|---|---|---|
| 學科（infra／devops／dataops／mlops） | **資料夾** | 學科的數量是固定的四個，而且它決定「誰該看這張圖」 |
| 專案（station2-twin、下一個…） | **`project` 標籤 ＋ `$project` 變數** | 專案的數量會長，而且每個專案在四個學科裡都有內容 |
| 預測目標（pct_ili、pct_flu…） | **`target` 標籤 ＋ `$target` 變數** | 一個專案可以有多個題目；2026-09-09 起這個試點就有兩個 |

## 為什麼不是資料夾

三個選項，用這個 repo 已經有的數字比：

| 方案 | 兩個專案時的看板數 | 五個專案時 | 加一個學科要改幾處 |
|---|---|---|---|
| 每個專案一組資料夾 | 4 × 2 = **8** | 4 × 5 = **20** | 5 處（每個專案各一） |
| **學科資料夾 ＋ 專案標籤** | **4** | **4** | 1 處 |
| 每個專案一個 Grafana org | 4 × 2，且看板被切斷 | 同上 | 5 處，且長官要登入兩次 |

第一個方案的問題不是數量本身，是**複製**：八張看板裡有四對是同一份 JSON 改了一個
標籤選擇器。這個 repo 已經付過這筆帳四次——settle 規則兩份、發布器的估計器一份、
schema 版本四份、閾值在 `install.sh` 與它的測試各一份。**每一次都是「做的當天是對的」
的第二份拷貝。**

第三個方案還多砍掉一件事：跨專案的比較。「哪一個專案的資料新鮮度最差」在 org 之間
問不出來，而那正是平台層存在的理由。

## 什麼帶 `project` 標籤，什麼不帶

判準是**這個數字換一個專案會不會有第二個值**：

- **帶**：`mlops_*`（模型、評分、重放）。一個專案一組模型。
- **帶**：`dataops_*`（來源新鮮度、攝入、鏡像、年比）。**2026-09-09 補上**，
  313 條序列，唯一的例外是這個檔案自己的產生時間戳（它是關於匯出器那一次執行，
  不是關於任何專案——`mlops_*` 也做同樣的例外）。原本登記為 T27 想等第二個
  專案，但那個順序是反的：**要等到第二個專案才加標籤，等於要在最忙的那一天
  同時改匯出器、告警與看板。**
- **不帶**：`devops_*`（288 條）。**這不是還沒做，是判斷。** 它量的多半是平台
  自己——健康快照覆蓋率、DAST 路由涵蓋、板面產生時間、Loki 攝入。那些沒有
  所屬專案。`devops_*` 裡真的屬於某個 pilot 的（部署副本、schema 版本）另有
  `service` 標籤在做這件事。
- **不帶**：`node_*`、`host_*`、`up`、`scrape_*`、`devops_loki_*`、
  `devops_health_rollup_*`。主機只有一台、叢集只有一個，硬把專案標籤貼上去
  會產生一個永遠只有一個值的維度，那不是資訊是雜訊。

**不帶標籤本身是一個判斷，不是遺漏**，所以它寫在這裡而不是留給下一個人推測。

## 資料夾

`foldersFromFilesStructure: true`，子目錄名即資料夾名。編號前綴讓資料夾清單
按工作流順序排，而不是按字母排（Grafana 只會按字母排）：

```
dashboards/
  0-overview/          platform-stages.json      三線階段燈號（跨學科的入口）
  1-infra-monitor/     infra-monitor.json        主機、磁碟、抓取目標、日誌攝入
  2-devops/            devops-overview.json      上版狀況：兩份副本、schema、錯誤率
  3-dataops/           dataops-pipeline.json     來源新鮮度、漂移、攝入健康
  4-mlops/             mlops-model.json          模型評估與事後評分
```

`0-overview` 是第五個資料夾而使用者只列了四個學科——它不是第五個學科，是**索引**。
三線階段燈號同時屬於三個學科，放進任何一個都會讓另外兩個的讀者找不到它。

## 代價

1. **`$project` 是一個要維護的變數。** 每張專案層的看板都要在每個查詢裡帶上
   `project="$project"`，漏掉一個面板就會在多專案時同時畫兩個專案的線。
   `platform/tests/dashboard_audit.py` 檢查這件事。
2. **標籤基數。** `project` × `target` × `horizon` × `algorithm` 會相乘。
   目前是 1 × 2 × 2 × 2 = 8 條線；十個專案時是 80。這仍在 textfile 匯出器的
   合理範圍內，但它是有上限的，而上限應該在被撞到之前就寫下來。
3. ~~**既有 `dataops_*` 沒有標籤。**~~ **2026-09-09 做掉了**，而且比預期便宜：
   13 個發射點全部走同一個 `base_labels()`，告警規則用的是 `by (source)`
   所以不受影響，看板由 `dashboard_audit.py` 驗過。**真正的成本不是改三個
   地方，是既有序列的身分改變**——Prometheus 裡舊的無標籤序列會在保留期內
   與新序列並存，跨越那條界線的查詢會看到一個斷點。這是加標籤這件事無法
   迴避的代價，寫在這裡是為了下一次有人問「為什麼那天的線斷了」。
4. **一個只有一個值的維度，仍然要顯式決定。** `project="station2-twin"`
   目前在每一條 `dataops_*` 與 `mlops_*` 上都是同一個值，看起來是廢話。
   它不是：**這一週已經有六個地方因為「目前只有一個值」而靜默地壞掉**
   （見 Backlog §37）。標籤存在時第二個值只是多一條線；標籤不存在時，
   第二個值會安靜地疊到第一個值上面。

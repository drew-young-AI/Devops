---
type: explanation
title: 規則與圖表以「能不能評估」驗收，不以「能不能解析」
description: "Validation must run a rule or panel rather than parse it, because both fail silently while reading as healthy."
tags:
  - decision
  - observability
  - testing
timestamp: 2026-08-29T00:00:00+08:00
decision:
  id: 7
  status: accepted
  date: 2026-08-29
  measured: true
  rerun: platform/tests/test_dashboards.sh
---

# 0007 規則與圖表以「能不能評估」驗收，不以「能不能解析」

## 決定

告警規則與儀表板的驗收條件，從「靜態檢查通過」改成**「在跑著的系統上真的取得到值」**：

| 對象 | 舊驗收 | 新驗收 | 由誰執行 |
|---|---|---|---|
| 告警規則 | `promtool check rules` | 加上 `/api/v1/rules` 每條 `health == "ok"` | `test_dataops_metrics.sh` |
| 儀表板 | 無（完全沒測過） | 每個 panel 透過 Grafana `/api/ds/query` 真的回傳資料 | `test_dashboards.sh` |
| 燈號板的 `prometheus` 節點 | 容器在跑 | 容器在跑**且**規則評估得動 | `dag.py: probe_prometheus` |
| 對外連結的主機名 | 無 | `PLATFORM_LAN_HOST` 必須解析得到 | `test_network_exposure.sh` |

## 促成這個決定的三件事，同一天發現

**一、規則解析通過，但每個週期評估失敗。**
`WidespreadGeoDrift` 用了隱含的多對一向量匹配。YAML 合法、PromQL 文法合法、
`promtool check rules` 回報 `SUCCESS: 6 rules found`。Prometheus 載入後
**每一個評估週期都失敗**，持續 11 小時。

`promtool` 抓不到這件事，而且不是它的缺陷：向量匹配取決於**執行當下實際存在的標籤**，
靜態檔案裡沒有那個資訊。只有評估知道。

期間燈號板顯示 `prometheus  ok  running (none)`、`alertmgr  ok  no active alerts`——
而「沒有活躍告警」和「規則根本產不出告警」長得一模一樣。

修好之後那條規則**立刻抓到 8 筆真實漂移**，其中 COVID-19 是 21 個可比地區**全部**同向下降。
這 11 小時裡它一直在那裡。

**二、給長官看的那張儀表板，每個 panel 都連不到資料來源。**
`platform-stages.json` 的 16 個查詢全部指向 datasource uid `prometheus`，
而 `datasources.yml` 佈建的是 `PBFA97CFB590B2093`。Grafana 回
`{"message":"Data source not found"}`，panel 畫空白。

JSON 合法、PromQL 合法、指標存在、`promtool` 與此無關，其他所有測試全綠。
**當時沒有任何測試會讀儀表板。**

**三、每一封告警信裡的連結指向不存在的主機。**
`PLATFORM_LAN_HOST=70.local`——舊主機名，DNS 完全解析不到。Grafana 用它組出每一個
分享連結與告警連結，Alertmanager 的信件範本把它放進每封通知的
`Board:` / `Grafana:` footer。本機一切正常，因為沒有人在本機點那些連結。
會發現的只有**在收到告警信時點下去的那個人**——也就是最糟的時機。

## 共同形狀

三件事都是**沉默失效**：東西存在、看起來被設定好了、產不出任何訊號，
而「產不出訊號」與「一切正常」在畫面上完全相同。

三件事也都**不是靜態檢查抓得到的**。它們的正確性取決於執行時期才存在的東西——
實際標籤、實際佈建的 datasource、實際的 DNS。

## 代價

測試需要跑著的服務。這是刻意的取捨，與 `test_data_contract_live.sh` 同一個立場：
**在服務不在時跳過並標記 `UNVERIFIED`，不是預設通過。** 一個在沒有資料時也會綠的
資料契約測試，在 2026-08-19 那次 3 小時 55 分的憑證中斷期間會全程回報成功。

## 副作用：又一份重複的定義被移除

漂移比例的算式原本會同時出現在告警與圖表裡。改成 recording rule
`dataops:yoy_geo_drift_share`，一處定義、兩處讀取。

這是本平台第五次踩同一個坑（`install.sh` 的門檻與它的測試各一份；`LINES` 與儀表板的
節點正則各一份；`dag.py` 的 `RANK` 與 Grafana 的 value mapping 各一份；
`PLATFORM_LAN_HOST` 與各處連結）。`dashboard_audit.py` 現在會擋下前三種。

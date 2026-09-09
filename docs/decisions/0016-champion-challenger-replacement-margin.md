---
type: explanation
title: 上線模型的汰換規則：相對 2% 門檻，同分留任
description: "The database gate answers 'is this a model at all'. Nothing answered 'is it better than the one already serving' -- the publisher just ORDER BY mae LIMIT 1, across feature sets. This fixes the comparison and states the margin as a policy with a measured floor."
tags:
  - decision
  - mlops
  - model-gate
  - pilot
timestamp: 2026-09-08T00:00:00+08:00
decision:
  id: 16
  status: accepted
  date: 2026-09-08
  measured: true
  rerun: pilots/station2-twin/mlops/run.sh publish_forecast.py --explain-gate
  supersedes: []
---

# 0016 上線模型的汰換規則：相對 2% 門檻，同分留任

## 決定

**挑戰者要取代線上模型，必須在同一個 feature set 上，相對 MAE 至少好 2%。
差距在 2% 以內（含打平、含挑戰者略好）一律留任現役。**

規則本體：`platform/mlops/promotion_policy.py`（專案中立、無預設門檻）。
門檻數字：`pilots/station2-twin/mlops/publish_forecast.py` 的 `REPLACEMENT_MARGIN`。
看板上那行門檻是**讀**這個檔案印出來的，不是另抄一份。

## 這一條之前不存在，而它看起來存在

資料庫的 trigger 擋掉「輸給持平基準的模型」——那是事實判斷，各專案都一樣，
所以放在 trigger 裡誰都繞不過。但「該不該換掉現役」從來沒有人回答過。
`publish_forecast.py` 的選法是：

```sql
WHERE beats_baselines ORDER BY mae ASC LIMIT 1
```

這一行讀起來像有規則，實際上有兩個問題：

1. **它會為了 0.01% 的差距換掉線上模型**，而且不會說。
2. **它跨 feature set 比較 MAE。** migration 013 自己寫過一句話：
   「baseline evaluated on different folds is not a comparison, and that
   mismatch is invisible in a single reported number」——然後隔壁那張表的
   publisher 就是照 MAE 跨所有 feature set 排序。**同一個錯誤，隔一張表。**
   551 折算出來的 0.001682 和 553 折算出來的 0.001680，印出來一模一樣，
   意思不一樣。

今天剛好是新的 feature set 贏，所以線上沒有錯的模型。**這不是規則擋下來的，
是運氣。**

## 2% 是怎麼來的（量測，不是拍腦袋）

2026-09-08 於 pilot 資料庫實測。同一組設定、同一個模型，只差兩週資料：

| run | feature_set | 設定 | MAE |
|---|---|---|---|
| 2 / 6 / 8 / 10 | 1 | HGB t+2 相同超參 | 0.001682 |
| 12 / 14 | 55 | 同上，兩週後 | 0.001680 |

**模型不動，兩週新資料把分數移動了 0.12%。** 贏不到這個幅度的挑戰者，
沒有證明自己是更好的模型，只證明了資料動了。

另一端：Ridge 在 t+2 比 HGB 差 11.6%。**2% 落在「資料雜訊」與「家族差異」
中間，離兩邊各約一個數量級。** 它是一把刻意鈍的刀。

## 為什麼打平留任

換掉線上模型不是免費的：發布出去的序列會換形狀、下游任何學過它行為的東西失效、
事後要對臨床端解釋為什麼換。為了雜訊等級的差距付這個成本，是有成本沒有效益。
**偏向穩定是一個選擇，寫在這裡，而不是藏在一句 `ORDER BY` 裡。**

## 2026-09-09 補測：這條規則在 431 次真實決策裡一次都沒有生效過

把 `--margin` 掃過 `0.00 / 0.01 / 0.02 / 0.05 / 0.10 / 0.20`，重放同一段歷史
（fs=100 流感 t+2、451 個 origin、431 次發布）：**六個結果逐位元相同。**

證據：`evidence/mlops/policy_margin_sweep_*.json`，重跑指令

```bash
export PGPASSWORD="$(docker exec station2-twin-db-1 sh -c 'printf %s "$POSTGRES_PASSWORD"')"
pilots/station2-twin/mlops/run.sh policy_backtest.py \
  --feature-set 100 --horizon 2 --all-origins --margin 0.10 --json -
```

原因用 `--lock-family` 分離出來：

| 只准這個家族上線 | 通過閘門 | 對持平基準 |
|---|---:|---:|
| `HistGradientBoostingRegressor` | 431 / 451 | **+6.58%** |
| `Ridge` | 151 / 451 | **−7.13%** |

**門檻仲裁的是接近的平手，而這段歷史裡沒有平手。**

### 這不推翻這條規則，但它改變這條規則的地位

- 它仍然是**必要的護欄**：沒有它，一個贏 0.3% 的挑戰者就會把現役換掉，
  而那個 0.3% 在 §36 的配對自助法區間裡分不出來。
- 但 2% 這個**數字**目前是**未被現實測試過的**。§27 T23 說「等出現第一次
  挑戰者落在 1–3% 之間」——**那一天還沒到，而現在知道它為什麼還沒到**：
  候選只有兩個家族，而其中一個從頭到尾輸給持平基準。
- **要讓這個門檻真的被測試，需要的不是等待，是更多便宜的候選家族**
  （見 Backlog §39）。這是一個可以主動促成的條件，不是只能觀望的條件。

## 這條規則的已知弱點

2% 是**政策**，不是統計論證。真正該回答「這個差距是不是真的」的方法是
**同折配對檢定**（paired test on per-fold errors）——同一批折、逐折比誤差。
`model_run` 只存彙總值，存不到逐折誤差，所以現在做不了。

已登記為 **Backlog T23**。在那之前，這個門檻在看板上會標明是門檻，
不會被講成統計顯著。

## 六種判定，全部有可重跑的案例

```
pilots/station2-twin/mlops/run.sh publish_forecast.py --explain-gate
```

| 判定 | 情境 | 動作 |
|---|---|---|
| `BOOTSTRAP` | 這個 horizon 還沒有線上模型 | 發布最佳候選 |
| `REPLACE` | 挑戰者超過門檻 | 換 |
| `KEEP` | 挑戰者較好但在門檻內 | 留任 |
| `REFRESH` | 現役設定仍是最佳 | 用新資料重擬合現役 |
| `INCOMPARABLE` | 現役在目前 feature set 上沒有分數 | 發布最佳候選，**並明說無法比較** |
| `REFUSED` | 沒有通過基準閘門的候選 | 不發布（閘門正常運作） |

`INCOMPARABLE` 不是把現役當成輸——那會讓每次重建特徵都無條件換模型。
它是一個**被命名的狀態**，正常情況下由每週 retrain 先跑現役設定來避免。

## 驗收

```bash
platform/tests/test_model_registry.sh     # 六種判定各一個案例 + 邊界
pilots/station2-twin/mlops/run.sh publish_forecast.py --dry-run
```

2026-09-08 實測：t+2 判 `REFRESH`（現役 run 12 的設定，重擬合為 run 14），
重擬合預測值 2.3564 pp，與現有 forecast 7 逐位相同——**換掉整條擬合路徑之後
數字不動，這是重構沒有改變行為的證據。**

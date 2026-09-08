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

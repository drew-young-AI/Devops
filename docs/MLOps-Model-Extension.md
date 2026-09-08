---
type: how-to
title: 模型怎麼擴充（統計／深度學習／混合模態）
description: "The model registry, what a new entry must declare and why, and the measured constraints each family runs into on this dataset and this machine."
tags:
  - mlops
  - model
  - extensibility
  - pilot
timestamp: 2026-09-08T00:00:00+08:00
---

# 模型怎麼擴充

`verify`：`pilots/station2-twin/mlops/run.sh backtest.py --list-models`

這份文件回答一個問題：**要換成別的模型，要動什麼、以及動之前必須先回答什麼。**
它不主張任何一種模型比較好——那要靠回測講話，而回測是可重跑的。

---

## 一、現在有什麼（不是規劃，是跑得出來的）

```bash
pilots/station2-twin/mlops/run.sh backtest.py --list-models
```

| 名稱 | 家族 | 吃 NaN | 缺值政策 | 可重現 |
|---|---|---|---|---|
| `HistGradientBoostingRegressor` | 梯度提升樹 | 是 | —（原生支援） | 是 |
| `Ridge` | 統計／線性（L2） | 否 | 中位數填補 ＋ 缺值指示欄，**每折在 pipeline 內擬合** | 是 |

**同一批折、同樣的基準，實測（2026-09-08，feature_set 55、556 列、n_test 451）**：

| 模型 | t+1 對持平基準 | t+2 對持平基準 | t+2 方向準確率 |
|---|---|---|---|
| HistGradientBoosting | −12.1% | **+0.6%** | 63.8% |
| Ridge | −22.0% | −11.0% | 62.0% |

這兩筆 Ridge 已經**寫進 `model_run`（run 15／16），不是 dry-run 的紙上數字**。
板面因此長成這樣，而且這一行就是「新模型 vs 目前線上模型」：

```
t+1 最新 run15 Ridge -21.99%（尚未上線）
t+2 最新 run16 Ridge -11.01%（線上 run12 +0.55%）
```

**挑戰者輸給線上那個，板面把兩個分數並列。** 順帶暴露了一件事：
在只有一個模型時「最新一次 run」是明確的，有了第二個家族之後**必須帶上模型名稱**，
否則樹模型與線性模型的數字會輪流佔用同一格，看起來像同一個模型時好時壞。
`dag.py` 的 `MODEL_GATE_SQL` 因此也一併帶出 `algorithm`。

兩者**都不足以宣稱可用**。t+2 的 +0.6% 在雜訊範圍內，程式自己就這樣講
（`but only by 0.6% -- within noise, not a result`）。
Ridge 兩個 horizon 都輸，**上線閘門會直接拒絕它**——這正是閘門存在的理由，
而且這件事現在有第二個模型可以示範，不再只是一句宣稱。

---

## 二、加一個模型要動的東西（三步）

1. 在 `pilots/station2-twin/mlops/backtest.py` 的 `MODELS` 加一筆
2. `./run.sh backtest.py --algorithm <名稱> --horizon 1 --predict-delta --dry-run`
3. 數字說服人了，拿掉 `--dry-run`；它會寫進 `model_run`，
   之後由 `publish_forecast.py` 的閘門決定上不上線

**沒有第四步。** 不用改資料庫、不用改看板、不用改排程：
`model_run` 的 `algorithm`／`hyperparams`／`feature_set_id`／`code_sha256`
本來就是為多模型設計的。

### 一筆登記必須宣告的六件事，以及為什麼每一件都不是選填

| 欄位 | 為什麼強制 |
|---|---|
| `family` | 板面與報告要能看出**兩次 run 到底可不可比** |
| `build(hp)` | 回傳**未擬合**的估計器。擬合在每一折內部發生；回傳已擬合的物件會讓 rolling-origin 靜默失效 |
| `hyperparams` | **同一個 dict** 同時餵給 `build()` 與寫進 `model_run`。這一欄以前是三份手抄副本（banner、建構子、INSERT），換模型會讓紀錄描述上一個模型 |
| `handles_nan` | 決定這個家族**能不能直接加**，見第三節 |
| `nan_policy` | `handles_nan=False` 時必填，否則註冊表直接拒絕啟動 |
| `deterministic` | `False` 允許但**必須宣告**。CLAUDE.md §5b 把不可重現的結果視為 `UNVERIFIED`，而閘門比的是小數點後四位的 MAE |

**未登記的名稱一律拒絕並列出清單，絕不預設回退**——
靜默回退會把一個演算法的名字記在另一個演算法的數字上。

### 登記完之後會被**真的執行一次**，不是只被印出來

`--list-models` 會對每一筆呼叫 `build(hyperparams)`，並檢查回傳物件：
有 `.fit()`／`.predict()`，而且**還沒有被擬合過**（sklearn 在 `fit` 之後才會有
`n_features_in_`）。回傳已擬合估計器的條目會被拒絕，訊息指名是哪一筆。

理由：已擬合的物件跑起來一切正常，分數是**把測試列包在擬合裡面**算出來的，
下游沒有一個地方看得出異常。這條守衛本身用**突變測試**驗證會紅
（`platform/tests/test_model_registry.sh`，還原後 `cmp` 逐位元比對）。

---

## 二之二、換到別的專案怎麼重用（這一層是中立的）

```
platform/mlops/model_registry.py     契約：一筆登記合不合法        ← 共用
platform/mlops/promotion_policy.py   規則：挑戰者何時取代現役      ← 共用
pilots/<專案>/mlops/backtest.py      條目：這個專案有哪些模型      ← 各專案
pilots/<專案>/mlops/publish_forecast.py  門檻數字＋為什麼是這個數字 ← 各專案
```

**分界線是：中立層放「怎麼判斷」，專案層放「判斷什麼、門檻多少、為什麼」。**
中立層裡沒有任何一個字提到流感、疾病、22 個縣市或 51.8% 的缺值率——
那些理由屬於條目，要跟條目放在一起才看得懂。

三條刻意的限制，都是為了**收斂**而不是為了廣泛：

1. **沒有 plugin 掃描、沒有 entry points、沒有 YAML、沒有字串 import。**
   加一個模型是一次程式碼變更，跟其他變更一樣被審。
   「能載入一個沒人看過宣告的模型」的註冊表，是它要解決的問題的加強版。
2. **汰換門檻沒有預設值。** `promotion_policy.choose_run()` 的 `margin`
   是必填參數。沒想過門檻的專案應該被逼著想，不是拿到 `0.02` 和一片沉默。
3. **六個欄位就是六個，不加第七個。** 每加一欄都是每個專案都要填的成本；
   目前這六欄各自對應一個已經發生過的失效。

新專案要接上，只要：容器掛載 `platform/mlops`（見
`pilots/station2-twin/mlops/run.sh`）、宣告自己的 `MODELS`、
在測試裡呼叫一次 `mreg.validate_all(MODELS)`。

---

## 二之三、上線之後：挑戰者什麼時候換掉現役（ADR-0016）

回測贏基準只回答了「這是不是一個模型」。**「該不該換掉線上那個」是另一個問題**，
規則寫在 `platform/mlops/promotion_policy.py`，門檻寫在 pilot：

```bash
pilots/station2-twin/mlops/run.sh publish_forecast.py --explain-gate
```

| 判定 | 情境 |
|---|---|
| `BOOTSTRAP` | 這個 horizon 還沒有線上模型 |
| `REPLACE` | 挑戰者相對 MAE 好過 2% |
| `KEEP` | 挑戰者較好但在 2% 以內 → **留任** |
| `REFRESH` | 現役設定仍是最佳 → 用新資料重擬合 |
| `INCOMPARABLE` | 現役在目前 feature set 上沒有分數 → 發布最佳候選並明說 |
| `REFUSED` | 沒有通過基準閘門的候選 |

**2% 的來源是量測**：同一組設定、只差兩週資料，MAE 移動 0.12%；
不同家族之間相差 11.6%。2% 落在中間，離兩邊各約一個數量級。
細節與已知弱點見 `docs/decisions/0016-champion-challenger-replacement-margin.md`。

**候選只在同一個 feature set 內比較。** 551 折算出來的 MAE 和 553 折算出來的
MAE 印起來一樣長、意思不一樣。

---

## 三、加之前必須先回答的問題（每一題都有量測值）

### 3-1 缺值：這份資料 51.8% 的 COVID 特徵是 NULL

| 特徵 | 556 列中 NULL 的數量 | 為什麼 |
|---|---|---|
| `covid_lag_1` | **288（51.8%）** | COVID 資料 2020 才開始，序列回溯到 2015 |
| `same_week_last_year` | 52（9.4%） | 第一年沒有去年 |
| `lag_4` | 4 | 序列開頭 |
| 其餘 | 1–2 | 序列開頭 |

**這不是「遺漏」，是「當時不存在」。** 差別很重要：

- **丟掉不完整的列** → 少掉一半歷史，而且丟掉的全是 2020 以前
- **靜默填補** → 等於**發明了一段 2020 年以前的 COVID 訊號**

樹模型原生吃 NaN，所以現行模型沒碰到這題。**線性與深度模型都會碰到。**
`Ridge` 的做法是唯一被接受的形狀：**明講**（中位數填補 ＋ 缺值指示欄），
而且用 sklearn 的 `Pipeline`，讓填補的統計量**每折只從訓練列學**——
不是我們自己寫的迴圈，所以不會有自己寫錯 leak 的空間。

### 3-2 資料量：556 列，這是深度學習的硬牆

feature_set 55 有 **556 個週**（約 10.7 年），`min_train=104`（兩年）之後
可回測 **451 折**。特徵 12 個（11 個基礎 ＋ 1 個每折重算的季節指數）。

556 這個數字對 LSTM／TCN／Transformer 來說**不是「有點少」，是少兩個數量級**。
可以硬跑，會得到一個過擬合的模型與一個好看的隨機分割分數——
而這個 repo 已經留了 `--also-wrong-split` 專門示範那個數字長什麼樣。

**要做深度學習，先解決資料量，不是先解決模型。** 兩條路，都不是這個 pilot 現在的範圍：

- **擴 panel**：現在的目標是「單一地區（66000）／單一就診別／單一疾病」的一條序列。
  22 個縣市 × 13 種疾病是 286 條序列，**全域模型（global model）** 在
  286 × 556 上才有話講。代價是要重新定義 `feature_set`，而且要處理跨地區的異質性。
- **換頻率**：TB 那條線是**日**粒度（`cal_date` 到 2026-09-01，4.1M 列）。
  但那是不同疾病、不同問題。

### 3-3 這台機器：訓練有時間上限

CLAUDE.md §5c：這是 MacBook Pro（被動散熱、無 ECC、非機房）。
**禁止 >10 分鐘的持續滿載**——不是為了保護機器而已，
是因為降頻之後測到的是散熱曲線不是模型行為，結論不可重現。

實測參考：現行 HGB 的 451 折全跑完是**秒級**。
任何一個候選模型如果單次回測要跑幾十分鐘，它就不屬於這台機器，
屬於 ubu 或雲端——而那是 T7 之後的事。

### 3-4 混合模態：先問資料在哪裡

「混合模態」在這個 pilot 的具體意思是**把非監測資料接進特徵**。現在庫裡有的：

| 已載入 | 粒度 | 現在有沒有用 |
|---|---|---|
| 人口／戶數（`population`、`households`） | 縣市／鄉鎮，年 | 只當分母（`denominator_lag_1`） |
| 年齡分層 | `age_band`，週 | 用了一個（`age_share_0_6_lag_1`） |
| 跨疾病訊號 | 週 | 用了兩個（`covid_lag_1`、`entero_lag_1`） |
| 8,059 個行政區的地理階層 | 縣市／鄉鎮／村里 | **完全沒用**——目前只做 66000 一個地區 |

**沒有的**：氣象、人流、學校行事曆、疫苗接種率。這些要新的 `ingest` 來源，
而每一個新來源都要走 `ingest_runs` 的 `content_sha256` 與守恆 CHECK。
**先有來源才有模態，不是先有模型再去找資料。**

---

## 四、擴充不會改變的四件事（也不該改變）

1. **折的切法**：`rolling_origin(rows, horizon, min_train)` 不看模型是誰。
   兩個模型比得起來，就是因為它們踩的是同一批折。
2. **基準**：持平（下週等於本週）與季節天真（去年同週）。
   換模型不換基準，否則跨模型的 margin 不可比。
3. **閘門**：`WHERE beats_baselines ORDER BY mae ASC LIMIT 1`——
   **贏了才准上線，且只在贏的那群裡挑最好的**，不會從一群輸家裡挑最不爛的。
   多了模型不會鬆動這條，只會多幾個候選。
4. **provenance**：`code_sha256` 綁的是**產生特徵的程式碼**。
   模型換了而特徵程式沒換，`code_sha256` 就該一樣——這是刻意的。

**閘門目前不做的事**（登記在 `docs/Backlog.md` §27 的 T22）：
它拿候選跟**持平基準**比，不跟**目前線上的模型**比。
多模型之後這件事會更重要——板面已經把兩個數字並列，
但「略差但更穩定的模型該不該取代線上的」是業務決定，這個 repo 答不出來。

---

## 五、給長官的一頁總結

- **要換模型：改一個檔案裡的一筆登記，跑一行指令。** 資料庫、看板、排程都不用動。
- **統計／線性模型：現在就能加**，Ridge 已經是活的第二筆，實測輸給樹模型。
- **深度學習：不是模型問題，是資料量問題。** 556 週擋在那裡，
  要做得先把 pilot 從「一個地區」擴成「286 條序列」。
- **混合模態：先有來源才有模態。** 氣象／人流／疫苗接種率目前一筆都沒載入。
- **不論加什麼，閘門不變**：贏不了持平基準就不會上線。
  這是這個 pilot 至今只發布 2 筆預測的原因，而那是機制在運作，不是機制壞了。
- **贏了基準也不一定換掉線上模型**：要贏過現役 2% 才換，打平留任（ADR-0016）。
  換掉服務中的模型有成本，為雜訊等級的差距付這個成本是有成本沒有效益。
- **這一層可以搬到別的專案**：契約與汰換規則在 `platform/mlops/`，
  各專案只帶自己的模型條目與門檻數字。

相關：[`docs/Backlog.md`](Backlog.md) §31／§33（MLOps 那條鏈與第二次倒推）、
[`docs/decisions/0016-champion-challenger-replacement-margin.md`](decisions/0016-champion-challenger-replacement-margin.md)（汰換規則）、
[`pilots/station2-twin/README.md`](../pilots/station2-twin/README.md)（業務層的決策背景）

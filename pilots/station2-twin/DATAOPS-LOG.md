---
type: reference
title: DataOps 記錄 — station2-twin
description: "Provenance and cleaning log for the pilot's public-health data: how each feed was found, every defect measured in it, and the reasoning behind each cleaning decision."
tags:
  - dataops
  - data-quality
  - provenance
  - surveillance
timestamp: 2026-08-19T10:30:00+08:00
---

# DataOps 記錄 — station2-twin

> 這份文件記錄**資料本身**發生過什麼：來源怎麼找到的、髒在哪裡、
> 每一個清理決定的理由、以及哪些事情刻意沒有做。
>
> 為什麼要有這份文件：三個月後有人問「台中市 2021-08-23 的結核病數字為什麼
> 是 24 不是 25」，答案不能只存在某個人的記憶裡。程式碼說明「怎麼做」，
> migration 說明「schema 怎麼變」，這裡說明**「為什麼相信這些數字」**。
>
> 平台面的階段紀錄在 `../../STAGE_REVIEW.md`；這裡只談資料。

---

## 1. 資料來源盤點（2026-08-18/19）

### 怎麼找的

不是猜 URL。對 `data.cdc.gov.tw` 的 CKAN API 取 `package_list`（73 個
dataset），再對每一個呼叫 `package_show`，把所有 resource 的名稱與網址攤平
後，用關鍵字（鄉鎮 / 村里 / 每日 / 日別 / 發病日）過濾。

```bash
curl -s https://data.cdc.gov.tw/api/3/action/package_list
curl -s "https://data.cdc.gov.tw/api/3/action/package_show?id=<name>"

```

這個做法找到了 `tbdata001`，而先前逐一猜測 URL 的做法沒有。**先列舉再過濾，
不要先假設再驗證。**

### 找到什麼

| feed | 空間 | 時間 | 期間 | 分母 | 量測型別 | 原始列數 |
|---|---|---|---|---|---|---|
| `cdc-rods-ili` | 縣市 | 流行病學週 | 2007–2026 | 無 | flow | 109,907 |
| `cdc-nhi-ili` | 縣市 | 流行病學週 | 2016–2026 | **有** | flow | 187,908 |
| `cdc-tb-town` | **鄉鎮** | 年 | 2005–2024 | 無 | flow | 7,360 |
| `cdc-tb-caremag` | **鄉鎮** | **日** | 2016–2026 | 無 | **stock** | 1,549,649 |

`cdc-tb-caremag`（`CareMagOld.csv` + `CareMagDailyList.csv`）是目前公開資料裡
**空間與時間同時最細**的一組：鄉鎮 × 日，涵蓋 3,867 個日期、370 個鄉鎮寫法。

### 確認不存在的東西

- **村里級的疫情 feed 不存在。** 村里「界線與代碼」有（內政部，7,871 筆），
  但沒有任何一個公開的疫情資料集是村里粒度。
- `Dengue_Daily.csv`（曾有村里 × 日）**已 404 下架**。CKAN 搜「登革熱」只剩
  `dengue_ns1_clinics`（診所名冊，靜態點位）。
- NIDSS 是 SPA，猜測的 API 路徑全部 404。

> 因此：**geo_area 建到村里，surveillance_fact 只到鄉鎮。**
> 維度描述的是國家的行政區劃，不是今天剛好有哪些 feed。村里 feed 出現時
> 直接落地，不需要 schema 變更，也不需要回填維度。

---

## 2. 地理權威：內政部國土測繪中心

`api.nlsc.gov.tw` 提供三層階層，而且用的就是 RODS/NHI 已經帶的 5 碼縣市代碼，
所以疫情 feed 不需要任何轉譯就能接上。

```
ListCounty              → 22 筆，countycode01 = 63000 這種 5 碼
ListTown/<county>       → 365 筆
ListVillage/<c>/<t>     → 7,871 筆，villageId 11 碼

```

**鄉鎮代碼是推導出來的，而且推導有被驗證。** NLSC 沒有直接發布鄉鎮代碼；
它是 villageId 的前 7 碼。載入器不假設這件事，它**證明**這件事：

- 同一鄉鎮底下每個村里的 7 碼前綴必須一致 → 0 筆例外
- 任兩個鄉鎮不得共用同一前綴 → 365 個鄉鎮、365 個相異前綴

任一條不成立就中止，不會帶著壞掉的鍵繼續跑。

### 快照，不是即時抓取

建一次參考資料要 ~390 次 API 呼叫、數分鐘。更嚴重的是，依賴第三方即時 API
的載入器**無法重現上個月的結果**。所以：

- `--refresh` 是明確的、獨立的動作，寫出 `reference/moi_admin_YYYYMMDD.csv`
- 平常的載入讀 repo 內的快照，並把快照的 sha256 寫進 `ingest_runs`

目前快照：`moi_admin_20260818.csv`，8,258 列，
sha256 `c696a731dd045013ec7ab7aded394f50f759171f1b318511c3ffd428772d1c6e`

### 權威自己的缺口（兩個，都已記錄）

**(a) 204 筆無名稱的村里。** NLSC 回傳名稱為空字串的村里，集中在連江縣
（0900702×44、0900703×41、0900701×39），代碼末段是字母而非 4 位數字
（例：`66000120S01`）。

處理：**快照原樣保留，載入時排除並印出數量。** 沒有名字的地方無法被名稱查詢
到，而目前沒有任何以代碼為鍵的村里 feed。若將來出現，它的代碼會撞上外鍵而
**大聲失敗**——那正是發現這件事的正確方式。原始與載入集不同，差異被印出來，
不被默默吸收。

**(b) 新竹市、嘉義市沒有區級代碼。** NLSC 把這兩個省轄市各當成一個單元。
但疾管署資料確實有區級（新竹市東區/北區/香山區、嘉義市東區/西區）。

處理：`crosswalk/derived_townships.csv` **明示宣告** 5 個衍生代碼，
`geo_area.code_system = 'derived'`，代碼含 `-` 肉眼可辨。
關鍵差別在於「宣告」：這是人審過的固定集合，不是載入器看到陌生地名就自己造
一個 key——後者正是 migration 005 修掉的錯誤。

---

## 3. 髒資料清單（全部實測，非推測）

同一個機關發布的兩個 feed，對同樣 368 個鄉鎮有六種不同的寫法。

| # | 類別 | 實例 | 規模 | 處理 |
|---|---|---|---|---|
| 1 | 空白字元 | `中　區`(U+3000) / `北  區`(兩個半形空白) / `北區` | 同一 feed 內三種寫法並存 | 機械正規化（移除所有空白 + 臺→台），**並先驗證正規化後官方地名不會互撞** |
| 2 | 名稱截斷 | `太麻里`→`太麻里鄉`、`阿里山`→`阿里山鄉`、`三地門`→`三地門鄉`、`那瑪夏`→`那瑪夏區` | 4 個 | crosswalk 宣告 |
| 3 | 行政改制 | `員林鎮`→`員林市`(2015-08-08)、`頭份鎮`→`頭份市`(2015-10-05) | 2 個 × 2 feeds | crosswalk 宣告，附改制日期 |
| 4 | 行政類別錯誤 | `金寧鎮`→`金寧鄉`（金門縣無金寧鎮） | 1 個 | crosswalk 宣告 |
| 5 | 已廢止實體 | `舊中縣 / 豐原市`（2010-12-25 台中縣市合併後改制為豐原區） | 全檔 1 列，2021-08-23 | crosswalk 宣告 → 隨即引爆 #7 |
| 6 | 完全重複列 | 逐位元組相同的 (縣市, 鄉鎮, 日期) | **187,724 列，占 12.1%**，橫跨 526 個日期 | 去重並計數，寫進 `ingest_runs` |
| 7 | **值衝突** | `舊中縣/豐原市` = 1 vs `台中市/豐原區` = 24，同一天同一地 | **1 列** | **拒絕並具名印出** |

### #7 值得單獨說明

第一版去重只比對「鍵」，不比對「值」。兩列鍵相同 → 保留先遇到的、丟掉後面的，
**沒有任何訊息**。

而這兩列不是重複，是矛盾：`manage_number` 一邊是 1、一邊是 24。

最危險的地方在於：**修掉之後總列數完全沒變，都是 4,085,772。**
任何基於「筆數對不對」的檢查都抓不到它。

修正後的規則：

- 值相同 → 是重複，靜靜丟掉但**計數**
- 值不同 → 是**衝突**，該列**拒絕**，並把細節印出來

```
CONFLICT 6600009 2021-08-23: [1, 1, 0] vs [24, 24, 0] (來源 台中市豐原區)

```

為什麼不加總成 25？因為資料沒有告訴我們這兩列是「互斥的兩群人」還是
「同一筆的重述」。加總是猜測。專案規則是：**數據對應必須有明確 evidence，
不得強迫對應。** 拒絕並具名，比安靜地猜一個數字誠實。

### 名稱對照的做法

不用模糊比對。`crosswalk/geo_alias.csv` 每一列是一筆**有署名、可查證**的宣告：

```csv
source_code,raw_county,raw_town,official_county,official_town,rule,evidence
cdc-tb-caremag,彰化縣,員林鎮,彰化縣,員林市,renamed,2015-08-08 彰化縣員林鎮改制為縣轄市員林市；內政部現登錄為員林市

```

載入器只做**精確查表**。查不到 → 拒絕該列，不猜。
crosswalk 指向一個權威裡不存在的地名 → **整批載入中止**，因為那是打錯字或
錯誤假設，兩者都必須擋下而不是跳過。

---

## 4. 量測語意：stock 不是 flow

這是接上 CareMag 之後最重要的模型變更。

- `管理中個案數` 是 **stock**：那一天還在治療管理中的人數
- `就診人次`、`新案發生數` 是 **flow**：一段期間內的事件計數

flow 沿時間加總有意義（一年的就診人次）。**stock 沿時間加總是胡說**——
同一個病人會在他生病的每一天各被算一次，結核病療程 6–9 個月，
天真地做年度 `SUM` 會高估約 200 倍。

舊 schema 沒有任何欄位記錄一個數字是哪一種，所以也沒有任何東西能阻止那個查詢
被寫出來。現在 `metric.measure_type` 把這件事變成**資料的屬性**，
`surveillance_rate` 檢視把它一起帶出來——想寫錯的查詢，得先讀到那個說它會錯的
欄位。

同樣的理由，`app/surveillance.py` 的 `MODELS` 把每個疾病**綁定**到唯一一組
(source, metric, time_level)。問 `?disease=tuberculosis` 得到 **HTTP 422**，
不是一個從 prevalence 算出來、看起來很有信心的 z-score。

---

## 5. 刻意沒有做的事

| 項目 | 理由 |
|---|---|
| **不統一年齡分組** | RODS 5 組（0~6/7~12/13~18/19~64/65+），NHI 9 組且切點不同。載入時統一會**不可逆地**破壞解析度，而且兩套本來就對不起來。原樣存，調和留給下游可重跑的地方。 |
| **不載入 CareMag 的 `T_conf_*` 欄位** | 那 8 個欄位（性別、年齡、實驗室狀態）是 confirmed 的**重疊子集，不是分割**：`T_conf_65plus` 和 `T_conf_afspos` 數的是同一批人。當成 age_band 存會暗示它們加總等於總數，而它們不會。 |
| **不載入 `tb_town_inc_rate.csv`** | 那是率（26.9/十萬），`surveillance_fact.value` 是 `INTEGER`。存整數會失真，四捨五入是竄改。已記為待辦：事實表需要一個 numeric 的量測欄位才能承載 rate。 |
| **不填補缺失** | 缺列就是缺列。`value=0` 意思是「有通報，數字是零」。事實表的 `value` **沒有 DEFAULT**——通報中斷和沒有疾病不能長得一樣。 |
| **不推斷流行病學週的曆法對應** | 資料裡 2009/2014/2020/2025 是 53 週年，六種標準慣例沒有一種對得上。`time_period.cal_date` 對週層級**保持 NULL**，直到疾管署確認定義。日層級 feed 直接填，不需要換算。 |

---

## 6. 目前狀態（2026-08-19）

```
geo_area          8,059   county/moi=22  township/moi=365  township/derived=5  village/moi=7,667
geo_alias            10   truncated=4 renamed=4 wrong_type=1 historical=1
time_period       ~4,900  epi_week / year / day 三種層級
surveillance_fact 4,390,947
    cdc-rods-ili     flow      109,907
    cdc-nhi-ili      flow      187,908
    cdc-tb-town      flow        7,360
    cdc-tb-caremag   stock   4,085,772
資料庫大小        1,797 MB

```

驗算：`(1,549,649 − 187,724 重複 − 1 衝突) × 3 metrics = 4,085,772` ✓

### 可重現性

```bash
cd pilots/station2-twin/ingest
PGPASSWORD=... ./run.sh load_geography.py       # 維度，讀 repo 內快照
PGPASSWORD=... ./run.sh load_dimensional.py     # 事實，四個 feed

```

`run.sh` 在**釘死版本的容器**裡執行（`Dockerfile`：python 3.12 +
psycopg 3.2.3 + certifi）。先前是用「PATH 上剛好有的 python」跑，那台主機的
python 是 3.9、沒有 psycopg，而要裝它就得污染主機——本機規則明文禁止。
**結果取決於你當時在哪個 shell 的管線不叫可重現。**

每次載入都在 `ingest_runs` 留一列：來源網址、內容 sha256、位元組數、
原始列數、接受、拒絕、重複、衝突。

### TLS 附註

`od.cdc.gov.tw` 送出錯誤的中繼憑證（leaf 由 `TWCA SSL Certification
Authority` 簽發，伺服器卻送 `TWCA Secure SSL Certification Authority`）。
瀏覽器用 AIA 自己去抓，Python 不會。處理方式是**釘住經 AIA 取得的正確中繼**
（`certs/twca-ssl-ca-2023.pem`），**不是** `verify=False`。
細節見 `certs/README.md`。

---

## 7. 已知缺口

1. **事實表無法承載 rate**：`value INTEGER`。要接 `tb_town_inc_rate` 或任何
   已經是比率的 feed，需要一個 numeric 量測欄位。
2. **流行病學週 ↔ 曆法日期未確立**：需要向疾管署確認 53 週年的定義。
   在此之前週層級無法與日層級 join。
3. **CareMag 的人口分母不存在**：只有計數，沒有鄉鎮人口。要算發生率需要另外
   接內政部人口統計。
4. **無村里級疫情資料**：維度已備妥，feed 不存在；可能需向疾管署申請
   （非開放資料）。
5. **CareMag 重新載入約 50 分鐘**：110 MB 下載 + 1.55M 列解析。尚未做增量載入
   （來源沒有提供變更指標）。

---

## 7. 這條線實際執行的載入器（2026-09-02 補上索引）

| 檔案 | 什麼時候跑 | 載入什麼 | 保證什麼 |
|---|---|---|---|
| [`ingest/run.sh`](ingest/run.sh) | 由 [`dataops/ingest.sh`](../../platform/dataops/ingest.sh) 呼叫（每日 03:00） | **入口**，容器化執行整條載入 | 帶 `--network host`（要抓政府 API）。**這一欄原本寫「排程與 CI 都從這裡進去」，而兩邊都不成立**：直到 2026-09-03 才有排程，CI 至今不跑載入器。四欄全部填滿、可達性四層全過，描述照樣是錯的——這是「描述會變錯」的實例，不是舉例 |
| [`ingest/load_dimensional.py`](ingest/load_dimensional.py) | 由 `ingest/run.sh` 呼叫 | 疫情事實表與維度 | 星狀模型的主線；upsert 與衝突判定在載入時決定，不留給查詢端 |
| [`ingest/load_registry.py`](ingest/load_registry.py) | 資料來源更新時 | 內政部戶政司**村里級人口統計** | **這是這個平台一直沒有的分母**——沒有分母，通報數只能比大小、不能算率，而流行病學要的是率 |

`load_registry.py` 在 2026-09-02 之前**沒有被任何從 README 連得到的文件指名**，
只被測試呼叫。它不是內部細節，它是這條線缺了很久的那一半。
守衛：`platform/docs/capability_graph.py`。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`ingest/discover_sources.py`](ingest/discover_sources.py) | 盤點資料來源時 | 列舉 CKAN 目錄，回報**真正可發布**的東西 | 回報的是**實際可取得**的，不是「猜一個 URL 看起來存在」的——猜出來的來源會在載入當天才爆 |

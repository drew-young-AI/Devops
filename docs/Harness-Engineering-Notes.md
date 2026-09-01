---
type: reference
title: Harness engineering 觀察筆記
description: "What DeepSeek Harness and Codex Security actually do, and the two ideas from them that bear directly on the harder problem: knowing where the TEST boundary is."
tags:
  - harness
  - agents
  - eval
  - research
timestamp: 2026-08-28T00:00:00+08:00
---

# Harness engineering 觀察筆記

**這份不是決策，是觀察。** 累積用，日後有決定再開 ADR。

起點是一個判斷：**agent 的能力邊界好判斷，測試的邊界難判斷。**
「這個 agent 做不做得到 X」跑一次就知道；「我的測試有沒有蓋到該蓋的地方」沒有等價的一次性答案。

## 一、規模先擺著（2026-08-28 實測）

| repo | ★ | 語言 | 授權 | 建立 |
|---|---:|---|---|---|
| `deepseek-ai/deepseek-harness` | **201,728** | TypeScript | MIT | **2026-08** |
| `openai/codex` | 119,498 | Rust | Apache-2.0 | 2025-04 |
| `openai/codex-security` | 10,240 | TypeScript | Apache-2.0 | 2026-07 |

`deepseek-harness` **比 DeepSeek-V3（104k）和 R1（92k）都大**，而且是這個月才建立的。
不到一個月 20 萬星——這個數字本身就是訊號：harness 這一層現在是重點，不是模型。

## 二、DeepSeek Harness：everything is a plugin

底層是 [Cordis](https://github.com/cordiverse/cordis)，論文 [_A Programming Paradigm for
Spatiotemporal Composability_](https://arxiv.org/abs/2608.25512)。

原文的關鍵句：

> plugins contribute services, typed events, and **reversible effects** to a shared context.
> Every part of the product is a plugin, **including the model adapter, the tool registry,
> the session log, and the agent loop itself**.
> There is **no privileged core to patch**.

### 四個值得學的性質

**1. 註冊是可逆的效果，plugin 卸載時自己解開。**
沒有「重載之後殘留一半舊狀態」這種問題。這是維運性質不是架構美學——
我們的排程器重載會重置計時器、nginx 重載要重啟容器，都是同一類問題的不同表現。

**2. 整棵組態樹可以 dump 出來 diff。**
`dsh --profile web --dump-config` 印出開機組成的每一列，而**印出來的任何一列都可以被自己的 patch 取代**。
這是「組態即可稽核物件」——我們的平台目前沒有等價物：Compose、jobs.conf、conf.d、alerts 分散四處，
沒有一個指令能印出「這台機器現在到底由什麼組成」。

**3. 層次順序是明文的**：bundle 依序 → profile patch → home patch → `--patch` 覆蓋。

**4. 有一個腳本專門擋「繞過正門的第二條路」。**
`verify-application-entrypoints` 把每個 package bin、可執行原始碼、根目錄 demo 都歸進明確類別，
並**拒絕任何繞過 `dsh` 的 Node 應用路徑**。

> 這正是我們 `cap validate` / `cap scan-drift` 在做的事，也是 `okf_check` 與
> `test_network_exposure` 在做的事：**擋住未登記的第二條路**。同一個原則被獨立地發明了三次，
> 這比任何星數都更能說明它是對的。

### 事件分三域，而選對域是第一個決定

| 域 | 語意 | 何時用 |
|---|---|---|
| **Session events** | 附加到 log 的**持久事實**，經 `session/event` 廣播 | 這個事實必須撐過重載 |
| **Agent events** (`agent/*`) | 帶著活的 `Agent`：inbox、step、status、request、validation、continuation | 觀察或攔截**進行中**的工作 |
| **Capability events** | 把政策與轉接器掛到接縫（`fs/*`、`tools/*`、`telemetry/*`） | 不需要 import agent loop |

**session 是 append-only 事件記錄**——和我們的 `evidence/**/*.jsonl` 是同一個形狀。
差別在他們把「哪些事實必須存活」變成一個要明確回答的設計問題，我們是憑感覺決定哪些寫進 evidence。

## 三、Codex Security：測試邊界的答案是「經驗性的」

它把工作切成 **finding → validating → fixing** 三段，**validating 是獨立的一段**。

SDK 的參數把終止策略直接寫在介面上：

```ts
await security.run("/path/to/directory", {
  mode: "deep",
  workers: 2,
  subagents: 0,
  stopAfterNoNew: 3,        // 連續 3 輪沒發現新東西才停
  maxDiscoveryRuns: 10,     // 硬上限
  maxTimeHours: 1.5,        // 時間上限
});

```

### `stopAfterNoNew: 3` 就是答案的形狀

**你不能先驗地知道測試邊界在哪，所以把它變成經驗問題**：
重複跑發現階段，直到**連續 N 輪沒有新東西**才收工，再用執行次數與時間當硬上限。

這和「寫 20 個測試就夠了」是完全不同的判準。前者測的是**飽和**，後者測的是**數量**——
而數量從來不知道自己漏了什麼。

### 另外兩個機制

- **findings service 有持久狀態**：發現跨次累積而不是每次從零開始，所以「已經找過」是真的知識不是印象。
- **去重先用 embedding 找候選，再「run independent Codex reviews locally」判定是不是同一件事。**
  相似度只用來**縮小候選**，判定交給獨立複審——不讓相似度直接下結論。

## 四、對我們的意義：兩個半互補的方法

我們已經有的是**突變測試**：改壞程式 → 跑測試 → 測試該紅。
它回答的是「測試**偵測得到**嗎」。

Codex Security 的 `stopAfterNoNew` 回答的是另一半：「還有沒有**沒被發現**的東西」。

| | 問題 | 我們有嗎 |
|---|---|---|
| 突變測試 | 既有測試偵測得到已知的破壞嗎 | ✅ 大量使用 |
| 飽和式發現 | 還有沒有沒人想到的破壞 | ❌ 完全沒有 |

**兩者缺一不可**：只有突變測試，只能證明你想得到的事情你測得到；
只有飽和式發現，找到的東西沒有人驗證是不是真的。

### 最小可行的下一步（未實作，等決定）

接回 `llmreview` 之後（它現在是 SUPERSEDED，在那之前談 eval 都是在談一個沒在跑的元件）：

1. 一組 golden commits，每個標註「應該被抓到什麼」——這是突變測試在 prompt 層的對應物
2. `SYSTEM_PROMPT` 變更時重跑，記錄抓到幾個。`system_digest` 已經存在，可以直接當版本鍵
3. 發現階段跑到**連續 2 輪沒有新發現**才收——把 `stopAfterNoNew` 的形狀搬過來

三項都是自己寫幾十行的事，不需要引入 langfuse 或任何服務。

## 五、一個要抵抗的誘惑

`deepseek-harness` 是 developer preview，README 自己寫著 **THERE WILL BE
COMPATIBILITY-BREAKING CHANGES**。20 萬星不代表可以接進生產路徑。

**值得學的是它的性質**（可逆註冊、可 dump 的組態、擋住第二條路的守衛），
**不是它的程式碼**。把它裝進來，就是用一個 preview 期的相依換掉我們自己能理解的東西——
那正是工具越加越多、地基反而變薄的路徑。

## 六、測試邊界是經驗問題（2026-08-29 的證據）

**能力邊界好判斷，測試邊界難判斷。** agent 做不做得到某件事，試一次就知道；
「測試涵蓋到哪裡為止」沒有任何單次觀察會告訴你——**沒被測到的東西不會發出聲音**。
這正是 `stopAfterNoNew` 存在的理由：邊界不能先驗宣告，只能跑到飽和為止。

這一天提供了一次乾淨的實例。當時的狀態是：

- 18 個測試套件，**全綠**，244 秒
- 每個守衛都被親手弄壞過一次，都紅過
- 同時有**三個沉默失效**在線上（見 [ADR-0007](decisions/0007-verify-by-evaluation.md)）

三個缺陷都不是「測試寫錯」，是**沒有任何測試看過那一類東西**：

| 缺陷 | 為什麼沒被抓到 |
|---|---|
| 告警規則每個週期評估失敗 | 只做靜態檢查，沒問過跑著的 Prometheus |
| 儀表板每個 panel 連不到資料來源 | **沒有任何測試讀過儀表板檔案** |
| 對外連結的主機名不解析 | 沒有測試查過 DNS |

三個都不是被差勁的測試漏掉的，是被**不存在的測試**漏掉的。加更多同類斷言不會找到它們，
因為新斷言只會落在已經被看過的類別裡。

### 可以拿來問的問題

「測試夠不夠」問不出答案（數量從來不知道自己漏了什麼）。可問的是：

1. **有哪一類產出物，至今沒有任何測試讀過它？**
   儀表板 JSON 存在數月無人讀，是被這個問題找出來的，不是被覆蓋率找出來的。
2. **有哪個宣稱，是靠「解析成功」而不是靠「執行成功」支撐的？**
   `promtool` 對一條永遠評估失敗的規則回報 SUCCESS。
3. **哪個事實在兩個地方各有一份？** 這個平台踩了五次。
4. **有沒有哪個「證據齊全但沒人讀」的地方？**
   健康探針連續 11 小時寫入 `UNKNOWN`。偵測是對的，抵達沒有發生。

這四個問題不會窮盡邊界——**它們每次會把邊界往外推一格，而且推的量可以看見**。
這就是把測試邊界當經驗問題處理的實際樣子。

### 這一天推了多遠

新增 3 類過去從未被讀過的產出物（儀表板、活的規則健康、對外連結的 DNS），
新增 22 項斷言，全部負向驗證過。找到 3 個線上缺陷。

**下一輪要問的是第 1 題：還有哪一類東西沒有任何測試讀過。**
目前已知的候選：Alertmanager 的路由（信件範本從未被渲染過）、
`.github/` 的 workflow 檔、OpenTofu 的 plan 產物。

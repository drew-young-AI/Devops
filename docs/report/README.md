---
type: how-to
title: 八張圖：線上與離線兩個版本，一份來源
description: "One source, two builds: the published Artifact and a zero-network HTML for presenting."
tags:
  - report
  - offline
  - diagrams
timestamp: 2026-09-02T00:00:00+08:00
---

# 八張圖：線上與離線，一份來源

## 快速使用

```bash
open docs/report/plates.offline.html      # 離線開啟，不需網路、不需伺服器
docs/report/build.sh                      # 改完來源後重新產生離線版
```

要 Keynote / PowerPoint 用的素材：打開離線版，點左上角 **「匯出八張 SVG」**，
八個 `.svg` 直接拖進投影片。SVG 是向量，投影機放大不糊。

## 檔案是什麼

| 檔案 | 角色 |
|---|---|
| `plates.src.html` | **唯一來源。要改就改這個。** |
| `plates.offline.html` | **產生的**，勿手改。零外部連線，`file://` 直接開 |
| `assets/mermaid.min.js` | 內嵌的繪圖函式庫（11.6.0，釘死版本） |
| `build.sh` | 由來源產生離線版 |

線上的 Artifact 也是從 `plates.src.html` 發布。**「同步」在這裡只有一個意思：
兩邊都由同一個檔案產生**，而且有測試檢查產生出來的那份仍帶著來源的每一張圖。
兩個手改的檔案一週內必定分岔，而分岔在有人並排比對之前完全看不出來——
這就是它是一支腳本而不是 README 裡一句叮嚀的理由。

## 為什麼要有離線版

兩個理由，第二個才是決定性的：

1. **需要網路才能開的簡報，就是不能保證開得起來的簡報**——火車上、醫院會議室、
   防火牆後面。
2. **唯一的副本在遠端。** 原始工作檔放在 session 的暫存目錄，隔天就沒了，
   線上那份是唯一倖存的副本。**唯一副本放在你控制不到的地方，那不是交付物，
   是一個書籤。**

所以現在 repo 是唯一來源。

## 線上與離線的三個差異（都由 build.sh 處理）

| | 線上 Artifact | 離線 |
|---|---|---|
| 繪圖 | host 原生渲染 `<pre class="mermaid">` | 載入內嵌的 `assets/mermaid.min.js` |
| 字體 | Google Fonts | 移除連結，改用系統字體堆疊 |
| 匯出 | 沙箱擋下載 | 有「匯出八張 SVG」按鈕 |

函式庫是**內嵌**不是現抓：一個需要網路才能產出離線成品的建置步驟，
在「網路正好是缺的那個東西」的那天就自我否定了。

## 三個只有真的用瀏覽器開才找得到的缺陷

第一版離線檔「看起來成功了」——八張圖都出現、沒有錯誤、console 乾淨。
實際上三個缺陷同時存在，**沒有一個是靜態檢查抓得到的**：

| 缺陷 | 症狀 | 真正原因 |
|---|---|---|
| `<br/>` 消失 | 標籤黏成一行「GitHub Actionsx86 雲端 runner」 | `<pre>` 裡的 `<br/>` 是**真的 HTML 元素**，`pre.textContent` 完全不回傳它，mermaid 根本沒看到換行 |
| 標籤互相影響 | 尺寸怪異 | 八個 `mermaid.render()` 並行，共用同一個離屏量測元件，互相量到對方的文字 |
| 標籤被裁掉 | 「Alertmanager」顯示成「Alertmanage」 | **`<pre>` 預設是等寬元素**。mermaid 在 `<body>` 上的暫存元件用 sans 量測，卻把 SVG 注入等寬的 `<pre>` 裡——同一個字串在渲染字體下比量測字體寬，於是溢出被裁 |

第三個是最值得記的：它讀起來像 mermaid 的排版 bug，其實是字體繼承問題。
找到它的方法是**把同一張圖分別放在 `.sheet` 裡面與外面渲染，然後比對**——
不是讀程式碼推出來的。

修法在 `build.sh` 裡有完整註解。守衛是 `platform/tests/test_offline_report.sh`。

## 測試能證明什麼、不能證明什麼

`test_offline_report.sh`（tier 1，14 項）證明：

- 零外部連線（不是「我們拿掉了明顯的那一個」）
- 函式庫用相對路徑載入（資料夾複製到別台機器仍可用）
- 上面三個修正沒有被誰悄悄還原
- 產生的那份帶著來源的每一張圖，**逐張比對內容**不是比對數量
- 來源少一張圖時，建置會**拒絕**而不是產出一份看起來完整的報告

**它不能證明圖畫得出來。** 那需要瀏覽器，2026-09-02 是人工用真的 Chrome 驗的
——上面三個缺陷就是那樣找到的。這件事明講，不假裝測試涵蓋了它。

## 改完之後

```bash
docs/report/build.sh                          # 重新產生離線版
bash platform/tests/test_offline_report.sh    # 守衛
# 線上版：用 plates.src.html 重新發布到同一個 artifact URL
```

`build.sh --check` 會在「已提交的離線版和來源產生出來的不一致」時回傳 rc 3，
CI 用得上。

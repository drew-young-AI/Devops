---
type: reference
title: 任何 AI CLI 接手這個 repo 的入口
description: "Vendor-neutral entry point for codex / copilot / agy / gemini / cursor. A thin pointer to docs/Session-Handover.md plus the rules that bind every agent, deliberately holding no state and no numbers of its own."
tags:
  - handover
  - onboarding
  - cross-agent
timestamp: 2026-09-05T00:00:00+08:00
---

# AGENTS.md — 任何 AI CLI 接手這個 repo 的入口

適用於 codex、copilot、agy、gemini、cursor、claude 等所有 agent。

**這份檔案是薄指標，不是內容。** 它刻意不複製任何說明與任何數字：
兩份索引就是一個分岔問題，而這個 repo 已經為此付過代價
（`docs/Reachability.md` 的失效形狀目錄有這一條）。

---

## 1. 先讀這一份，讀完再動作

**[`docs/Session-Handover.md`](docs/Session-Handover.md)**

它是接手路由，裡面有：開場要跑的指令、讀的順序、
會再遇到的坑、接手後**不要做**的事、以及只有使用者能做的項目。

不要用讀的推測狀態——**跑它第一節的指令**。這個 repo 的現況一律由指令產生，
手寫的現況會退化成信念（該檔開頭列了三個實例）。

## 2. 三條對所有 agent 都成立的硬規則

1. **不要 commit／push／開 PR，除非使用者明講。**
2. **待辦一律走 [`docs/Backlog.md`](docs/Backlog.md) §27 登記簿**，規則是「只登記，不實作」。
   例外：**修好既有東西的缺陷**不算新增範圍，可以直接做（判準見 §29）。
3. **用工具，不要堆自研程式。** 維護成本由使用者本人承擔。
   優先序：工具原生設定／查詢語言 → 工具原生測試機制 → 最後才是寫程式。
   說明在 `docs/Session-Handover.md`「三之三」。
4. **不得讀取、印出、複製或記錄任何 Secret 的值。** 可以用 Git 與 Secret
   Manager 的 metadata／action API（例如「這把金鑰存在、上次輪替是什麼時候」），
   但值本身不進對話、不進日誌、不進 evidence。
5. **正式環境的政策、不可逆的動作、發行核准，一律由真人決定。**

第 4、5 條 2026-09-09 從一份 2026-08-09 寫的安全決策範圍頁遷入，該頁同日刪除
（判準見 [ADR-0018](docs/decisions/0018-delete-a-document-only-when-an-adr-carries-its-reason.md)）。
它裡面是一張**全部沒打勾、而實際上早就做完**的 P0 檢查清單（Vault 已 unsealed、
機密已遷入、Gitleaks 每次測試都跑）。一份宣稱阻擋發行、而阻擋理由已經不存在的
清單，比沒有清單更糟。清單刪除，這兩條規則留下——**它們不是清單項目，是一直
成立的界線，而且原本躺在一份沒有 agent 會讀的檔案裡。**

## 3. 交付前的證據要求

這個 repo 只接受**可重跑的 deterministic 證據**：

- 測試套件的 pass/fail（指令在 Session-Handover 第一節）
- 新增或修改守衛時，要有**證明它會紅**的合成控制或突變
- 涉及告警規則時，**以評估驗收不是以解析**
  （`promtool check rules` 說 SUCCESS 而每次評估都失敗，這個 repo 發生過，
  見 `docs/decisions/0007-verify-by-evaluation.md`）
- 無法驗證時明確標記 `UNVERIFIED` 並說明原因，不要含糊帶過

## 4. 跨 AI 的共用知識

這個 repo 的教訓有一部分已抽成中立層記錄，任何 agent 都可取用：

```bash
/Users/drew/Apps/AIS/capabilities/scripts/context resolve --tags devops,platform --budget-bytes 8192
```

不要預載整個 knowledge tree，也不要把它當成本 repo 的現況來源——
**現況只有指令說了算。**

## 5. 這個 repo 真正的資產

工具會換掉，這三樣不會（`docs/Reachability.md`）：

1. **失效形狀目錄**——「登記為存在，但不執行」／「空集合上的恆真句」／
   「可達不等於還是真的」／「執行了，但沒有效果」／
   「監控系統被它沒有監控的東西弄停了」
2. **證據紀律**——每個數字都要有 provenance；估計值在表格裡和量測值長得一模一樣
3. **每個守衛都有證明它會紅的合成控制**——
   沒有被證明能失敗的守衛，和不能失敗的守衛，從輸出上分不出來

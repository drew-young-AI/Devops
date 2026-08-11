# Human Platform Usability Review — 走查清單

依 `docs/Pilot-Validation.md` 的定義，這項檢查「operator 能否理解 CI、
dashboard、evidence、rollback」——本質上必須是你本人操作過一次，AI 無法
代做。這份清單把「所有工具都輪詢過」具體化成可以逐項點擊確認的步驟。

**2026-08-11 產出前的準備工作**：在寫這份清單之前，我實際打開瀏覽器把
Grafana 和 GHCR 網頁介面都看過一次（不只是查 API）——**在 Grafana 這邊
發現一個真的壞掉的 bug**：`devops-overview.json` 這份 dashboard 定義檔
所有 panel 都缺少 `datasource` 欄位、`id` 也是 null，導致整個 dashboard
頁面完全空白，只有底層資料（Prometheus/Loki）是好的，畫面呈現是壞的。
已經修好並重新驗證過真的會顯示資料，見下面第 3 項。所以這份清單裡列的
每一項，都是我剛剛實際走過一遍確認會動的，不是憑印象寫的。

---

## 1. CI/CD — GitHub Actions（只涵蓋 IaC，不涵蓋 pilot，這是設計如此）

**去哪裡看**：https://github.com/drew-young-AI/Devops/actions

**怎麼點**：開啟連結 → 應該會看到「IaC Validation」這個 workflow 的執行
紀錄列表，最上面幾筆是綠色勾勾（成功）。點進任一筆 → 可以看到
`Terraform Format, Validate, and Security Scan`、`Additional Security
Scanning`、`Validation Summary` 三個 job，全部綠燈。

**你應該看到**：綠色勾勾，沒有紅色叉叉。

**重要提醒**：這個 CI **只會在 `platform/iac/**` 有變更時觸發**，
station1-hello 本身的建置/測試是跑在你的本機（`platform/ci/
run_local_ci.sh`），不會出現在 GitHub Actions 裡——這是設計上刻意的
分離，不是漏掉了。如果你在這裡找 station1-hello 的建置紀錄，會找不到，
這是正常的。

- [ ] 已確認：Actions 頁面看得到綠燈的 IaC Validation 紀錄

---

## 2. 本機 CI — station1-hello 的建置紀錄

**去哪裡看**：終端機，不是網頁

```bash
cd /Users/drew/ENV/Devops
platform/compose/deploy.sh build pilots/station1-hello
```

**你應該看到**：依序印出 `[1/4] lint / compile`、`[2/4] unit / contract
test`（3 個測試全部 `ok`）、`[3/4] container build`、`[4/4] artifact
metadata`，接著是 Trivy 安全掃描的 `[1/3]`、`[2/3]`、`[3/3]`，最後
`SCAN PASS` 和 `artifact=...` 開頭的幾行路徑。

- [ ] 已確認：本機 build 指令跑完沒有紅字錯誤，最後看到 `SCAN PASS`

---

## 3. Dashboard — Grafana（2026-08-11 剛修好，請務必檢查這項）

**去哪裡看**：http://127.0.0.1:13000

**怎麼點**：開啟連結 → 首頁通常是空的（正常，那是 Grafana 自己的
Home，不是我們的 dashboard）→ 點左上角 `Dashboards` → 點 `DevOps`
資料夾 → 點 `DevOps Overview`。

**你應該看到**：五個區塊都有實際數字/圖表，不是空白：
- **Station 1 Requests**：一個紅色數字（累積請求數，例如 582）
- **Station 1 Errors**：一個綠色的 0
- **Metrics Target Up**：綠色的 1（代表 Prometheus 有抓到 station1-hello）
- **Request Rate**：一條時間序列線圖
- **Container Logs**：捲得動的日誌列表，每行是一個 JSON，例如
  `{"event": "http_request", "message": "\"GET /health/ready HTTP/1.1\" 200 -"}`

**如果看到空白或「Loading plugin panel...」卡住不動**：代表修復沒有生效
或又壞了，回報給我，不要自己猜。

- [ ] 已確認：五個 panel 都有真實資料，沒有空白或卡住的

---

## 4. Registry — GHCR（GitHub Container Registry）

**去哪裡看**：https://github.com/users/drew-young-AI/packages/container/package/station1-hello

**怎麼點**：開啟連結即可，不需要額外點擊。需要登入 GitHub 帳號才看得到
（因為是 Private package）。

**你應該看到**：
- 頁面標題 `station1-hello`，旁邊有一個 `Private` 標籤
- 「Recent tagged image versions」列表，看得到幾組 tag（例如
  `d830501`、`b0c679a`，對應 git commit sha）
- 右側「Total downloads」有數字（不是 0）

- [ ] 已確認：package 存在、標記 Private、看得到至少一個 tag

---

## 5. Evidence — 稽核紀錄

**去哪裡看**：終端機

```bash
cd /Users/drew/ENV/Devops
ls evidence/station1-hello/
cat evidence/station1-hello/build_07c23ea.json
cat evidence/station1-hello/deploy_develop_6d37623.json
cat evidence/station1-hello/production_like_state.json
```

**你應該看到**：每個檔案都是一個小的、格式一致的 JSON，記錄了「什麼時候
建置了什麼版本」「部署到哪個環境」「目前 production-like 是哪個顏色在
服務」。这些檔案是每次 build/deploy/promote/push 自動產生的，不是手動寫的。

**看懂重點**：`production_like_state.json` 裡的 `active_color` 現在是
`"blue"`——代表目前 production-like 環境是 blue 這個容器在服務流量，
`previous_color` 是 `"green"` 但 green 已經被 teardown 掉了（下一項
rollback 會解釋這個狀態的意義）。

- [ ] 已確認：能打開至少 2-3 份 evidence JSON，內容看得懂欄位意思

---

## 6. Rollback — 真人確認 gate

**現況說明**：目前 `active_color=blue`，`previous_color=green`，但
green 容器已經被清掉了（之前測試時 teardown 掉的）。這代表**現在執行
rollback 會被系統正確拒絕**，因為沒有 green 可以切回去——這是設計上的
保護機制，不是 bug。

**怎麼觀察這個保護機制**（不會真的改動任何東西，只是示範被拒絕的畫面）：

```bash
cd /Users/drew/ENV/Devops
platform/compose/deploy.sh rollback pilots/station1-hello
```

**你應該看到**：
```
Previous color 'green' (project station1-hello-productionlike-green) is not running -- cannot roll back to it.
```
指令會直接失敗（exit 1），不會詢問你要不要繼續，因為根本沒有東西可以
切換。

**如果想看真正的 rollback 動作**（會實際啟動一個新容器，屬於有實際影響
的操作，建議你自己決定要不要做）：先 `promote`（會要求輸入 `PROMOTE`
確認）產生一個新的 green，再 `rollback`（會要求輸入 `ROLLBACK` 確認）
切回 blue。兩個指令都需要你手動打字確認，沒有 `--yes` 可以跳過。

- [ ] 已確認：理解 rollback 為什麼現在會被拒絕，也知道真正觸發 rollback
      需要打字確認、不會被自動化跳過

---

## 7. 安全掃描證據（Trivy / Gitleaks / Cosign）

**去哪裡看**：終端機

```bash
cd /Users/drew/ENV/Devops
cat evidence/station1-hello/trivy_summary_station1-hello_07c23ea.json
cat evidence/security/gitleaks_20260808T225110Z.json
```

**你應該看到**：Trivy 摘要裡 `gate_result` 是 `"PASS"`，
`fixable_critical_high_count` 是 `0`；Gitleaks 的檔案內容是空陣列
`[]`（代表全部 commit 掃描過，沒找到洩漏的 secret）。

- [ ] 已確認：兩份安全掃描證據都看得懂「通過」是什麼意思

---

## 完成後

七項都打勾之後，`docs/Pilot-Validation.md` 定義的
`HUMAN_PLATFORM_USABILITY_REVIEW` 這一關就算完成，可以回來跟我說，我會
把 `Plan.md` 對應的項目改成 `[x]`。如果任何一項卡住、看不懂、或跟這份
清單描述的不一樣，直接說是哪一項，不用自己想辦法解決。

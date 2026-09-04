---
type: explanation
title: 磁碟沒有被量——14 條告警規則、91 個能力、777 個綠燈，被一個沒人量的數字停掉
description: "The volume filled, Docker's engine died, and every layer of the monitoring went down with it. Nothing had referenced free space."
tags:
  - decision
  - observability
  - alerting
  - host
  - capacity
timestamp: 2026-09-03T00:00:00+08:00
decision:
  id: 14
  status: accepted
  date: 2026-09-03
  measured: true
  rerun: platform/tests/test_host_capacity.sh
  supersedes: []
---

# 0014 磁碟沒有被量——14 條告警規則、91 個能力、777 個綠燈，被一個沒人量的數字停掉

## 決定

**新增主機磁碟監控：一支跑在 macOS 上的匯出器（`platform/observability/host_disk_metrics.sh`），
三條告警規則（`alerts/host-capacity.yml`），以及一組證明規則會紅的合成控制。**

不使用 node-exporter 自己的 filesystem collector。理由在下面第三節，
那是這個決策裡唯一有技術內容的部分。

## 事故（2026-09-03）

| 時間 | 事件 |
|---|---|
| — | APFS 資料卷 `/System/Volumes/Data` 使用率達 100%，剩餘 133Mi |
| — | Prometheus 停止回應；`Bash` 與檔案寫入因 ENOSPC 失敗 |
| 11:23:30 | Docker 引擎關閉，所有容器 unregister |
| — | Docker Desktop UI 仍在，socket 仍接受連線，但背後沒有東西回答——每個 `docker` 指令掛住而不是快速失敗 |
| 06:30(UTC) | 強制重啟 Docker（graceful stop 逾時，backend PID 1045 不理會 TERM），引擎 114s 後回來；TSDB 無損毀 |

事故當下平台的狀態：14 條告警規則、91 個已登記能力（零孤兒）、777 個通過的斷言。
**沒有一條規則引用剩餘空間。**

失效形狀，加進目錄：**「監控系統被它沒有監控的東西弄停了」**。
這個形狀的特別之處在於它自我隱藏——資源耗盡會先殺掉負責報告資源耗盡的那個程序。

## 為什麼不用 node-exporter 的 filesystem collector

兩個各自獨立、任一個都足夠的理由：

1. **它是關的。** `compose.yaml` 以 `--collector.disable-defaults --collector.textfile`
   啟動 node-exporter，所以它唯一產出的就是 textfile 目錄裡的東西。
   `node_filesystem_avail_bytes` 在這座 Prometheus 裡**不存在**。
2. **打開它會量錯磁碟。** node-exporter 是 Linux 容器，在 macOS 上它跑在 Docker 的
   Linux VM 裡，`/proc` 描述的是 `Docker.raw` **內部**那顆 ext4，不是實際填滿的 APFS 卷。
   打開之後會得到一個關於「從來不是問題的那顆磁碟」的、很有信心的綠色數字——
   這比一個被承認的缺口更糟。

所以主機的數字必須**在主機上產生**，再從 textfile 通道遞進去——
和 `dag.py` 已經在用的機制相同，但獨立檔案、獨立排程，
讓 `dag.py` 掛掉時不會把磁碟指標一起帶走。

`service-health.yml` 的檔頭原本用「nothing collects those metrics yet
(no cAdvisor/node-exporter)」來解釋這個缺口。寫下時 node-exporter 已經跑了數週。
**結論碰巧還對，但它宣稱的理由早就不成立，而沒有人重讀。**
一個沒有標日期的「已承認缺口」會從決策退化成信念。該段已更正並標注日期。

## 量測

### Docker.raw：926G 是假警報

```
ls -lh  Docker.raw   926G     <- apparent（虛擬大小，等於整顆卷）
stat -f %b × 512     22.4GB   <- allocated（APFS 真正交出去的區塊）
```

差 44 倍。`ls` 那個數字從頭到尾沒動過，因為它與消耗量無關。
這與事故初期把 `df /`（唯讀封存系統卷 `/dev/disk3s1s1`）誤讀成資料卷是**同一類**錯誤：
一個技術上為真、但回答了另一個問題的數字。匯出器同時輸出兩個值，理由寫在腳本檔頭。

### Docker.raw 會不會縮：預期錯誤，實測推翻

「macOS 上的 Docker.raw 只增不減」這條規則被先寫進腳本註解，然後才實測
（Docker Desktop 4.84.0 / engine 29.6.2，Apple Silicon）：

| | allocated |
|---|---|
| 清理前 | 24.03 GB |
| VM 內回收 | ~2.7 GB（build cache 1.67GB、3 個 dangling image、1 個無引用的 424MB image） |
| 數分鐘後 | 22.49 GB（20.95 GiB），20 秒間隔連續三次取樣一致 |

**這個版本會 discard，主機檔案確實縮了約 1.4 GiB。**
舊規則對更舊的 Docker Desktop 仍然成立，但在這裡不成立。
如果保留原本的敘述，runbook 會告訴人「清理救不了主機磁碟」，
把人推向「重設磁碟映像」這條會摧毀所有 image 與 volume 的破壞性路徑。

### 規則能不能紅

`promtool check rules` 回報 SUCCESS 不構成證據——本 repo 已有它對
「每次評估都失敗的規則」回報 SUCCESS 的紀錄（0005）。
合成控制以 `promtool test rules` 餵入假序列，8 個案例，紅綠成對；
再以突變測試證明這組控制**本身能失敗**：

| 突變 | rc | 期望 |
|---|---|---|
| baseline | 0 | 0 |
| 門檻 0.10 → 0.01 | 1 | 非 0 |
| `for: 15m` → `0m` | 1 | 非 0 |
| 移除 `absent()` 子句 | 1 | 非 0 |
| 還原後 baseline | 0 | 0 |

故障全程以假序列模擬，**沒有真的填滿磁碟**——CLAUDE.md §5c 明確禁止
在這台主機上注入真實故障（「填滿磁碟」被點名），
何況要測的故障正好會殺掉執行測試的那個程序。

## 三條規則

| 規則 | 條件 | 嚴重度 |
|---|---|---|
| `HostDiskLow` | 剩餘 < 10%，持續 15m | warning |
| `HostDiskCritical` | 剩餘 < 4%，持續 5m | critical |
| `HostDiskMetricsStale` | 指標超過 30m 未更新，**或**從未出現 | warning |

### 「守衛的守衛」——這個遞迴在哪裡停

第三條原本是 `HostDiskMetricsStale`，看的是磁碟匯出器**自己寫的**時間戳。
**原則對，實作錯，2026-09-03 當天就改掉了。**

錯在三點：

1. **node-exporter 早就有了。** `node_textfile_mtime_seconds` 對 textfile 目錄裡
   每一個檔案都會輸出，而且是已經啟用的那個 collector 在做。自訂 gauge 是重複造輪子。
2. **mtime 是比較強的訊號。** 自訂 gauge 是腳本**對自己的宣稱**；時鐘錯了、
   或 `emit` 成功而 `mv` 失敗，它會繼續報一個新鮮的時間給一個根本沒落地的檔案。
   mtime 是檔案系統**觀察到**的，寫入者無法宣稱。
3. **它只守一個檔案。** 另外五個（dag、dataops、health_rollup、loki_coverage、
   dast_coverage）失效模式一模一樣，**一條規則都沒有**。
   其中 `dag.prom` 是平台自己的狀態板：它一凍結，板上每個節點會永遠停在最後狀態，
   而一塊凍結的綠燈是代價最高的謊。

現在是 `alerts/exporter-freshness.yml`，三條規則涵蓋六個檔案。

**遞迴停在哪裡，是一個性質不是一個約定。** 判準是：

> **這個檢查失敗的時候，是安靜地失敗，還是大聲地失敗？**

安靜失敗需要外部見證者；大聲失敗已經有人看見。

- 凍結的 `.prom` **安靜地**失敗：node-exporter 照樣供應舊檔，下游規則照樣評估，
  一個停止更新的值和一個穩定的值從下游完全分不出來。→ 需要守衛。
- 這條新規則**大聲地**失敗：它以 `time()` 為軸，而 `time()` 是 Prometheus 自己產的。
  Prometheus 停了，它不會安靜變綠，而是連同整組規則一起消失，
  `PlatformNodeFailed`、`ScrapeTargetDownProlonged` 與排程器自己的新鮮度探針
  都會從外部變紅。→ 不需要再一層。

**鏈長是二，不是無限。**

唯一還沒被涵蓋的縫是「新增一個 `.prom` 但沒人給它門檻」——
那被放在 `platform/tests/test_exporter_freshness.sh`，**不是第三條告警**。
理由同樣是性質：那是**組態的**性質，只在有人改檔案時變動，
測試正好在那個時刻執行、其餘時間成本為零；
寫成告警則是每 15 秒重算一個沒有變的答案。
**執行期的問題給告警，組態的問題給測試**——第二個環節是不同**種類**的檢查，所以鏈就停了。

### 一個當場被抓到的量測錯誤

第一版規則寫成 `file="host_disk.prom"`。實際 label 是 `/textfile/host_disk.prom`——
**是我自己的顯示指令用 `sed` 把前綴拿掉，我再照著那個被我改過的形式寫規則。**
它匹配不到任何序列，永遠不會燒。

抓到它的正是 `TextfileExporterMissing` 轉成 pending。
這與把 `ls -lh` 的 926G 當成佔用量是同一類錯誤：**為了好讀而做的轉換改變了答案。**

門檻表、運算式、`jobs.conf`、compose 的掛載點、實際寫出的檔案，
現在由 `exporter_freshness_check.py` 做五方交叉比對，任兩者不一致就紅。

### 原本第三條規則的說明（保留，因為問題本身沒變）

第三條是**守衛的守衛**，也是這個決策裡最重要的一條。
磁碟真的滿的時候，匯出器寫不出檔案，舊的 `.prom` 會留在原地繼續被抓取——
前兩條規則於是繼續評估一個「已經不再為真的舒服數字」，
在它們存在的理由發生的那一刻保持安靜的綠色。
`absent()` 在這裡救不了，因為序列還在；只有它的**年齡**會露餡。
`absent()` 子句管的是另一端：指標從未出現。
沒有它，前兩條規則就是**空集合上的恆真句**，
會在一個根本沒人量磁碟的平台上回報一切正常。

## Alertmanager 有沒有在貢獻

有，而且此刻正在。量測（2026-09-03 重啟後，計數器隨容器重啟歸零）：

- `alertmanager_notifications_total{integration="telegram"} 1`，failed 0
- 當下 firing：`ScrapeTargetDownProlonged`（`station2-twin-k8s` / 18091 抓不到）
- `amtool config routes test` 對 `HostDiskCritical`(critical) 與 `HostDiskLow`(warning)
  都解析到 `telegram`

email 整合在 binary 裡存在但送出 0 封：**live config 裡沒有 email receiver**。
template 有 `email_configs`，產生器在沒有 SMTP 憑證時把它整段拿掉，
所以那是憑證缺口，不是實作缺口（B4，待使用者提供 app password）。
`dag.py` 的 `probe_alertmanager` 現在會為此回報 WARN「宣告了但沒接上: email」。

## 根因在 2026-09-04 找到了，而且比這份紀錄低一層

這份紀錄說「一個沒人量的數字停掉了整個平台」，並補上量測。隔天那個告警要燒的時候，
去找消耗者，發現是**測試套件自己**：`make_sandbox` 把
`platform/backup/archives`（3.3GB）複製進每一個 sandbox，而清理從來沒有執行過
（註冊用的陣列是在命令替換的子 shell 裡被追加的）。
$TMPDIR 裡 124 個洩漏的 sandbox、421GB，累積視窗涵蓋這場停機。

清掉之後 95GiB → 516GiB。細節與三個疊在一起的缺陷見 docs/Backlog.md §25。

**這不會讓這份決策失效——磁碟本來就該被量，而且量到了就找出了根因。**
但它值得記在這裡：**這份紀錄蓋的洞，比它自己的成因高了一層。**
「沒有東西在量磁碟」是真的；「所以我們不知道為什麼會滿」也是真的；
而知道之後，答案是這座平台自己的測試。

## 這條鏈證不到什麼

- **逐則訊息對不上告警。** `HostDiskMetricsStale` 在真實資料上燒過並解除
  （launchd 首次觸發前指標確實超過 30 分鐘沒更新），telegram 計數器同步上升
  1 → 5、失敗 0。但 Alertmanager 只為**重試過**的通知寫 `Notify success` 日誌，
  一次就成功的不留紀錄，所以哪一則訊息對應哪一個告警要看使用者的 Telegram。
  `HostDiskLow` / `HostDiskCritical` 本身則從未在真實資料上燒過——磁碟一直健康。
- **門檻是推出來的，不是量出來的。** 10% / 4% 依據事故當天的填充速度選定，
  只有一次觀察。第二次事故才能說它是不是給得夠早。
- **只量一顆卷。** 外接磁碟、其他 APFS volume 都沒有涵蓋。
- **300s 的取樣週期是選的不是導出的。** 事故的填充歷時數小時，
  但沒有量過「最快可能多快」。

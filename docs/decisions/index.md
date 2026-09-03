# 決策紀錄索引

<!-- 這份是產生的，不要手動編輯：platform/docs/decisions.py -->

每一筆帶量測的決策**都必須附上重跑指令**，而那個指令必須指向存在的檔案——
`decisions.py` 會擋下不符合的。理由：三個月後真正的失敗不是「忘記決定什麼」，
是「找不到數字怎麼來的」，於是憑印象重估，而重估是穿著量測外衣的猜測。

| # | 決策 | 狀態 | 日期 | 可重跑 |
|---|---|---|---|---|
| 0001 | [分析查詢走 DuckDB + Parquet 鏡像，點查詢維持 Postgres](0001-analytical-mirror-duckdb.md) | 已採用 | 2026-08-27 | `platform/analytics/benchmark.sh` |
| 0002 | [Spark 範圍縮到串流語意一段，特徵與模型不遷移](0002-spark-scope.md) | 已採用 | 2026-08-28 | `platform/analytics/benchmark.sh` |
| 0003 | [Prometheus 開放區網，且明示接受它沒有認證](0003-prometheus-lan-exposure.md) | 已採用 | 2026-08-27 | `platform/tests/test_network_exposure.sh` |
| 0004 | [通知分成狀態與事件兩條路，不共用同一個機制](0004-notification-state-vs-event.md) | 已採用 | 2026-08-27 | — |
| 0005 | [DataOps 只監控約束看不見的三件事](0005-dataops-monitoring-scope.md) | 已採用 | 2026-08-28 | `platform/tests/test_dataops_metrics.sh` |
| 0006 | [不採用 headroom，也不自建等價壓縮](0006-context-compaction.md) | 已採用 | 2026-08-29 | `platform/docs/context_cost.sh` |
| 0007 | [規則與圖表以「能不能評估」驗收，不以「能不能解析」](0007-verify-by-evaluation.md) | 已採用 | 2026-08-29 | `platform/tests/test_dashboards.sh` |
| 0008 | [兩台機器兩種指令集：Mac 是 dev/SIT/UAT，Ubuntu 是 prod，映像檔在目標架構上建置](0008-two-machines-two-architectures.md) | 已採用 | 2026-08-31 | `platform/tests/test_image_arch.sh` |
| 0009 | [健康快照用彙總收斂，不用保留策略刪除](0009-health-rollup-not-retention.md) | 已採用 | 2026-09-01 | `platform/observability/rollup_health.py` |
| 0010 | [Kubernetes 從「未來 adapter」改為目標執行環境，發行版以 k3s 為先](0010-kubernetes-target-runtime-k3s.md) | 已採用 | 2026-09-02 | `platform/k8s/verify_cluster.sh` |
| 0011 | [不導入 ELK——那一格是 Loki 在填，不是 Prometheus](0011-loki-not-elk.md) | 已採用 | 2026-09-02 | `platform/observability/loki_coverage.py` |
| 0012 | [可觀測性：應用端一律 OTLP，後端選型延後——但「省事」的說法要拆開講](0012-otel-at-the-boundary-backend-deferred.md) | 已採用 | 2026-09-02 | `platform/observability/loki_coverage.py` |
| 0013 | [pilot 的資料迴路是開的——排程有 19 個 job，沒有一個抓資料](0013-pilot-loop-was-open.md) | 已採用 | 2026-09-03 | `platform/scheduler/status.sh` |

共 13 筆。

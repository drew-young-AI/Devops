# Pilot Services

目前 Pilot：`station1-hello`。

目前狀態：container validation、local CI baseline、Prometheus metrics、Grafana dashboard 與 Loki logs 已完成；develop auto-deploy、production-like promotion、blue/green、rollback 與 technical effect validation 尚未完成。

這裡放用來驗證 DevOps 平台的 POC、Pilot 與測試服務。

每個 Pilot 都可以有自己的：

- Dockerfile
- compose.yaml
- application code
- tests
- service-specific README

但必須遵守 [../NEW_SERVICE_GUIDE.md](../NEW_SERVICE_GUIDE.md) 的服務契約與安全基線。

Pilot 成功不代表產品成功，只代表平台能夠對該服務完成建置、測試、掃描、部署、監控與回滾驗證。

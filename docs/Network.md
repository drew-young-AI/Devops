---
type: explanation
title: 網路與公開存取邊界
description: "Network boundaries and the public-URL question: what may be exposed, what must never be, and the tunnel options considered."
tags:
  - network
  - security
  - ingress
timestamp: 2026-08-09T01:15:06+08:00
---
# Network Architecture

## Provider-neutral target

```text
Client
  -> DNS / CDN
  -> WAF / DDoS
  -> F5 or Cloud Load Balancer
  -> NGINX / Ingress
  -> Application
  -> Data / Queue / External API
```

## Local implementation

```text
localhost / app.local
  -> local HTTPS
  -> NGINX adapter
  -> Compose service
```

The local adapter validates routing, TLS, headers, health checks, timeout, rate limit and rollback semantics. It does not claim to provide real F5, CDN, DDoS or VPC isolation.

## Public URL experiment options

### Option A：快速臨時測試

```text
Cloudflare Quick Tunnel
  -> local NGINX
  -> Pilot
```

適合 webhook、短時間 demo 與快速確認外部 HTTP 交握。它依賴 Cloudflare hosted service，不是完整開源控制面；Quick Tunnel 也有測試用途限制，因此不能作為 production-like 結論。[Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/)

### Option B：推薦的企業網路縮小版

### 已由 Tailscale 取代（2026-08-17）

本節原本規劃 rathole relay + Cloud trial VM，並以 Cloudflare Tunnel 為替代
路徑。**兩者都不再需要。**

卡住的是一個錯誤前提，而不是一個缺少的決策：所有服務都綁 127.0.0.1，
Tailscale 跑在同一台主機上、直接可達 loopback。因此不必開 router port、
不必設 inbound 防火牆規則、不必申請雲端 VM、也不必有網域。

```text
Tailscale tailnet
  -> tailscale serve（tailnet only）／ funnel（公開網際網路）
  -> 127.0.0.1 上的本機服務
```

實作與暴露天花板見 [platform/ingress/README.md](../platform/ingress/README.md)。
每個目標的暴露上限依「靠什麼驗證」決定，而非依名稱敏感度：
prometheus / loki / alertmanager / vault 一律 `never`。

原 rathole / Cloudflare 段落已移除，因為保留一份不會被執行的計畫，
會讓讀者以為那是待辦事項。歷史決策見 `STAGE_REVIEW.md` §7。

### Public URL 安全邊界

- [ ] 只暴露 Pilot HTTP/HTTPS port，不暴露 Docker daemon、Grafana、Prometheus、Loki、Vault 或 MLX `127.0.0.1:9000`。
- [ ] Public VM firewall 只開 80/443 與 tunnel server 必要 port。
- [ ] NGINX 加 authentication、rate limit、request size、timeout 與 access log。
- [ ] Tunnel 使用 token、TLS、service allowlist 與固定 target。
- [ ] Public URL 實驗結束後停止 VM、撤銷 token、移除 DNS 與清理 firewall rule。
- [ ] Public URL experiment 不等於 production Internet exposure。

## Future components

DNS, route tables, security groups, firewalls, F5, CDN, WAF, VPC/VNet and Kubernetes NetworkPolicy will be expressed as provider-specific adapters over the same contract.

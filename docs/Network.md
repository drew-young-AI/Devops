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

```text
Public DNS
  -> Cloud trial VM with public IP
  -> NGINX + TLS
  -> rathole relay server
  -> MacBook rathole client
  -> local NGINX
  -> Pilot
```

這需要一台 Cloud trial VM，但 Cloud provider 不固定。VM 只作 relay，不承載 application；因此可以驗證 public IP、DNS、TLS、firewall、reverse proxy、tunnel、access log、timeout 與回收流程。

- `rathole`：本專案主方案。Rust 實作的輕量 reverse proxy，需一台有 public IP 的 server，支援 token、TLS 與 Noise。[rathole repository](https://github.com/rathole-org/rathole)
- `frp`：保留為替代方案，不在第一版同時安裝。它同樣可將 NAT/Firewall 後的 local service 暴露到 Internet，但必須配置 authentication 與 allowlist。[frp repository](https://github.com/fatedier/frp)

第一版固定採 `rathole`，藉此驗證跨語言 runtime、relay protocol、token、TLS、firewall 與 NGINX 交握。

### Optional Cloudflare adapter

Cloudflare Tunnel 可以作為另一條獨立的 edge path：

```text
Cloudflare DNS / WAF / CDN
  -> cloudflared CLI on Mac
  -> local NGINX
  -> Pilot
```

它適合驗證 CLI、DNS、edge TLS、WAF、CDN、Zero Trust policy 與快速外部 URL；但不應取代 rathole 主方案，因為 Cloudflare relay、control plane 與 edge network 是託管服務，不是本機可重建的開源元件。Cloudflare Tunnel 使用 outbound-only connection，不要求 origin 有 public IP。[Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/)

- [ ] Cloudflare path 與 rathole path 分開驗收，不混用結果。
- [ ] Cloudflare credential 使用獨立、最小權限 token，不使用個人全權限 token。
- [ ] Cloudflare URL 只指向 local NGINX，不直接指向 Docker socket、observability、Vault 或 MLX。
- [ ] Cloudflare Quick Tunnel 只作短期測試，不作 SLA、HA 或 production capacity 證據。

### Public URL 安全邊界

- [ ] 只暴露 Pilot HTTP/HTTPS port，不暴露 Docker daemon、Grafana、Prometheus、Loki、Vault 或 MLX `127.0.0.1:9000`。
- [ ] Public VM firewall 只開 80/443 與 tunnel server 必要 port。
- [ ] NGINX 加 authentication、rate limit、request size、timeout 與 access log。
- [ ] Tunnel 使用 token、TLS、service allowlist 與固定 target。
- [ ] Public URL 實驗結束後停止 VM、撤銷 token、移除 DNS 與清理 firewall rule。
- [ ] Public URL experiment 不等於 production Internet exposure。

## Future components

DNS, route tables, security groups, firewalls, F5, CDN, WAF, VPC/VNet and Kubernetes NetworkPolicy will be expressed as provider-specific adapters over the same contract.

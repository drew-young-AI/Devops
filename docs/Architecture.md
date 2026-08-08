# Architecture

## Control plane

```text
External GitHub Free / GitLab Free
  -> CI runner
  -> Registry
  -> Develop Compose
  -> Human approval
  -> Production-like Compose
  -> NGINX local HTTPS
  -> Grafana / Prometheus / Loki
```

## Execution boundary

- MacBook is a PoC host, not a production host.
- MLX `127.0.0.1:9000` is an automation actor endpoint, not an application deployment target.
- Pilot owns application code and Dockerfile.
- Platform owns reusable CI, security, network, observability and deployment contracts.
- Production-like is stopped by default to conserve resources.

## Future adapters

- Cloud provider adapter: intentionally unspecified.
- Kubernetes adapter: replace Compose deployment adapter only after the platform contract passes.
- F5/WAF/CDN: local NGINX simulation first, enterprise integration later.

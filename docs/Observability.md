# Observability

## Local stack

- Grafana: dashboard and alert entry point.
- Prometheus: metrics and time series.
- Loki: container logs.
- Alloy: Docker log collection.

## Required views

- Platform progress: pipeline, artifact, security gate, deploy and rollback status.
- Runtime health: up/down, CPU, memory, restart, latency, errors and disk.
- Pilot evidence: test result, image digest, logs, metrics and failure events.

Production later adds authentication, TLS, alert routing, retention and HA storage.

---
type: reference
title: station1-hello Pilot
description: "The first pilot service: endpoints, health contract, and graceful shutdown behaviour."
tags:
  - pilot
  - reference
timestamp: 2026-08-09T01:15:06+08:00
---
# Station 1: Minimal Hello World Container

This service validates the first container baseline without external dependencies.

## Endpoints

- `/` — hello response
- `/health/live` — process liveness
- `/health/ready` — readiness and graceful-drain state
- `/version` — service version

## Run

```sh
docker compose up --build
```

The service binds only to `127.0.0.1:18080` on the host.

---
type: checklist
title: Pilot 驗證項目
description: What a pilot service must demonstrate before it counts as validating the platform.
tags:
  - pilot
  - validation
timestamp: 2026-08-09T01:15:06+08:00
---
# Pilot Validation

```text
CREATED -> BUILT -> SECURITY_CHECKED -> DEPLOYED_DEVELOP
  -> TECHNICALLY_VERIFIED -> HUMAN_PLATFORM_USABILITY_REVIEW
  -> PRODUCTION_LIKE -> ROLLED_BACK / RETIRED
```

Technical checks include API, health, smoke, security, metrics, logs, failure and rollback.

Human Platform Usability Review checks whether the operator can understand CI, dashboards, evidence and rollback. It is not product PRD or product UX acceptance.

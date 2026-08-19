---
type: reference
title: 已退役 Pilot 的證據
description: "Why evidence from deleted services is kept but moved out of the probe globs."
tags:
  - evidence
  - retired
timestamp: 2026-08-19T09:10:00+08:00
---

# Retired pilots

Evidence from services that no longer exist. Kept because it is the audit
trail of work that was really done and really verified; moved out of the
top level because the platform's probes glob `evidence/*/…`, and a retired
pilot's last successful promote would otherwise keep reporting itself as
the platform's current deployment state.

- `station1-hello/` — the platform's first pilot, a stateless HTTP service.
  Retired 2026-08-19 once station2-twin took over as the reference workload.
  Its build, scan, SBOM, deploy and promote records are the evidence behind
  the pipeline claims in STAGE_REVIEW.md up to that date.

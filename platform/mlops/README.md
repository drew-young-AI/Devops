---
type: platform-adapter
title: MLOps 週期重訓與發布閘門
description: Weekly retraining with a publication gate that is currently, and correctly, refusing to publish.
tags:
  - mlops
  - model-gate
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/mlops — weekly retrain, and a gate that is allowed to say no

## Start here

```bash
platform/mlops/retrain.sh         # rebuild features, re-backtest, publish only if it qualifies
```

## Why weekly

The cadence comes from how fast the thing it watches can change. The source is
**weekly** surveillance data published with roughly a two-week lag. Retraining
daily would rebuild an identical feature set six days out of seven and write six
`model_run` rows differing only by timestamp — noise that makes the one real
weekly change harder to see.

## The gate is the valuable part

Publishing is not a separate decision made by a human afterwards. A model is
published only if it beats the incumbent on the backtest; otherwise the run
completes, records why, and publishes nothing.

**The gate is currently refusing to publish, and that is the correct outcome.**
The candidate loses to a persistence baseline (t+1 −12.31%, t+2 +0.32%). A gate
that has never said no is not a gate — it is a formality — so this state is
evidence the mechanism works, not evidence that MLOps is broken. It appears on
the board as `mgate: warn`, which is honest: the pipeline is healthy, the model
is not good enough.

## Known gaps

1. **No golden evaluation set.** Non-determinism is detectable today (the same
   `inputs_digest` producing different conclusions is a catchable failure), but
   **quality regression is not**: change the prompt or the features and nothing
   answers whether the result got better or worse.
2. **Cross-architecture numerics are unverified.** BLAS can differ in the last
   bits between arm64 and amd64. If a model is ever trained on the Mac and
   scored on the Ubuntu box, the gate's win/lose verdict could flip for reasons
   that have nothing to do with the model. Any determinism claim must record the
   architecture it was measured on.
3. `run.sh status` does not exist; only `retrain.sh` does. Read the `mgate` node
   on the board for current state.

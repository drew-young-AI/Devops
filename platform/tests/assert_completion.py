#!/usr/bin/env python3
"""Assert the stage report's completion block is usable as a target.

Kept as a file rather than a heredoc inside the suite: the suite is bash, the
assertions are Python, and a Python heredoc inside a bash heredoc inside an
editor is how the `say()`/`print()` recursion bug got written earlier in this
project's history.
"""
import json
import os
import sys

# A DIRECTORY HOLDING Stage-Report.json, not the repo root. The caller passes
# the suite's own --out-dir, because docs/Stage-Report.json is gitignored build
# output and does not exist in a fresh checkout.
out_dir = sys.argv[1]
doc = json.load(open(os.path.join(out_dir, "Stage-Report.json"),
                    encoding="utf-8"))
for line in doc["lines"]:
    c = line["completion"]
    assert c["denominator"] == "nodes", c
    assert c["nodes_total"] > 0, line["id"]
    assert 0 <= c["pct_strict"] <= 100, c
    # Crediting a retired node whose job moved to a live one can only raise the
    # figure; if it ever lowered it, the split has been computed backwards.
    assert c["pct_crediting_retired"] >= c["pct_strict"], c
    # The engineering-only ceiling: what this line would read if every
    # eng-owned blocker were closed and nothing else changed. It can never be
    # below the current figure (closing blockers cannot subtract), and never
    # above 100. When it sits below the landing standard, no amount of work
    # inside this repository reaches the standard -- and that is exactly the
    # sentence this field exists so nobody has to write by hand each round.
    ceiling = c["pct_ceiling_eng_only"]
    assert c["pct_strict"] <= ceiling <= 100, (line["id"], c["pct_strict"], ceiling)
    eng = c["blocking_by_owner"].get("eng", 0)
    expected = round(100.0 * (c["nodes_ok"] + eng) / c["nodes_total"], 1)
    assert abs(ceiling - expected) < 0.05, (line["id"], ceiling, expected)
    for b in c["blocking"]:
        assert b.get("owner"), (line["id"], b)
    print("%s %s%% ceiling=%s%% denom=%s blockers=%d" % (
        line["id"], c["pct_strict"], ceiling, c["denominator"], len(c["blocking"])))

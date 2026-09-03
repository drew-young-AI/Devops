#!/usr/bin/env python3
"""Print the metric names an alert rules file actually EVALUATES.

Read from the parsed `expr:` fields, one per line. Deliberately not a grep
over the file: the runbook annotations in these rules name the exporter script
(`host_disk_metrics.sh`), and a grep for `host_[a-z_]+` turns that filename
into a metric that nothing produces. The join it feeds would then fail on its
own false positive, which is how a real guard gets marked flaky and ignored.
"""
import re
import sys

import yaml

PATTERN = re.compile(r"[a-z][a-z0-9_]*_[a-z0-9_]+")
# PromQL keywords and functions are not metrics. Only the ones that can appear
# with an underscore are listed; a bare `rate` or `time` never matches PATTERN.
NOT_METRICS = {"group_left", "group_right", "on_", "ignoring_"}


def names(path, prefix=""):
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    found = set()
    for group in doc.get("groups", []) or []:
        for rule in group.get("rules", []) or []:
            expr = rule.get("expr", "") or ""
            for token in PATTERN.findall(expr):
                if token in NOT_METRICS:
                    continue
                if token.startswith(prefix):
                    found.add(token)
    return sorted(found)


if __name__ == "__main__":
    path = sys.argv[1]
    prefix = sys.argv[2] if len(sys.argv) > 2 else "host_"
    print("\n".join(names(path, prefix)))

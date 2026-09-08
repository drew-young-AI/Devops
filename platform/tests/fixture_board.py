#!/usr/bin/env python3
"""Emit a synthetic board with every node dag.py declares, all green.

Used by test_stage_report.sh so the rendering assertions do not have to probe
the live platform. That probe is real work -- Docker, Postgres, kubectl,
Prometheus, the scheduler -- and it was 110 seconds, 22% of the entire test
run, spent proving that three files get written.

The node list is READ from dag.NODES rather than typed here, which is the whole
point: a hand-written fixture would drift from dag.py and the coverage guard
this suite exists for (「dag.py 有而報告沒有的節點」) would then be checking the
fixture against itself.

Usage: fixture_board.py <out.json> [--stale SECONDS]
"""
import importlib.util
import json
import os
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DAG = os.path.join(HERE, "..", "statusdag", "dag.py")

spec = importlib.util.spec_from_file_location("dag", os.path.abspath(DAG))
dag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dag)

def make_board(stale=0):
    """A board with every node dag.py declares, all green. Importable, because
    the mutation harness in test_stage_report.sh needs the same object and a
    second copy of this list would be the drift this fixture exists to avoid."""
    when = datetime.now(timezone.utc) - timedelta(seconds=stale)
    return {
        "generated_at": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verdict": "OK",
        "counts": {},
        "edges": [list(e) for e in dag.EDGES],
        "nodes": [{"id": nid, "label": label, "layer": layer,
                   "state": dag.OK, "detail": "fixture", "impacted_by": []}
                  for (nid, label, layer, _probe) in dag.NODES],
    }


if __name__ == "__main__":
    out = sys.argv[1]
    stale = 0
    if "--stale" in sys.argv:
        stale = int(sys.argv[sys.argv.index("--stale") + 1])
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(make_board(stale), fh, ensure_ascii=False, indent=2)

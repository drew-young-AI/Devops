#!/usr/bin/env python3
"""Insert one deliberately broken registry entry into backtest.py.

Used only by test_model_registry.sh, which restores the file afterwards and
verifies the restore with cmp. Kept as a file rather than inlined in the suite
because a python heredoc nested inside a bash heredoc is how the quoting goes
wrong quietly.

The mutant returns an ALREADY FITTED estimator. That is the specific defect
check_buildable exists for, and the reason it needs a check at all: a fitted
object produces normal-looking scores computed with the test rows inside the
fit, so nothing downstream looks unusual.
"""
import sys

MUTANT = '''def _build_already_fitted(hp):
    import numpy as np
    from sklearn.linear_model import Ridge
    m = Ridge(**hp)
    m.fit(np.zeros((3, len(FEATURES))), np.zeros(3))
    return m


MODELS["MutantPreFitted"] = {
    "family": "mutation test",
    "build": _build_already_fitted,
    "hyperparams": {"alpha": 1.0},
    "handles_nan": False,
    "nan_policy": "none -- this entry exists only inside a mutation test",
    "deterministic": True,
}


'''

path = sys.argv[1]
src = open(path).read()
anchor = "def model_spec(name):"
if src.count(anchor) != 1:
    sys.exit(f"anchor {anchor!r} appears {src.count(anchor)} times in {path}; "
             f"refusing to mutate a file whose shape has changed")
open(path, "w").write(src.replace(anchor, MUTANT + anchor, 1))

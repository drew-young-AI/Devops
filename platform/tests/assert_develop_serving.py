"""probe_deploy('develop') must ask whether the copy is SERVING, not only whether it deployed."""
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag

# A deployment evidence file that says the deploy went fine. Everything the
# probe read before 2026-09-10 came from a document like this.
dag.load = lambda p: {"health_status": "healthy", "commit_sha": "abc1234"}
dag.glob.glob = lambda p: ["/fake/deploy_develop_1.json"]

cases = [
    ("SERVING",   (True, "HTTP 200"), '{"status": "ready", "schema_version": 18}'),
    ("MISMATCH",  (False, "HTTP 503"),
     '{"status": "schema_mismatch", "expected": 17, "actual": 18}'),
    ("ABSENT",    (False, "connection refused"), None),
]
for name, probe_result, body in cases:
    dag.http_probe = lambda url, timeout=6, _r=probe_result: _r
    dag._ready_body = lambda _b=body: _b
    state, detail = dag.probe_deploy("develop")
    print("%s %s | %s" % (name, state, detail))

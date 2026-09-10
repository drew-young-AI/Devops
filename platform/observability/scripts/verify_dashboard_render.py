#!/usr/bin/env python3
"""Ask Grafana itself whether each panel would draw something.

WHY THIS EXISTS, AND WHY IT IS NOT `dashboard_audit.py`.

`dashboard_audit.py` reads the JSON on disk and asks static questions: does
this metric name exist somewhere, is this datasource uid provisioned, does the
value mapping match dag.RANK. It never talks to Grafana. It would pass on a
Grafana that is refusing every login, holding a broken datasource credential,
or unable to reach Prometheus from inside its own container -- three failures
that produce a dashboard of empty panels and no error anywhere.

This script closes that gap by running every panel's query THROUGH Grafana's
datasource proxy (`/api/datasources/proxy/uid/<uid>/api/v1/query`), which is
the same path a rendered panel takes: Grafana authenticates the caller,
resolves the datasource uid, and reaches Prometheus over the container
network. A `curl` straight to `localhost:19090` proves none of those three.

WHAT AN EMPTY PANEL MEANS IS AMBIGUOUS ON PURPOSE. A panel with zero series
may be broken, or may be correctly reporting that nothing is firing. So this
reports counts and never exits non-zero for an empty result; it exits non-zero
only for the unambiguous failures -- Grafana refusing the request, the proxy
erroring, or a query Prometheus rejects as invalid.

Credentials come from platform/observability/.grafana.env (gitignored, sourced
from Vault). Nothing is printed from that file.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import base64

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
DASH_DIR = os.path.join(REPO_ROOT, "platform", "observability", "grafana",
                        "dashboards")
ENV_FILE = os.path.join(REPO_ROOT, "platform", "observability", ".grafana.env")
BASE = os.environ.get("GRAFANA_URL", "http://localhost:13000")


def credentials():
    user = os.environ.get("GF_SECURITY_ADMIN_USER")
    pwd = os.environ.get("GF_SECURITY_ADMIN_PASSWORD")
    if user and pwd:
        return user, pwd
    if not os.path.exists(ENV_FILE):
        print(f"FAIL  no credentials: set GF_SECURITY_ADMIN_USER/PASSWORD or "
              f"create {ENV_FILE} via "
              f"platform/observability/scripts/setup_grafana_identity.sh")
        sys.exit(78)
    got = {}
    with open(ENV_FILE, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            got[k.strip()] = v.strip().strip('"').strip("'")
    try:
        return got["GF_SECURITY_ADMIN_USER"], got["GF_SECURITY_ADMIN_PASSWORD"]
    except KeyError as exc:
        print(f"FAIL  {ENV_FILE} has no {exc}")
        sys.exit(78)


def call(path, user, pwd, timeout=20):
    req = urllib.request.Request(BASE + path)
    token = base64.b64encode(f"{user}:{pwd}".encode()).decode()
    req.add_header("Authorization", "Basic " + token)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def dashboards():
    for root, _dirs, files in os.walk(DASH_DIR):
        for f in sorted(files):
            if f.endswith(".json"):
                p = os.path.join(root, f)
                with open(p, encoding="utf-8") as fh:
                    yield os.path.relpath(p, DASH_DIR), json.load(fh)


def template_defaults(dash):
    """$project -> its current value; $target -> .* so the panel is unfiltered.

    A template variable left unsubstituted makes PromQL a syntax error, which
    would be reported as a broken panel when the panel is fine. `$__all` and
    multi-value variables become `.*`, matching what Grafana sends.
    """
    out = {}
    for v in dash.get("templating", {}).get("list", []):
        name = v.get("name")
        cur = (v.get("current") or {}).get("value")
        if isinstance(cur, list):
            cur = cur[0] if cur else "$__all"
        if cur in (None, "", "$__all") or v.get("includeAll"):
            out[name] = ".*"
        else:
            out[name] = str(cur)
    return out


def substitute(expr, values):
    for name, val in values.items():
        expr = expr.replace("${%s}" % name, val).replace("$" + name, val)
    # Any variable we did not know about would leave a `$` and break parsing.
    return expr


def panels(dash):
    for pan in dash.get("panels", []):
        title = pan.get("title", "(untitled)")
        for t in pan.get("targets", []):
            expr = t.get("expr")
            uid = ((t.get("datasource") or {}).get("uid")
                   or (pan.get("datasource") or {}).get("uid"))
            if expr and uid:
                yield title, uid, expr


def datasource_types(user, pwd):
    """uid -> type. A dashboard mixes Prometheus and Loki panels, and they do
    not share a query endpoint: sending PromQL to Loki's `/api/v1/query`
    returns a bare 404 with no hint that the caller used the wrong API. The
    first run of this script did exactly that and reported a healthy Loki panel
    as broken -- a verifier that cannot tell its own defect from the system's
    is worse than no verifier.
    """
    return {d["uid"]: d["type"] for d in call("/api/datasources", user, pwd)}


def query_path(uid, kind, query):
    if kind == "loki":
        # RANGE, not instant. Loki refuses a log selector as an instant query
        # ("log queries are not supported as an instant query type"), and a
        # log panel is exactly what this dashboard has. One minute of window is
        # enough to prove the path works without asking Loki to scan a day.
        now = int(time.time())
        return ("/api/datasources/proxy/uid/" + uid +
                "/loki/api/v1/query_range?query=" +
                urllib.parse.quote(query, safe="") +
                f"&start={(now - 60) * 10**9}&end={now * 10**9}&limit=1")
    return ("/api/datasources/proxy/uid/" + uid + "/api/v1/query?query=" +
            urllib.parse.quote(query, safe=""))


def main():
    user, pwd = credentials()
    try:
        health = call("/api/health", user, pwd)
    except urllib.error.HTTPError as exc:
        print(f"FAIL  Grafana refused the credential: HTTP {exc.code}. "
              f"The dashboards may be perfect and still show nothing.")
        return 1
    except urllib.error.URLError as exc:
        print(f"FAIL  Grafana unreachable at {BASE}: {exc.reason}")
        return 78
    print(f"grafana {health.get('version')} database={health.get('database')}")
    kinds = datasource_types(user, pwd)

    found = list(dashboards())
    if not found:
        print(f"FAIL  no dashboards under {DASH_DIR}. A verification that "
              f"checked nothing reports the same as one that checked "
              f"everything -- refusing.")
        return 1

    fails, empty, drew, checked = [], [], 0, 0
    for name, dash in found:
        values = template_defaults(dash)
        for title, uid, expr in panels(dash):
            query = substitute(expr, values)
            if "$" in query:
                fails.append(f"{name}: panel {title!r} still has an "
                             f"unsubstituted variable: {query}")
                continue
            checked += 1
            kind = kinds.get(uid, "prometheus")
            path = query_path(uid, kind, query)
            try:
                res = call(path, user, pwd)
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", "replace")[:200]
                fails.append(f"{name}: panel {title!r} -> HTTP {exc.code} "
                             f"through the Grafana proxy: {body}")
                continue
            if res.get("status") != "success":
                fails.append(f"{name}: panel {title!r} -> {res.get('error')}")
                continue
            n = len(res.get("data", {}).get("result", []))
            if n:
                drew += 1
            else:
                empty.append(f"{name}: {title!r} -> 0 series ({query[:70]})")

    for f in fails:
        print("  FAIL  " + f)
    for e in empty:
        print("  EMPTY " + e)
    print(f"{len(found)} dashboard(s), {checked} panel quer(ies) run through "
          f"Grafana's own datasource proxy: {drew} returned data, "
          f"{len(empty)} returned none, {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

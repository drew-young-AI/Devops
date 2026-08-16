#!/usr/bin/env python3
"""Pipeline status DAG -- traffic lights on the platform's own mechanisms.

This answers a different question from the value stream board, and confusing
the two is easy:

    board.py   "where is my work?"          nodes are commits
    dag.py     "what is broken right now,   nodes are mechanisms
                and what does it take down
                with it?"

The thing only a DAG can express is BLAST RADIUS. Vault sits upstream of
identity, CI credentials, the Grafana admin login and the audit trail; a flat
status list shows four green rows and one red one, and says nothing about the
fact that the red one is the reason. Here, a failed node marks everything
downstream of it as IMPACTED, so the structure carries the consequence.

Same derivation discipline as everything else in this platform: every light
comes from evidence already on disk or a live probe. Nothing is
hand-maintained, so the diagram cannot drift from the system it describes.

Three states are deliberately distinct:
    ok        verified working
    warn      degraded, or a verdict too old to trust
    fail      verified broken
    unknown   could not determine  <-- NOT green

The last one is the whole point. A check that could not run is not a passing
check, and every previous component in this platform had to learn that the
hard way (see check_health.sh's exit 3).

Usage:
  dag.py [--json] [--out <path.html>]
"""

import argparse
import glob
import json
import os
import shutil
import subprocess
import urllib.error
import urllib.request
from datetime import datetime, timezone

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
EVIDENCE = os.path.join(REPO_ROOT, "evidence")

OK, WARN, FAIL, UNKNOWN = "ok", "warn", "fail", "unknown"
RANK = {OK: 0, WARN: 1, UNKNOWN: 2, FAIL: 3}


# --------------------------------------------------------------------------
# Probes. Each returns (state, detail).
# --------------------------------------------------------------------------

def newest(pattern):
    files = sorted(glob.glob(os.path.join(EVIDENCE, pattern)))
    return files[-1] if files else None


def load(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def age_hours(stamp, fmt="%Y%m%dT%H%M%SZ"):
    try:
        when = datetime.strptime(stamp, fmt).replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - when).total_seconds() / 3600
    except (ValueError, TypeError):
        return None


def http_probe(url, timeout=6):
    """Returns (ok, detail). Certificate validation is off: the local vhosts
    use mkcert, and this probe is asking 'is it answering', not 'is the chain
    trusted' -- which the DAST scan covers properly."""
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(url, timeout=timeout, context=ctx) as r:
            return r.status < 400, f"HTTP {r.status}"
    except urllib.error.HTTPError as e:
        return e.code < 400, f"HTTP {e.code}"
    except Exception as e:  # noqa: BLE001 - any failure is "not answering"
        return False, str(e)[:60]


def run(cmd, timeout=25):
    try:
        p = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (subprocess.TimeoutExpired, OSError) as e:
        return None, str(e)[:60]


def probe_docker(name):
    rc, out = run(["docker", "inspect", "--format",
                   "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}",
                   name], timeout=15)
    if rc != 0:
        return UNKNOWN, "container not found"
    status, health = (out.strip().split("|") + ["none"])[:2]
    if status != "running":
        return FAIL, f"container {status}"
    if health == "unhealthy":
        return FAIL, "healthcheck unhealthy"
    if health in ("starting",):
        return WARN, "healthcheck starting"
    return OK, f"running ({health})"


def probe_vault():
    rc, out = run(["docker", "exec", "-e", "VAULT_ADDR=http://127.0.0.1:8200",
                   "vault-vault-1", "vault", "status", "-format=json"], timeout=20)
    if not out:
        return UNKNOWN, "unreachable"
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return UNKNOWN, "unparseable status"
    if data.get("sealed"):
        # Sealed Vault is not "degraded" -- nothing that needs a secret works.
        return FAIL, "SEALED -- needs manual unseal"
    return OK, "unsealed"


def probe_audit():
    rc, out = run(["docker", "exec", "vault-vault-1", "sh", "-c",
                   "wc -c < /vault/logs/audit.log"], timeout=20)
    if rc != 0:
        return UNKNOWN, "cannot read audit log"
    try:
        size = int(out.strip())
    except ValueError:
        return UNKNOWN, "unreadable size"
    mb = size / 1024 / 1024
    if mb > 100:
        # Vault is fail-closed on audit writes: an unbounded log is a pending
        # outage, not a tidiness problem.
        return WARN, f"{mb:.0f} MB -- rotate (Vault is fail-closed)"
    return OK, f"{size / 1024:.0f} KB"


def probe_scheduler():
    rc, out = run([os.path.join(REPO_ROOT, "platform/scheduler/status.sh"), "--json"],
                  timeout=30)
    if rc is None:
        return UNKNOWN, "status check did not complete"
    try:
        data = json.loads(out)
    except (json.JSONDecodeError, TypeError):
        return UNKNOWN, "unparseable"
    stale = [j["job"] for j in data.get("jobs", []) if not j.get("fresh")]
    if stale:
        return FAIL, f"not running: {', '.join(stale)}"
    bad = [j["job"] for j in data.get("jobs", [])
           if j.get("status") in ("failed", "critical", "timeout")]
    if bad:
        return WARN, f"failing: {', '.join(bad)}"
    # `late` must surface here too, or the DAG shows a green light while
    # status.sh exits 1 -- two views of one system disagreeing is exactly the
    # drift both are supposed to prevent.
    late = [j["job"] for j in data.get("jobs", []) if j.get("late")]
    if late:
        return WARN, f"late: {', '.join(late)}"
    return OK, f"{len(data.get('jobs', []))} jobs fresh"


def probe_gate(pattern, result_key="gate_result", stale_hours=48, stamp_key=None):
    """SAST / DAST / Trivy style summaries: verdict plus an age check.

    Age matters as much as verdict. A PASS from last week says nothing about
    what is deployed now, so a stale pass is WARN, never OK."""
    path = newest(pattern)
    data = load(path)
    if not data:
        return UNKNOWN, "no evidence"
    verdict = data.get(result_key)
    stamp = data.get(stamp_key) if stamp_key else os.path.basename(path)
    hours = None
    if stamp_key and stamp:
        hours = age_hours(stamp)
    else:
        parts = os.path.basename(path).replace(".json", "").split("_")
        hours = age_hours(parts[-1]) if parts else None
    label = f"{verdict}" + (f", {hours:.0f}h ago" if hours is not None else "")
    if verdict not in ("PASS", "ok"):
        return FAIL, label
    if hours is not None and hours > stale_hours:
        return WARN, f"{label} -- stale"
    return OK, label


def probe_gitleaks():
    """Gitleaks writes a JSON ARRAY, and an empty array means 'no leaks' --
    i.e. the success case. Feeding that through the generic gate probe read
    `[]` as falsy and reported 'no evidence', turning a clean scan into an
    unknown. Success that looks like absence is the recurring bug in this
    codebase; here it gets its own probe rather than a shared one that has to
    guess the shape."""
    path = newest("security/gitleaks_*.json")
    if not path:
        return UNKNOWN, "never scanned"
    try:
        with open(path, encoding="utf-8") as fh:
            findings = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return UNKNOWN, "unreadable report"
    hours = age_hours(os.path.basename(path).replace("gitleaks_", "").replace(".json", ""))
    age = f", {hours / 24:.0f}d ago" if hours else ""
    if isinstance(findings, list) and findings:
        return FAIL, f"{len(findings)} leak(s) found"
    if hours is not None and hours > 24 * 30:
        return WARN, f"no leaks{age} -- stale"
    return OK, f"no leaks{age}"


def probe_llm_review():
    """The review's own contract: `status` is OK/DEGRADED_*, and `verdict` is
    advisory only. A FAIL verdict must NOT light this red -- that would
    reintroduce, in the status view, exactly the blocking authority that
    NEW_SERVICE_GUIDE.md section 8 denies the LLM."""
    path = newest("*/llm_review_*.json")
    data = load(path)
    if not data:
        return UNKNOWN, "no review"
    hours = age_hours(os.path.basename(path).replace(".json", "").split("_")[-1])
    age = f", {hours:.0f}h ago" if hours is not None else ""
    if data.get("status") != "OK":
        return WARN, f"{data.get('status')}{age}"
    verdict = data.get("verdict")
    if hours is not None and hours > 24 * 3:
        return WARN, f"verdict {verdict}{age} -- stale"
    return OK, f"verdict {verdict}{age}"


def probe_backup():
    archives = sorted(glob.glob(os.path.join(
        REPO_ROOT, "platform/backup/archives/*/manifest.json")))
    if not archives:
        return UNKNOWN, "no backup found"
    stamp = os.path.basename(os.path.dirname(archives[-1]))
    hours = age_hours(stamp)
    if hours is None:
        return UNKNOWN, "unreadable timestamp"
    if hours > 48:
        return WARN, f"last backup {hours / 24:.1f}d ago"
    return OK, f"{hours:.0f}h ago"


def probe_restore_drill():
    state = load(os.path.join(EVIDENCE, "scheduler/restore_last.json"))
    if not state:
        return UNKNOWN, "never drilled"
    hours = age_hours(state.get("started_at", ""), "%Y-%m-%dT%H:%M:%SZ")
    if state.get("status") != "ok":
        return FAIL, f"drill {state.get('status')}"
    # A backup that has not been restored recently is a claim, not a capability.
    if hours is not None and hours > 24 * 10:
        return WARN, f"passed but {hours / 24:.0f}d ago"
    return OK, f"passed {hours / 24:.1f}d ago" if hours else "passed"


def probe_deploy(env):
    if env == "develop":
        files = sorted(glob.glob(os.path.join(
            EVIDENCE, "*/deploy_develop_*.json")))
        data = load(files[-1]) if files else None
        if not data:
            return UNKNOWN, "no deploy evidence"
        if data.get("health_status") != "healthy":
            return FAIL, f"health={data.get('health_status')}"
        return OK, f"sha {data.get('commit_sha', '?')}"
    state = load(os.path.join(EVIDENCE, "station1-hello/production_like_state.json"))
    if not state:
        return UNKNOWN, "never promoted"
    return OK, f"{state.get('active_color')} @ sha {state.get('promoted_sha', '?')}"


def probe_ci():
    files = sorted(glob.glob(os.path.join(EVIDENCE, "*/build_*.json")))
    data = load(files[-1]) if files else None
    if not data:
        return UNKNOWN, "no build evidence"
    return OK, f"sha {data.get('commit_sha', '?')[:7]}"


def probe_registry():
    files = sorted(glob.glob(os.path.join(EVIDENCE, "*/push_*.json")))
    if not files:
        return UNKNOWN, "nothing pushed"
    data = load(files[-1]) or {}
    hours = age_hours(os.path.basename(files[-1]).split("_")[-1].replace(".json", ""))
    return OK, f"{data.get('registry_image', 'pushed')}".split("/")[-1][:28]


def probe_alertmanager():
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:19093/api/v2/alerts?active=true", timeout=6) as r:
            alerts = json.load(r)
    except Exception as e:  # noqa: BLE001
        return UNKNOWN, f"unreachable: {str(e)[:40]}"
    crit = [a for a in alerts if a["labels"].get("severity") == "critical"]
    if crit:
        return FAIL, f"{len(crit)} critical firing"
    if alerts:
        return WARN, f"{len(alerts)} alert(s) firing"
    return OK, "no active alerts"


def probe_human_gate():
    """The promote gate is not a service and cannot be 'down'. It is shown so
    the DAG matches the real flow -- and so the one deliberately manual step
    is visible as manual rather than looking like a missing automation."""
    return OK, "manual by design"


# --------------------------------------------------------------------------
# The graph. Edges are real dependencies, not drawing conveniences.
# --------------------------------------------------------------------------

NODES = [
    # id,          label,               layer,          probe
    ("vault",      "Vault 機密/身分",     "foundation",  probe_vault),
    ("audit",      "稽核軌跡",            "foundation",  probe_audit),
    ("scheduler",  "排程器",              "foundation",  probe_scheduler),
    ("backup",     "備份",                "foundation",  probe_backup),
    ("restore",    "還原演練",            "foundation",  probe_restore_drill),

    ("sast",       "SAST 原始碼",         "source",      lambda: probe_gate("security/sast_summary_*.json", stale_hours=24 * 8)),
    ("secrets",    "Secret 歷史掃描",     "source",      probe_gitleaks),

    ("ci",         "CI 建置",             "build",       probe_ci),
    ("trivy",      "映像漏洞掃描",         "build",       lambda: probe_gate("*/trivy_summary_*.json", stale_hours=24 * 30)),
    ("registry",   "Registry 推送",       "build",       probe_registry),

    ("develop",    "develop 部署",        "deploy",      lambda: probe_deploy("develop")),
    ("dast",       "DAST 執行中系統",      "verify",      lambda: probe_gate("security/dast_summary_*.json", stale_hours=48)),
    ("llmreview",  "LLM 複審",            "verify",      probe_llm_review),
    ("gate",       "真人 PROMOTE",        "gate",        probe_human_gate),
    ("prodlike",   "production-like",     "release",     lambda: probe_deploy("production-like")),
    ("nginx",      "NGINX 入口",          "release",     lambda: probe_docker("nginx-nginx-1")),

    ("prometheus", "Prometheus 指標",     "observe",     lambda: probe_docker("observability-prometheus-1")),
    ("loki",       "Loki 日誌",           "observe",     lambda: probe_docker("observability-loki-1")),
    ("alertmgr",   "Alertmanager 告警",   "observe",     probe_alertmanager),
    ("grafana",    "Grafana 檢視",        "observe",     lambda: probe_docker("observability-grafana-1")),
]

# (from, to) -- "to depends on from".
EDGES = [
    ("vault", "audit"),
    ("vault", "ci"),          # CI reads the GHCR credential from Vault
    ("vault", "grafana"),     # Grafana's admin credential is sourced from Vault
    ("scheduler", "backup"),
    ("scheduler", "dast"),
    ("scheduler", "sast"),
    ("backup", "restore"),

    ("sast", "ci"),
    ("secrets", "ci"),
    ("ci", "trivy"),
    ("trivy", "registry"),
    ("ci", "develop"),
    ("develop", "dast"),
    ("develop", "llmreview"),
    ("dast", "gate"),
    ("llmreview", "gate"),
    ("gate", "prodlike"),
    ("prodlike", "nginx"),

    ("develop", "prometheus"),
    ("prodlike", "prometheus"),
    ("prometheus", "alertmgr"),
    ("loki", "grafana"),
    ("prometheus", "grafana"),
    ("alertmgr", "grafana"),
]

LAYERS = [
    ("foundation", "基礎（橫切）"),
    ("source", "原始碼"),
    ("build", "建置"),
    ("deploy", "部署"),
    ("verify", "驗證"),
    ("gate", "人工關卡"),
    ("release", "上線"),
    ("observe", "觀測"),
]


def build():
    results = {}
    for node_id, label, layer, probe in NODES:
        try:
            state, detail = probe()
        except Exception as e:  # noqa: BLE001
            # A probe that raises must not take the whole diagram down, and
            # must not silently render green.
            state, detail = UNKNOWN, f"probe error: {str(e)[:50]}"
        results[node_id] = {"id": node_id, "label": label, "layer": layer,
                            "state": state, "detail": detail, "impacted_by": []}

    # Blast radius: propagate from every failed node to everything downstream.
    # A node that is itself fine but sits under a failure is marked IMPACTED --
    # a distinct thing from being broken, and the reason a DAG beats a list.
    downstream = {}
    for src, dst in EDGES:
        downstream.setdefault(src, []).append(dst)

    for node_id, node in results.items():
        if node["state"] != FAIL:
            continue
        seen, stack = set(), list(downstream.get(node_id, []))
        while stack:
            nxt = stack.pop()
            if nxt in seen:
                continue
            seen.add(nxt)
            if results[nxt]["state"] != FAIL:
                results[nxt]["impacted_by"].append(node_id)
            stack.extend(downstream.get(nxt, []))

    worst = max((RANK[n["state"]] for n in results.values()), default=0)
    verdict = {0: "ALL_GREEN", 1: "DEGRADED", 2: "UNKNOWN", 3: "FAILED"}[worst]

    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verdict": verdict,
        "nodes": list(results.values()),
        "edges": EDGES,
        "counts": {s: sum(1 for n in results.values() if n["state"] == s)
                   for s in (OK, WARN, FAIL, UNKNOWN)},
    }


# --------------------------------------------------------------------------
# Render. Mermaid for the graph itself -- it auto-routes edges, which removes
# the entire class of overlap bugs that hand-placed diagrams keep producing.
# --------------------------------------------------------------------------

def esc(text):
    return (str(text if text is not None else "")
            .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def mermaid(board):
    by_id = {n["id"]: n for n in board["nodes"]}
    lines = ["flowchart LR"]
    for layer_id, layer_label in LAYERS:
        members = [n for n in board["nodes"] if n["layer"] == layer_id]
        if not members:
            continue
        # Prefixed so a layer id can never collide with a node id. The
        # "gate" layer contains a node also called "gate", and mermaid treats
        # both as the same identifier -- the subgraph swallows the node and
        # the diagram renders wrong with no error anywhere.
        lines.append(f'  subgraph layer_{layer_id}["{layer_label}"]')
        lines.append("    direction TB")
        for n in members:
            # Mermaid node text cannot contain quotes or parens unescaped.
            label = n["label"].replace('"', "'")
            detail = n["detail"].replace('"', "'").replace("(", "").replace(")", "")
            lines.append(f'    {n["id"]}["{label}<br/><small>{detail[:34]}</small>"]')
        lines.append("  end")
    for src, dst in board["edges"]:
        if src in by_id and dst in by_id:
            lines.append(f"  {src} --> {dst}")
    for n in board["nodes"]:
        cls = n["state"]
        if n["state"] != FAIL and n["impacted_by"]:
            cls = "impacted"
        lines.append(f'  class {n["id"]} {cls};')
    lines += [
        "  classDef ok fill:#E1EFE6,stroke:#2F7D4F,stroke-width:1px,color:#16202B;",
        "  classDef warn fill:#F7EEDA,stroke:#B07A16,stroke-width:1px,color:#16202B;",
        "  classDef fail fill:#F5E4E4,stroke:#A03C3C,stroke-width:2px,color:#16202B;",
        "  classDef unknown fill:#EFF2F4,stroke:#8794A1,stroke-width:1px,color:#16202B,stroke-dasharray:4 3;",
        "  classDef impacted fill:#FFFFFF,stroke:#A03C3C,stroke-width:1px,color:#16202B,stroke-dasharray:2 3;",
    ]
    return "\n".join(lines)


STATE_LABEL = {OK: "正常", WARN: "注意", FAIL: "失敗", UNKNOWN: "無法判定"}


def render_html(board):
    counts = board["counts"]
    rows = []
    for layer_id, layer_label in LAYERS:
        for n in [x for x in board["nodes"] if x["layer"] == layer_id]:
            impacted = ""
            if n["state"] != FAIL and n["impacted_by"]:
                impacted = (f'<span class="imp">受 {esc(", ".join(n["impacted_by"]))} '
                            f'影響</span>')
            rows.append(
                f'<tr><td><span class="dot d-{n["state"]}"></span>'
                f'{esc(STATE_LABEL[n["state"]])}</td>'
                f'<td>{esc(n["label"])}{impacted}</td>'
                f'<td class="mono">{esc(layer_label)}</td>'
                f'<td class="mono det">{esc(n["detail"])}</td></tr>')

    failed = [n for n in board["nodes"] if n["state"] == FAIL]
    unknown = [n for n in board["nodes"] if n["state"] == UNKNOWN]
    banner = ""
    if failed:
        names = "、".join(esc(n["label"]) for n in failed)
        impacted = sorted({n["label"] for n in board["nodes"]
                           if n["state"] != FAIL and n["impacted_by"]})
        extra = (f"　連帶影響：{esc('、'.join(impacted))}" if impacted else "")
        banner = (f'<div class="banner bad"><b>失敗：</b>{names}。{extra}</div>')
    elif unknown:
        names = "、".join(esc(n["label"]) for n in unknown)
        banner = (f'<div class="banner warn"><b>無法判定：</b>{names}。'
                  f'無法判定<em>不等於</em>正常——是檢查沒跑成功。</div>')

    return f"""<title>DevOps 管線燈號</title>
<style>
:root{{--ground:#F7F8F9;--surface:#FFFFFF;--sunk:#EFF2F4;--ink:#16202B;
 --muted:#5A6875;--faint:#8794A1;--rule:#DDE3E8;--accent:#0F6E6B;
 --ok:#2F7D4F;--ok-s:#E1EFE6;--warn:#B07A16;--warn-s:#F7EEDA;
 --bad:#A03C3C;--bad-s:#F5E4E4;--unk:#8794A1;--unk-s:#EFF2F4}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{
 --ground:#10161C;--surface:#171F27;--sunk:#1E2831;--ink:#E3E9EE;
 --muted:#9AA8B4;--faint:#6E7D8A;--rule:#2A353F;--accent:#4FB3AF;
 --ok:#6BBF8B;--ok-s:#17301F;--warn:#D9A945;--warn-s:#302711;
 --bad:#D97676;--bad-s:#331B1B;--unk:#6E7D8A;--unk-s:#1E2831}}}}
:root[data-theme="dark"]{{--ground:#10161C;--surface:#171F27;--sunk:#1E2831;
 --ink:#E3E9EE;--muted:#9AA8B4;--faint:#6E7D8A;--rule:#2A353F;--accent:#4FB3AF;
 --ok:#6BBF8B;--ok-s:#17301F;--warn:#D9A945;--warn-s:#302711;
 --bad:#D97676;--bad-s:#331B1B;--unk:#6E7D8A;--unk-s:#1E2831}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--ground);color:var(--ink);line-height:1.6;
 font-family:-apple-system,BlinkMacSystemFont,"Noto Sans TC","PingFang TC",sans-serif;
 -webkit-font-smoothing:antialiased}}
.wrap{{max-width:1200px;margin:0 auto;padding:40px 24px 72px}}
.eyebrow{{font-family:ui-monospace,Menlo,monospace;font-size:11px;letter-spacing:.14em;
 text-transform:uppercase;color:var(--accent);margin:0 0 10px}}
h1{{font-size:clamp(26px,3.4vw,36px);font-weight:800;letter-spacing:-.025em;margin:0 0 10px}}
.lede{{color:var(--muted);max-width:66ch;margin:0 0 20px;font-size:15.5px}}
.strip{{display:flex;flex-wrap:wrap;gap:10px;padding:14px 0;border-top:1px solid var(--rule);
 border-bottom:1px solid var(--rule);font-family:ui-monospace,Menlo,monospace;font-size:12.5px}}
.pill{{padding:3px 11px;border-radius:2px;font-weight:700}}
.p-ok{{background:var(--ok-s);color:var(--ok)}}
.p-warn{{background:var(--warn-s);color:var(--warn)}}
.p-bad{{background:var(--bad-s);color:var(--bad)}}
.p-unk{{background:var(--unk-s);color:var(--unk)}}
.ts{{margin-left:auto;color:var(--faint)}}
.banner{{margin:20px 0 0;padding:13px 18px;border-left:3px solid var(--bad);
 background:var(--bad-s);font-size:14.5px;border-radius:0 3px 3px 0}}
.banner.warn{{border-left-color:var(--warn);background:var(--warn-s)}}
.graph{{margin:26px 0 0;padding:18px;background:var(--surface);border:1px solid var(--rule);
 border-radius:3px;overflow-x:auto}}
h2{{font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;
 color:var(--muted);margin:34px 0 12px;padding-bottom:9px;border-bottom:2px solid var(--rule)}}
table{{width:100%;border-collapse:collapse;font-size:14px;min-width:640px}}
.tw{{overflow-x:auto}}
th{{text-align:left;font-size:10.5px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;
 color:var(--faint);padding:0 12px 8px 0;border-bottom:1px solid var(--rule)}}
td{{padding:9px 12px 9px 0;border-bottom:1px solid var(--rule);vertical-align:top}}
.mono{{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:var(--muted)}}
.det{{color:var(--faint)}}
.dot{{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px}}
.d-ok{{background:var(--ok)}} .d-warn{{background:var(--warn)}}
.d-fail{{background:var(--bad)}} .d-unknown{{background:var(--unk);
 box-shadow:inset 0 0 0 1px var(--faint)}}
.imp{{display:inline-block;margin-left:8px;padding:1px 7px;border-radius:2px;
 font-size:11px;font-family:ui-monospace,Menlo,monospace;
 background:var(--bad-s);color:var(--bad)}}
footer{{margin-top:40px;padding-top:18px;border-top:1px solid var(--rule);
 font-size:13px;color:var(--faint)}}
a{{color:var(--accent)}}
</style>
<div class="wrap">
<p class="eyebrow">平台燈號 · 衍生自實際探測</p>
<h1>DevOps 管線燈號</h1>
<p class="lede">節點是<strong>平台機制本身</strong>，不是工作項目。連線是真實依賴，
所以一個節點失敗時，下游會被標為<strong>受影響</strong>——這是清單做不到、
只有 DAG 才表達得出來的爆炸半徑。</p>
<div class="strip">
  <span class="pill p-ok">正常 {counts['ok']}</span>
  <span class="pill p-warn">注意 {counts['warn']}</span>
  <span class="pill p-bad">失敗 {counts['fail']}</span>
  <span class="pill p-unk">無法判定 {counts['unknown']}</span>
  <span class="ts">{esc(board['generated_at'])}</span>
</div>
{banner}
<div class="graph">
<pre class="mermaid">
{mermaid(board)}
</pre>
</div>
<h2>逐節點狀態</h2>
<div class="tw"><table>
<thead><tr><th>燈號</th><th>機制</th><th>層</th><th>依據</th></tr></thead>
<tbody>{''.join(rows)}</tbody>
</table></div>
<footer>由 <code>platform/statusdag/dag.py</code> 產生。每個燈號都來自磁碟上的
evidence 或即時探測，沒有任何一格是手動維護的——因此本圖無法與它描述的系統脫節。
<strong>無法判定</strong>刻意與<strong>正常</strong>分開：跑不起來的檢查不是通過的檢查。</footer>
</div>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--out", default=os.path.join(
        REPO_ROOT, "docs", "Pipeline-Status.html"))
    args = parser.parse_args()

    board = build()

    if args.json:
        print(json.dumps(board, indent=2, ensure_ascii=False))
        return

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(render_html(board))

    print(f"verdict: {board['verdict']}")
    for n in board["nodes"]:
        mark = {OK: "  ok  ", WARN: " warn ", FAIL: " FAIL ", UNKNOWN: " ???  "}[n["state"]]
        extra = f"   <- impacted by {', '.join(n['impacted_by'])}" if n["impacted_by"] else ""
        print(f"  [{mark}] {n['label']:<20} {n['detail'][:44]}{extra}")
    print(f"\nartifact={args.out}")


if __name__ == "__main__":
    main()

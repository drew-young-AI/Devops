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
# SUPERSEDED: this stage was exercised end-to-end and then REPLACED by another
# stage. Added 2026-08-25 because five DevOps stages were sitting amber for the
# Compose-to-Kubernetes migration, which made the board read as "five things
# need attention" when the honest reading is "five things moved". Amber that
# never clears is amber nobody looks at, and it was crowding out the two rows
# that genuinely need a decision.
#
# Ranked above OK and below WARN: a superseded node should not turn a stage
# green (it really is not running), and should not outrank a node that is
# actually degraded.
SUPERSEDED = "superseded"
RANK = {OK: 0, SUPERSEDED: 1, WARN: 2, UNKNOWN: 3, FAIL: 4}


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
    # EVERY warn-level reason, not the first one found.
    #
    # This used to return on the first match, and on 2026-09-01 that hid a new
    # one: `offsite` is not-configured (a known, accepted state), so the node
    # read "not configured: offsite" while `rotation` had just started
    # reporting `vacuous` -- a gate that ran and checked nothing. The node was
    # the right colour for the wrong reason, and the reason is the only part
    # anyone acts on. A board that shows one problem while holding two is a
    # board that will be trusted right up until the second one matters.
    jobs = data.get("jobs", [])

    def named(pred):
        return [j["job"] for j in jobs if pred(j)]

    reasons = []
    # Vacuous first: a failing job is visibly broken and somebody will look at
    # it. A vacuous one looks like a pass, which is the entire reason this
    # state exists.
    vacuous = named(lambda j: j.get("status") == "vacuous")
    if vacuous:
        reasons.append(f"檢查了零個項目: {', '.join(vacuous)}")
    bad = named(lambda j: j.get("status") in ("failed", "critical", "timeout"))
    if bad:
        reasons.append(f"failing: {', '.join(bad)}")
    # `late` must surface here too, or the DAG shows a green light while
    # status.sh exits 1 -- two views of one system disagreeing is exactly the
    # drift both are supposed to prevent.
    late = named(lambda j: j.get("late"))
    if late:
        reasons.append(f"late: {', '.join(late)}")
    unconfigured = named(lambda j: j.get("status") == "not-configured")
    if unconfigured:
        reasons.append(f"not configured: {', '.join(unconfigured)}")

    if reasons:
        return WARN, "；".join(reasons)
    return OK, f"{len(jobs)} jobs fresh"


def probe_gate(pattern, result_key="gate_result", stale_hours=48, stamp_key=None,
               retired_note=None):
    """SAST / DAST / Trivy style summaries: verdict plus an age check.

    Age matters as much as verdict. A PASS from last week says nothing about
    what is deployed now, so a stale pass is WARN, never OK."""
    path = newest(pattern)
    data = load(path)
    if not data:
        # Same distinction retired_only() draws for the build path: a gate that
        # ran to completion under a pilot since retired is not a gate that
        # never ran, and only one of those needs somebody to go and look.
        if retired_note and retired_only(pattern):
            return SUPERSEDED, retired_note
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
        # review.sh reads build metadata, the Trivy gate, the SBOM and develop
        # health -- all artefacts of the Compose path. With that path retired
        # it has nothing to review, which is a consequence of the Kubernetes
        # move rather than a review that failed to run.
        if retired_only("*/llm_review_*.json"):
            return SUPERSEDED, "輸入來自已退役的 Compose 路徑；待接上 Kubernetes 產物"
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
            if retired_only("*/deploy_develop_*.json"):
                return SUPERSEDED, "已由 station1-hello 驗證後退役；改走 Kubernetes"
            return UNKNOWN, "no deploy evidence"
        if data.get("health_status") != "healthy":
            return FAIL, f"health={data.get('health_status')}"
        return OK, f"sha {data.get('commit_sha', '?')}"
    # Globbed like every other probe rather than naming one pilot. The
    # hardcoded path here outlived the pilot it named: after station1-hello was
    # retired this would have kept reporting its last promote as the platform's
    # current production state, which is worse than reporting nothing. Retired
    # pilots live under evidence/_retired/ precisely so these globs stop
    # matching them.
    files = sorted(glob.glob(os.path.join(EVIDENCE, "*/production_like_state.json")))
    state = load(files[-1]) if files else None
    if not state:
        if retired_only("*/production_like_state.json"):
            return SUPERSEDED, "已由 station1-hello 驗證後退役；藍綠改在 Kubernetes"
        return UNKNOWN, "never promoted"
    return OK, f"{state.get('active_color')} @ sha {state.get('promoted_sha', '?')}"


def retired_only(pattern):
    """True when a stage has evidence ONLY under evidence/_retired/.

    Distinguishes two things a bare "no evidence" collapses into one:
    a stage that never worked, and a stage that WAS exercised end-to-end by a
    pilot that has since been retired. The Compose build -> push -> promote
    path is the second: station1-hello ran it and left evidence; station2-twin
    took the Kubernetes route instead, so nothing new lands here and nothing
    ever will. Reporting that as "no evidence" reads as a broken pipeline and
    sends the reader looking for a failure that is not there.
    """
    live = glob.glob(os.path.join(EVIDENCE, pattern))
    live = [f for f in live if "_retired" not in f]
    retired = glob.glob(os.path.join(EVIDENCE, "_retired", "*", os.path.basename(pattern)))
    return not live and bool(retired)


def probe_ci():
    files = sorted(glob.glob(os.path.join(EVIDENCE, "*/build_*.json")))
    data = load(files[-1]) if files else None
    if not data:
        if retired_only("*/build_*.json"):
            return SUPERSEDED, "已由 station1-hello 驗證後退役；改走 Kubernetes"
        return UNKNOWN, "no build evidence"
    return OK, f"sha {data.get('commit_sha', '?')[:7]}"


def probe_github_actions():
    """Remote CI state, read from evidence rather than fetched here.

    WHY THIS NODE EXISTS (2026-08-31).

    GitHub Actions was red on 13 of the last 20 runs and had been failing for at
    least six days with nobody notified. Every layer of the platform's own
    notification chain works -- Alertmanager groups, Telegram delivers, the
    board renders -- but remote CI state reached none of them, so the one signal
    saying "the contracts no longer hold" had no way to arrive.

    A red CI nobody is told about is the same failure as an alert routed to a
    null receiver: indistinguishable from no failure at all.

    WHY IT READS A FILE.

    The first version called `gh run list` here. It took 30s and then failed --
    GitHub was unreachable while 1.1.1.1 and 8.8.8.8 were both fine. A board
    that renders in 30s does not get looked at, and a board whose own health
    depends on a third party's uptime is reporting the wrong thing.
    platform/ci/fetch_gha_status.sh does the fetching on a schedule.

    THREE DISTINCT UNHAPPY STATES, kept distinct on purpose:
      - the fetch never ran            -> UNKNOWN, "no evidence"
      - the fetch ran and GitHub was   -> UNKNOWN, and the age is shown
        unreachable
      - the fetch ran and CI is red    -> FAIL
    Collapsing the first two into FAIL would make the board red for someone
    else's outage; collapsing any of them into OK is how six days went unread.
    """
    path = os.path.join(EVIDENCE, "ci", "gha_status.json")
    data = load(path)
    if not data:
        return UNKNOWN, "尚未抓取（platform/ci/fetch_gha_status.sh）"

    fetched = data.get("fetched_at", "")
    hours = age_hours(fetched)
    # Staleness is judged before content. Green CI information from three days
    # ago is not evidence that CI is green now, and presenting it as such is
    # exactly the "wrong copy is monitored" defect in a new place.
    stale = hours is not None and hours > 6

    state = data.get("fetch_state")
    if state != "ok":
        note = data.get("detail", state or "?")[:40]
        return UNKNOWN, f"抓取失敗：{note}"

    runs = data.get("runs") or []
    if not runs:
        return UNKNOWN, "main 上沒有執行紀錄"

    r = runs[0]
    title = (r.get("displayTitle") or "")[:30]
    age = f"（{hours:.0f}h 前抓取）" if stale else ""
    if r.get("status") != "completed":
        return WARN, f"執行中：{title}{age}"
    concl = r.get("conclusion")
    if concl == "success":
        if stale:
            return WARN, f"main 綠燈但資訊過期{age}"
        return OK, f"main 綠燈：{title}"

    # How many of the recent runs failed, because one red run is a bad commit
    # and ten red runs is a channel nobody reads.
    bad = sum(1 for x in runs if x.get("conclusion") not in (None, "success"))
    return FAIL, f"main {concl}：最近 {len(runs)} 次有 {bad} 次紅{age}"


def probe_registry():
    files = sorted(glob.glob(os.path.join(EVIDENCE, "*/push_*.json")))
    if not files:
        if retired_only("*/push_*.json"):
            return SUPERSEDED, "已由 station1-hello 驗證後退役；改走本機 registry"
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


def probe_prometheus():
    """Container up is NECESSARY AND NOT SUFFICIENT, which this probe learned
    the hard way.

    On 2026-08-28 a new alert rule shipped whose vector match was ambiguous.
    It parsed; `promtool check rules` reported SUCCESS; Prometheus loaded it
    and then failed to evaluate it on every single cycle. For 11 hours this
    node read `ok  running (none)` and `alertmgr` read `no active alerts` --
    and "no active alerts" is EXACTLY what a rule that cannot evaluate
    produces. Two green nodes agreeing, describing a blind spot.

    check_health.py did detect it and wrote UNKNOWN into evidence every 15
    minutes. Nobody read it, because the board is what people read. So the
    finding belongs here, on the node whose greenness was the lie.
    """
    state, detail = probe_docker("observability-prometheus-1")
    if state != OK:
        return state, detail
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:19090/api/v1/rules", timeout=6) as r:
            groups = json.load(r)["data"]["groups"]
    except Exception as e:  # noqa: BLE001
        return WARN, f"running, rules unreadable: {str(e)[:40]}"
    rules = [rule for g in groups for rule in g["rules"]]
    if not rules:
        # Zero rules is not "nothing wrong". It is an alerting layer that
        # cannot report anything, and it looks identical to a quiet system.
        return WARN, "running, but NO alert rules are loaded"
    broken = [rule["name"] for rule in rules if rule.get("health") != "ok"]
    if broken:
        return WARN, (f"{len(broken)} rule(s) cannot evaluate: "
                      + ", ".join(sorted(broken)[:3]))
    return OK, f"running, {len(rules)} rules evaluating"


def probe_human_gate():
    """The promote gate is not a service and cannot be 'down'. It is shown so
    the DAG matches the real flow -- and so the one deliberately manual step
    is visible as manual rather than looking like a missing automation."""
    return OK, "manual by design"


# --------------------------------------------------------------------------
# The graph. Edges are real dependencies, not drawing conveniences.
# --------------------------------------------------------------------------


# --------------------------------------------------------------------------
# DataOps / MLOps / Kubernetes probes.
#
# Added 2026-08-25. The board was DevOps-only, which made it structurally
# unable to answer the question the stage review actually asks -- "where is
# each of the three lines". Reporting the DevOps line alone and calling it the
# platform's status was the same shape of error this project keeps finding:
# a true statement that answers a narrower question than the one asked.
#
# Every probe below reads LIVE state (a query, an API round-trip), never a
# document. A number in a report that came from a document is a number nobody
# re-checked.
# --------------------------------------------------------------------------

def psql(sql, timeout=20):
    """One value out of the pilot database, or None if it cannot be reached.
    None is deliberately distinct from 0: 'no answer' and 'zero rows' are
    different facts and the board colours them differently."""
    rc, out = run(["docker", "exec", "station2-twin-db-1", "psql", "-U", "twin",
                   "-d", "twin", "-qtAX", "-c", sql], timeout=timeout)
    if rc != 0:
        return None
    return out.strip()


def _n(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def probe_sources():
    n = _n(psql("SELECT count(*) FROM data_source;"))
    if n is None:
        return UNKNOWN, "資料庫無回應"
    if n == 0:
        return FAIL, "沒有任何登記來源"
    return OK, f"{n} 個登記來源"


def probe_facts():
    sf = _n(psql("SELECT count(*) FROM surveillance_fact;"))
    df = _n(psql("SELECT count(*) FROM demographic_fact;"))
    if sf is None or df is None:
        return UNKNOWN, "資料庫無回應"
    if sf == 0:
        return FAIL, "事實表為空"
    return OK, f"監測 {sf:,} 列／人口 {df:,} 列"


def probe_lineage():
    """The arithmetic is a CHECK constraint, so a violating row cannot exist.
    Probing it anyway is the point: a constraint that was dropped leaves no
    trace, and 'the schema says so' is exactly the kind of claim this board
    exists to stop taking on faith."""
    # source_rows_accepted, NOT rows_accepted. The first version of this probe
    # used rows_accepted and reported 8/39 batches "broken" -- the arithmetic
    # was mine, not the schema's. rows_accepted counts OUTPUT rows and one
    # source row fans out to many facts (one CSV line x 11 diseases); the
    # constraint is over SOURCE rows. Reading the constraint instead of
    # recalling it would have taken ten seconds.
    bad = _n(psql("SELECT count(*) FROM ingest_runs WHERE rows_in_file <> "
                  "source_rows_accepted + rows_rejected + duplicate_rows;"))
    total = _n(psql("SELECT count(*) FROM ingest_runs;"))
    # A CHECK cannot be violated while it is enforced, so the arithmetic above
    # can only ever fail if the constraint was DROPPED -- which leaves no trace
    # anywhere. That is exactly why both are probed.
    enforced = _n(psql("SELECT count(*) FROM pg_constraint WHERE conrelid = "
                       "'ingest_runs'::regclass AND contype = 'c' AND "
                       "pg_get_constraintdef(oid) LIKE '%source_rows_accepted%';"))
    if bad is None or total is None or enforced is None:
        return UNKNOWN, "資料庫無回應"
    if not enforced:
        return FAIL, "血緣算術的 CHECK 約束已不存在"
    if bad > 0:
        return FAIL, f"{bad}/{total} 批次的血緣算術對不上"
    return OK, f"{total} 批次全數收斂（CHECK 約束執行中）"


def probe_geo():
    n = _n(psql("SELECT count(*) FROM geo_area;"))
    if n is None:
        return UNKNOWN, "資料庫無回應"
    if n == 0:
        return FAIL, "沒有地理權威資料"
    return OK, f"{n:,} 個行政區（縣市／鄉鎮／村里）"


def probe_epiweek():
    """B10, the blocked milestone, as a live number rather than a sentence in
    a plan. Reported WARN, not FAIL: nothing is broken, a question is
    unanswered -- and the two need to look different to a reader deciding
    where to spend attention."""
    null_dates = _n(psql("SELECT count(*) FROM time_period WHERE cal_date IS NULL;"))
    total = _n(psql("SELECT count(*) FROM time_period;"))
    if null_dates is None or total is None:
        return UNKNOWN, "資料庫無回應"
    if null_dates == 0:
        return OK, f"{total} 個期間全數對到日曆日"
    return WARN, f"{null_dates}/{total} 個期間無日曆日（待疾管署查證）"


def probe_features():
    n = _n(psql("SELECT count(*) FROM feature_set WHERE code_sha256 IS NOT NULL;"))
    rows = _n(psql("SELECT count(*) FROM feature_row;"))
    if n is None or rows is None:
        return UNKNOWN, "資料庫無回應"
    if n == 0:
        return FAIL, "沒有綁定程式碼雜湊的特徵集"
    return OK, f"{n} 個特徵集綁定 code_sha256／{rows:,} 特徵列"


def probe_backtest():
    n = _n(psql("SELECT count(*) FROM model_run "
                "WHERE split_strategy = 'rolling_origin';"))
    if n is None:
        return UNKNOWN, "資料庫無回應"
    if n == 0:
        return FAIL, "沒有 rolling-origin 回測紀錄"
    return OK, f"{n} 次 rolling-origin 回測"


def probe_model_gate():
    """Does the model actually beat its baselines? This is C8, and it is the
    one node on the board that is allowed to be amber while everything around
    it is green: the gate WORKS (it refuses), and the model LOSES. Collapsing
    those two into one light would hide whichever half you did not pick."""
    # Report the MARGIN, not just the count. The first version said
    # "3/7 次回測通過閘門" and rendered green -- true, and it reads as good
    # news. The three that pass do so by 0.32%, and every t+1 run LOSES by
    # 12%. A green light on that is the sentence "the model beats baseline"
    # doing work the numbers do not support.
    #
    # The amber condition is a FACT, not a threshold somebody chose: it turns
    # amber when any horizon loses to persistence. No invented significance
    # cutoff, nothing to argue about.
    rows = psql("SELECT horizon_weeks, "
                "round((((baseline_persistence_mae - mae) / "
                "baseline_persistence_mae) * 100)::numeric, 2) "
                "FROM model_run WHERE split_strategy = 'rolling_origin' "
                "GROUP BY horizon_weeks, mae, baseline_persistence_mae "
                "ORDER BY horizon_weeks;")
    if rows is None:
        return UNKNOWN, "資料庫無回應"
    best = {}
    for line in rows.splitlines():
        parts = line.split("|")
        if len(parts) != 2:
            continue
        try:
            h, margin = int(parts[0]), float(parts[1])
        except ValueError:
            continue
        best[h] = max(best.get(h, margin), margin)
    if not best:
        return WARN, "沒有 rolling-origin 回測可判定"
    detail = "／".join(f"t+{h} {m:+.2f}%" for h, m in sorted(best.items()))
    if any(m <= 0 for m in best.values()):
        return WARN, f"閘門運作中（贏才准上線），但仍輸給持平基準：{detail}"
    return OK, f"全數勝過持平基準：{detail}"


def probe_forecast():
    n = _n(psql("SELECT count(*) FROM forecast;"))
    if n is None:
        return UNKNOWN, "資料庫無回應"
    if n == 0:
        return WARN, "尚無已發布預測（閘門拒絕即為此結果）"
    return OK, f"{n} 筆已發布預測"


def probe_retrain():
    data = load(os.path.join(EVIDENCE, "scheduler", "retrain_last.json"))
    if not data:
        return UNKNOWN, "從未執行"
    if not data.get("last_scheduled_at"):
        return WARN, "只手動跑過，排程從未觸發"
    if data.get("status") != "ok":
        return FAIL, f"上次 {data.get('status')}"
    return OK, f"排程觸發成功（{data.get('duration_seconds')}s）"


def probe_k8s():
    rc, _ = run(["kubectl", "--context", "k3d-devops-lab",
                 "get", "--raw", "/readyz"], timeout=15)
    if rc is None:
        return UNKNOWN, "kubectl 無法執行"
    if rc != 0:
        return WARN, "叢集未啟動（Compose 平台不依賴它）"
    return OK, "k3d 叢集回應 /readyz"


def probe_bluegreen():
    """Which colour is live RIGHT NOW, read off the Service selector. Not
    'blue/green is implemented' -- that is a claim about code. This is a claim
    about the cluster, and it is the only one worth putting on a board."""
    # Namespace `station2` and label `color` -- both READ off the cluster, not
    # guessed. The first version guessed `station2-twin` / `colour` and
    # reported "service not deployed" while it was serving traffic: a probe
    # that is wrong about where to look reports an outage that is not there,
    # which is worse than no probe.
    rc, out = run(["kubectl", "--context", "k3d-devops-lab", "-n", "station2",
                   "get", "svc", "station2-twin",
                   "-o", "jsonpath={.spec.selector.color}"], timeout=15)
    if rc is None:
        return UNKNOWN, "kubectl 無法執行"
    if rc != 0 or not out.strip():
        return WARN, "叢集未啟動或服務未部署"
    return OK, f"目前流量指向 {out.strip()}"


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
    # Remote CI, distinct from the local build evidence above. Added 2026-08-31
    # because GitHub Actions had been red for at least six days unnoticed.
    ("gha",        "GitHub Actions",      "build",       probe_github_actions),
    ("trivy",      "映像漏洞掃描",         "build",       lambda: probe_gate("*/trivy_summary_*.json", stale_hours=24 * 30,
                                                                      retired_note="已由 station1-hello 驗證後退役；k8s 映像走本機 registry")),
    ("registry",   "Registry 推送",       "build",       probe_registry),

    ("develop",    "develop 部署",        "deploy",      lambda: probe_deploy("develop")),
    ("dast",       "DAST 執行中系統",      "verify",      lambda: probe_gate("security/dast_summary_*.json", stale_hours=48)),
    ("llmreview",  "LLM 複審",            "verify",      probe_llm_review),
    ("gate",       "真人 PROMOTE",        "gate",        probe_human_gate),
    ("prodlike",   "production-like",     "release",     lambda: probe_deploy("production-like")),
    ("nginx",      "NGINX 入口",          "release",     lambda: probe_docker("nginx-nginx-1")),

    ("prometheus", "Prometheus 指標",     "observe",     probe_prometheus),
    ("loki",       "Loki 日誌",           "observe",     lambda: probe_docker("observability-loki-1")),
    ("alertmgr",   "Alertmanager 告警",   "observe",     probe_alertmanager),
    ("grafana",    "Grafana 檢視",        "observe",     lambda: probe_docker("observability-grafana-1")),

    # --- DataOps（綠）---------------------------------------------------
    ("sources",    "來源登記",            "dataops",     probe_sources),
    ("geo",        "地理權威",            "dataops",     probe_geo),
    ("facts",      "事實載入",            "dataops",     probe_facts),
    ("lineage",    "血緣算術",            "dataops",     probe_lineage),
    ("dcontract",  "資料契約",            "dataops",     lambda: probe_gate("data/contract_summary_*.json", stale_hours=24 * 8)),
    ("epiweek",    "週↔日曆對照",         "dataops",     probe_epiweek),

    # --- MLOps（棕）-----------------------------------------------------
    ("features",   "特徵集",              "mlops",       probe_features),
    ("backtest",   "回測（rolling-origin）", "mlops",     probe_backtest),
    ("mgate",      "上線閘門",            "mlops",       probe_model_gate),
    ("forecast",   "已發布預測",          "mlops",       probe_forecast),
    ("retrain",    "排程重訓",            "mlops",       probe_retrain),

    # --- Kubernetes（藍，A9/A10）-----------------------------------------
    ("k8s",        "k3d 叢集",            "k8s",         probe_k8s),
    ("bluegreen",  "藍綠切換",            "k8s",         probe_bluegreen),
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

    # DataOps: 來源 -> 載入 -> 血緣 -> 契約。地理權威是載入的前提（沒有它就
    # 沒有 geo_code 可解析），週↔日曆對照掛在載入之後，因為它是「已經載進來
    # 的資料還缺什麼」，不是載入的阻擋條件。
    ("sources", "facts"),
    ("geo", "facts"),
    ("facts", "lineage"),
    ("lineage", "dcontract"),
    ("facts", "epiweek"),

    # MLOps 完全長在 DataOps 上：契約沒過，特徵就不該建。
    ("dcontract", "features"),
    ("features", "backtest"),
    ("backtest", "mgate"),
    ("mgate", "forecast"),
    ("scheduler", "retrain"),
    ("retrain", "backtest"),

    # Kubernetes: 叢集是藍綠的底座；藍綠取代了 Compose 的 promote 路徑。
    ("k8s", "bluegreen"),
    ("registry", "bluegreen"),
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
    ("k8s", "Kubernetes"),
    ("dataops", "DataOps 資料"),
    ("mlops", "MLOps 模型"),
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
    verdict = {0: "ALL_GREEN", 1: "ALL_GREEN", 2: "DEGRADED",
               3: "UNKNOWN", 4: "FAILED"}[worst]

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


STATE_LABEL = {OK: "正常", SUPERSEDED: "已被取代", WARN: "注意", FAIL: "失敗",
               UNKNOWN: "無法判定"}
# Terminal marks, keyed off the same set as STATE_LABEL so a new state can
# never be missing from one and present in the other.
TERMINAL_MARK = {OK: "  ok  ", SUPERSEDED: " moved", WARN: " warn ",
                 FAIL: " FAIL ", UNKNOWN: " ???  "}
assert set(TERMINAL_MARK) == set(STATE_LABEL) == set(RANK), \
    "a state exists in one map and not another -- add it everywhere"


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


# --------------------------------------------------------------------------
# Prometheus text format.
#
# WHY: the HTML page is only true at the moment it is generated, and somebody
# has to remember to generate it. A metric is scraped every 15s by the
# Prometheus already running in this platform, which buys three things the page
# cannot have at any price:
#
#   HISTORY   "when did this stage go red" is unanswerable from a page that
#             only ever shows now. It is the first question asked in a review.
#   ALERTING  Alertmanager already routes to a real human (A7). A red stage can
#             page someone instead of waiting to be looked at.
#   NO RUN    nobody has to remember anything.
#
# One gauge with a state label, rather than a number encoding state. A number
# invites `> 1` comparisons that silently reorder when a state is added --
# which just happened when SUPERSEDED was inserted between OK and WARN.
# --------------------------------------------------------------------------

def render_prometheus(board):
    lines = [
        "# HELP devops_node_state Platform DAG node state, 1 for the active state.",
        "# TYPE devops_node_state gauge",
    ]
    states = (OK, SUPERSEDED, WARN, UNKNOWN, FAIL)
    for n in board["nodes"]:
        for state in states:
            lines.append(
                f'devops_node_state{{node="{n["id"]}",layer="{n["layer"]}",'
                f'state="{state}"}} {1 if n["state"] == state else 0}')
    lines += [
        "# HELP devops_node_state_code DISPLAY ONLY: RANK of the node's state.",
        "# TYPE devops_node_state_code gauge",
    ]
    # A numeric companion, and its only job is drawing. Grafana's state-timeline
    # needs one numeric series per node to colour a band; the labelled gauge
    # above gives five series per node, which draws nothing useful.
    #
    # ALERT ON THE LABELLED GAUGE, NEVER ON THIS. The value is RANK, and RANK
    # reorders whenever a state is inserted -- SUPERSEDED went in between OK and
    # WARN and silently shifted every code above it. A rule written as `> 1`
    # would have quietly changed meaning that day. Sourced from RANK rather than
    # a second literal so the codes and the ordering cannot disagree.
    for n in board["nodes"]:
        lines.append(f'devops_node_state_code{{node="{n["id"]}",'
                     f'layer="{n["layer"]}"}} {RANK[n["state"]]}')
    lines += [
        "# HELP devops_node_impacted Node is downstream of a failing node.",
        "# TYPE devops_node_impacted gauge",
    ]
    for n in board["nodes"]:
        lines.append(f'devops_node_impacted{{node="{n["id"]}"}} '
                     f'{1 if n["impacted_by"] else 0}')
    lines += [
        "# HELP devops_board_generated_seconds Unix time this board was built.",
        "# TYPE devops_board_generated_seconds gauge",
        # Exported so a dashboard can show the board's OWN staleness. A scrape
        # target that quietly stops updating otherwise looks exactly like a
        # platform where nothing is changing.
        f"devops_board_generated_seconds {int(datetime.now(timezone.utc).timestamp())}",
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--prometheus", metavar="PATH", default=None,
                        help="also write Prometheus text format to PATH "
                             "(written atomically: a scraper must never read "
                             "a half-written file and see a node vanish)")
    parser.add_argument("--out", default=os.path.join(
        REPO_ROOT, "docs", "Pipeline-Status.html"))
    args = parser.parse_args()

    board = build()

    if args.json:
        print(json.dumps(board, indent=2, ensure_ascii=False))
        return

    if args.prometheus:
        os.makedirs(os.path.dirname(args.prometheus), exist_ok=True)
        tmp = args.prometheus + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(render_prometheus(board))
        os.replace(tmp, args.prometheus)     # atomic within one filesystem

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(render_html(board))

    print(f"verdict: {board['verdict']}")
    for n in board["nodes"]:
        # Derived from STATE_LABEL, not a second literal map. The first
        # version WAS a second literal, and adding SUPERSEDED made this line
        # raise KeyError after every probe had already run -- the job failed
        # rc=1 having done all its work. Two maps of the same thing is one map
        # too many; this one now cannot fall behind.
        mark = TERMINAL_MARK.get(n["state"], f" {n['state'][:4]:^4} ")
        extra = f"   <- impacted by {', '.join(n['impacted_by'])}" if n["impacted_by"] else ""
        print(f"  [{mark}] {n['label']:<20} {n['detail'][:44]}{extra}")
    print(f"\nartifact={args.out}")


if __name__ == "__main__":
    main()

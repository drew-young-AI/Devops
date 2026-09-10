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
import re
import shutil
import subprocess
import urllib.error
import urllib.parse
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


def age_hours_iso(stamp):
    """Age of an ISO-8601 timestamp, offset included.

    WHY THIS IS SEPARATE FROM age_hours (2026-09-09).

    `age_hours` takes the compact `%Y%m%dT%H%M%SZ` most of this repo's evidence
    filenames use. `evidence/ci/gha_status.json` does not: it is written by
    `datetime.now().astimezone().isoformat(timespec="seconds")`, which produces
    `2026-09-09T20:31:07+08:00`. Passed to `age_hours`, that raises ValueError
    and is caught and turned into None -- so `stale` was False on every run and
    the staleness branch, whose docstring says "green CI information from three
    days ago is not evidence that CI is green now", had never once been taken.

    A guard that cannot fire reads exactly like a guard that has nothing to
    report. This one was found by a fixture dated 2020 that came back OK.
    """
    try:
        when = datetime.fromisoformat(stamp)
    except (ValueError, TypeError):
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - when).total_seconds() / 3600


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


def run_diag(cmd, timeout=25):
    """run(), but keeps stderr -- for probes whose failure message is the
    diagnosis rather than noise.

    Separate from run() rather than a wider return tuple because run() has ten
    callers and none of the others want a third value. kubectl writes its one
    self-describing line ("certificate is valid for X, not Y") to stderr, and
    probe_prod_cluster discarded it for a fixed sentence, so three different
    causes read identically on the board -- docs/Backlog.md T2.
    """
    try:
        p = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, OSError) as e:
        return None, "", str(e)[:120]


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


def _ready_body():
    """The readiness endpoint's own words, or None if it did not answer.

    `http_probe` reports reachable/not; when a copy answers 503 the REASON is in
    the body, and 「schema_mismatch, expected 17, actual 18」 is the difference
    between a five-second fix and an afternoon.
    """
    try:
        import ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(
                "http://127.0.0.1:18090/health/ready", timeout=4, context=ctx) as r:
            return r.read(200).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        try:
            return exc.read(200).decode("utf-8", "replace")
        except Exception:
            return f"HTTP {exc.code}"
    except Exception:
        return None


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
        # DEPLOYED IS NOT SERVING (2026-09-10).
        #
        # Everything above reads the evidence file written AT DEPLOY TIME. It
        # answers "did the last deployment succeed", which stops being the same
        # question the moment anything changes underneath the running copy.
        #
        # Found by walking the platform as a first-time reader would: the pilot
        # README had no start instructions, and writing them meant running the
        # readiness check by hand. The develop copy had been answering
        # `{"status": "schema_mismatch", "expected": 17, "actual": 18}` for
        # thirteen hours -- migration 018 moved the database while that
        # container kept the environment it was started with -- and this node
        # said `ok` the entire time, because the deployment really had
        # succeeded, the previous day.
        #
        # The readiness endpoint is the one that knows. It is asked here rather
        # than trusted from a file, and a copy that cannot be reached is UNKNOWN
        # rather than FAIL: the pilot is allowed to be stopped, and a node that
        # goes red for a service nobody asked to be running gets ignored.
        sha = data.get("commit_sha", "?")
        ok, detail = http_probe("http://127.0.0.1:18090/health/ready", timeout=4)
        if not ok:
            body = _ready_body()
            if body is None:
                return UNKNOWN, f"sha {sha}，但這份副本沒有回應（可能沒在跑）"
            return FAIL, (f"已部署 sha {sha}，但**沒有在服務**："
                          f"{body}")
        return OK, f"sha {sha}，readiness 通過"
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
    # ISO-8601 with an offset, not the compact evidence-filename format --
    # see age_hours_iso for the six-week-old bug this line is fixing.
    hours = age_hours_iso(fetched)
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

    # PER WORKFLOW, NOT runs[0] (2026-09-09).
    #
    # `gh run list` returns every workflow interleaved -- this repo pushes
    # three (Platform Tests, IaC Validation, pilot-image) and they finish in
    # whatever order they finish. Reading runs[0] therefore asks "was the most
    # recently finished job of ANY workflow green", which is not a question
    # anybody wants answered. Platform Tests had been red for three pushes
    # while this node printed 「main 綠燈」 because IaC Validation happened to
    # land last.
    #
    # That is the exact failure this node was built to prevent -- "a red CI
    # nobody is told about is indistinguishable from no failure" -- recurring
    # one level down, inside the guard itself. The list held the answer; the
    # verdict looked at one element of it.
    #
    # The newest run of EACH workflow is the unit, because that is what "is
    # this contract currently holding" means for each of them.
    newest = {}
    for x in runs:
        wf = x.get("workflowName") or "?"
        if wf not in newest:            # runs arrive newest-first
            newest[wf] = x
    age = f"（{hours:.0f}h 前抓取）" if stale else ""

    running = [w for w, x in newest.items() if x.get("status") != "completed"]
    red = sorted(w for w, x in newest.items()
                 if x.get("status") == "completed"
                 and x.get("conclusion") not in (None, "success"))
    if red:
        # Named, because "CI is red" sends someone to look at three workflows.
        title = (newest[red[0]].get("displayTitle") or "")[:24]
        return FAIL, (f"{len(red)}/{len(newest)} 個 workflow 紅："
                      f"{', '.join(red)}（{title}）{age}")
    if running:
        return WARN, f"執行中：{', '.join(running)}{age}"
    if newest:
        title = (list(newest.values())[0].get("displayTitle") or "")[:26]
        if stale:
            return WARN, f"main 綠燈但資訊過期{age}"
        return OK, f"main {len(newest)} 個 workflow 全綠：{title}"
    r = runs[0]
    title = (r.get("displayTitle") or "")[:30]
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


ALERT_CHANNEL_RE = re.compile(r"^\s{4,}(\w+)_configs:", re.M)


def declared_channels():
    """Which delivery channels config.template.yml says this platform has.

    The template is the declaration; the live config.yml is generated from it
    by setup_notifications.sh, which DROPS a channel whose credential file is
    absent rather than leaving a receiver addressed to `__MAIL_TO__`. Dropping
    is the right behaviour. Dropping SILENTLY is not, and that is what this
    reads the template to catch.
    """
    path = os.path.join(REPO_ROOT,
                        "platform/observability/alertmanager/config.template.yml")
    try:
        with open(path, encoding="utf-8") as fh:
            return set(ALERT_CHANNEL_RE.findall(fh.read()))
    except OSError:
        return set()


NOTIFY_WINDOW_S = 6 * 3600


def _recent_notify_failures():
    """Failed sends per integration inside the recent window, or None.

    None means "Prometheus could not answer" -- no series yet, unreachable, or
    a malformed reply. It is deliberately distinct from {} ("asked, and nothing
    failed"), because the caller must not report a healthy channel on the
    strength of a question that was never answered.
    """
    q = ("sum by (integration) (increase("
         "alertmanager_notifications_failed_total[%ds]))" % NOTIFY_WINDOW_S)
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:19090/api/v1/query?query="
                + urllib.parse.quote(q), timeout=8) as r:
            d = json.load(r)
    except Exception:  # noqa: BLE001
        return None
    if d.get("status") != "success":
        return None
    rows = d.get("data", {}).get("result", [])
    if not rows:
        # No series at all: Alertmanager is not being scraped, or has not been
        # scraped twice yet. Either way this is unanswered, not clean.
        return None
    out = {}
    for row in rows:
        try:
            v = float(row["value"][1])
        except (KeyError, IndexError, TypeError, ValueError):
            continue
        if v > 0:
            out[row.get("metric", {}).get("integration", "?")] = v
    return out


def probe_alertmanager():
    """Alerts firing is NECESSARY AND NOT SUFFICIENT -- they must reach someone.

    Same lesson as probe_prometheus above, one hop further down the chain. On
    2026-08-19 every layer worked and the alert still went nowhere for 3h55m
    because the last hop was a null receiver; the fix wired Telegram, and the
    config comment written that day says there are TWO channels -- "mail is
    where it can be found again a week later ... neither is a fallback for the
    other".

    On 2026-09-03 that was measured for the first time. Telegram had delivered
    52 notifications with 0 failures. Email had delivered 0, because there is
    no email receiver in the live config at all: mail.conf and smtp-password
    were never created, so the generator correctly removed the block -- and
    NOTHING anywhere reported that one of the two declared channels did not
    exist. A comment describing a mechanism is not the mechanism.

    So this node now answers three questions instead of one:
      1. is Alertmanager reachable        (it always did)
      2. is every DECLARED channel wired  (not-configured, like offsite)
      3. is delivery actually succeeding  (failed_total, not just configured)
    """
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:19093/api/v2/alerts?active=true", timeout=6) as r:
            alerts = json.load(r)
    except Exception as e:  # noqa: BLE001
        return UNKNOWN, f"unreachable: {str(e)[:40]}"

    reasons = []

    # Wiring: declared in the template, present in what Alertmanager LOADED.
    # Read from the API, not from the file on disk -- the file is what someone
    # meant to run and this is what is running.
    live = ""
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:19093/api/v2/status", timeout=6) as r:
            live = json.load(r).get("config", {}).get("original", "") or ""
    except Exception:  # noqa: BLE001
        reasons.append("設定無法讀取，無法確認通道是否接上")
    if live:
        missing = sorted(c for c in declared_channels()
                         if f"{c}_configs:" not in live)
        if missing:
            reasons.append("宣告了但沒接上: " + ", ".join(missing))

    # Delivery: configured is not delivered. A channel whose every send fails
    # is indistinguishable, from the board, from one that is working.
    #
    # ASK "IS IT FAILING NOW", NOT "HAS IT EVER FAILED".
    #
    # This used to read alertmanager_notifications_failed_total straight off
    # /metrics and warn on any non-zero value. That counter is cumulative and
    # only resets when the process restarts, so it conflated two states that
    # need different actions: one bad send during a DNS blip six weeks ago, and
    # a channel that is dropping everything right now. It also meant a node
    # that had gone amber could never go green again by being FIXED -- only by
    # a restart, which is the same button that hides the problem.
    #
    # So the recent window comes from Prometheus (which scrapes Alertmanager as
    # of 2026-09-10; before that nothing did, which is how 287 failed telegram
    # sends stayed invisible for three days). The cumulative counter is kept
    # only as the fallback when Prometheus cannot answer, and it says so in the
    # text -- a reader must be able to tell "failing now" from "failed once,
    # sometime".
    recent = _recent_notify_failures()
    if recent is None:
        try:
            with urllib.request.urlopen(
                    "http://127.0.0.1:19093/metrics", timeout=6) as r:
                body = r.read().decode("utf-8", "replace")
            failed = {}
            for m in re.finditer(
                    r'alertmanager_notifications_failed_total\{integration="(\w+)"[^}]*\}'
                    r"\s+([0-9.e+]+)", body):
                failed[m.group(1)] = failed.get(m.group(1), 0.0) + float(m.group(2))
            broken = sorted(k for k, v in failed.items() if v > 0)
            if broken:
                reasons.append("累計曾送出失敗（無近期樣本）: " + ", ".join(broken))
        except Exception:  # noqa: BLE001
            reasons.append("送達指標無法讀取")
    elif recent:
        reasons.append(
            "近 %dh 送出失敗: " % (NOTIFY_WINDOW_S // 3600)
            + ", ".join("%s %d 次" % (k, round(v)) for k, v in sorted(recent.items())))

    crit = [a for a in alerts if a["labels"].get("severity") == "critical"]
    if crit:
        return FAIL, "; ".join([f"{len(crit)} critical firing"] + reasons)
    if reasons:
        # A channel that is not wired is a WARN even with zero alerts firing --
        # that is the only moment you can still fix it cheaply.
        return WARN, "; ".join(reasons + ([f"{len(alerts)} alert(s) firing"]
                                          if alerts else []))
    if alerts:
        return WARN, f"{len(alerts)} alert(s) firing"
    return OK, "no active alerts, all declared channels wired"


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


# Kept as a module constant so the suite can EVALUATE it -- against DuckDB
# with a synthetic regression -- rather than only exercise the Python that
# formats its output. The defect this replaced was entirely in the SQL
# (a max() where the sentence said "current"), and a stub of psql() would
# have certified it happily.
MODEL_GATE_SQL = """
        WITH m AS (
          -- TARGET IS PART OF THE KEY. From 2026-09-09 this pilot forecasts
          -- influenza-like illness AND influenza; without the target the two
          -- diseases' runs took turns in one slot and the board read as one
          -- model getting better and worse on alternate retrains. The two
          -- currently have margins of +2.3% and +10.4%, so the mixed version
          -- would have been wrong by a factor of four and still rendered.
          SELECT fs.target, mr.horizon_weeks, mr.model_run_id, mr.trained_at,
                 mr.algorithm,
                 (mr.baseline_persistence_mae - mr.mae)
                   / mr.baseline_persistence_mae * 100 AS pct
          FROM model_run mr
          JOIN feature_set fs ON fs.feature_set_id = mr.feature_set_id
          WHERE mr.split_strategy = 'rolling_origin'
        ),
        -- ALGORITHM IS PART OF THE ANSWER ONCE A SECOND FAMILY EXISTS.
        -- "the latest run at t+1" stopped being a single thing the moment the
        -- registry admitted Ridge: without the name, a tree-ensemble number
        -- and a linear-model number take turns in the same slot and the board
        -- reads as one model getting better and worse.
        latest AS (
          SELECT DISTINCT ON (target, horizon_weeks)
                 target, horizon_weeks, model_run_id, pct, algorithm
          FROM m ORDER BY target, horizon_weeks, trained_at DESC,
                          model_run_id DESC
        ),
        deployed AS (
          SELECT DISTINCT ON (m.target, f.horizon_weeks)
                 m.target, f.horizon_weeks, f.model_run_id, m.pct
          FROM forecast f JOIN m ON m.model_run_id = f.model_run_id
          ORDER BY m.target, f.horizon_weeks, f.forecast_id DESC
        )
        SELECT l.horizon_weeks, round(l.pct::numeric, 2),
               l.model_run_id || ' ' || l.algorithm,
               coalesce(round(d.pct::numeric, 2)::text, ''),
               coalesce(d.model_run_id::text, ''),
               l.target
        FROM latest l LEFT JOIN deployed d USING (target, horizon_weeks)
        ORDER BY l.target, 1;"""


def replacement_margin():
    """The champion/challenger margin, READ from the publisher rather than
    retyped here. A board that states a threshold it keeps its own copy of will
    eventually state the wrong one, and it would still render."""
    try:
        src = open(os.path.join(
            REPO_ROOT, "pilots/station2-twin/mlops/publish_forecast.py")).read()
    except OSError:
        return None
    m = re.search(r"^REPLACEMENT_MARGIN = ([0-9.]+)", src, re.M)
    return float(m.group(1)) if m else None


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
    # LATEST, NOT BEST-EVER -- and the deployed run beside it.
    #
    # The first version selected every rolling-origin run and then took
    # `max(margin)` per horizon. That reports THE BEST MARGIN EVER RECORDED
    # while the sentence around it reads as the current state. The two agree
    # today (2026-09-08: t+1 latest -12.08 = best -12.08; t+2 latest +0.55 =
    # best +0.55) purely because every retrain so far has improved, so the
    # defect is latent -- the first retrain that regresses is the one nobody
    # would see. History already contains a -56.25% run at t+1 that the max
    # has been hiding since 2026-08-20.
    #
    # The second column answers the question a reviewer actually asks, and
    # which nothing on this board could answer before: HOW DOES THE NEW MODEL
    # COMPARE TO THE ONE CURRENTLY SERVING? The gate itself only ever compares
    # a candidate against the persistence baseline (publish_forecast.py:
    # `ORDER BY mae ASC LIMIT 1` over every qualifying run in history), never
    # against the deployed run. Naming both here does not add that comparison
    # to the gate -- it makes its absence visible instead of invisible.
    rows = psql(MODEL_GATE_SQL)
    if rows is None:
        return UNKNOWN, "資料庫無回應"
    # KEYED ON (target, horizon). Two targets exist from 2026-09-09 and their
    # margins differ by a factor of four, so a dict keyed on horizon alone
    # would keep whichever row sorted last and report it as the layer's state.
    cur = {}
    for line in rows.splitlines():
        parts = line.split("|")
        if len(parts) != 6:
            continue
        try:
            h, margin, run_id = int(parts[0]), float(parts[1]), parts[2]
        except ValueError:
            continue
        cur[(parts[5], h)] = (margin, run_id, parts[3], parts[4])
    if not cur:
        return WARN, "沒有 rolling-origin 回測可判定"
    bits = []
    for (target, h), (margin, run_id, dep_pct, dep_run) in sorted(cur.items()):
        # "no deployed run" is not the same claim as "deployed and equal", so
        # it gets its own words rather than an empty comparison.
        served = (f"線上 run{dep_run} {float(dep_pct):+.2f}%"
                  if dep_pct else "尚未上線")
        short = target.replace("pct_", "")
        bits.append(f"{short} t+{h} 最新 run{run_id} {margin:+.2f}%（{served}）")
    detail = "／".join(bits)
    # The replacement rule belongs on this line because the line invites the
    # wrong inference without it: a reader who sees a challenger with a better
    # margin than the deployed run and no policy stated will read "should have
    # been promoted and was not".
    mg = replacement_margin()
    rule = (f"；汰換門檻 {mg*100:.0f}%（同分留任，ADR-0016）" if mg is not None
            else "；汰換門檻讀取失敗")
    # ANY target losing keeps the node amber. Aggregating them would let the
    # easier disease mask the harder one, which is the same masking the alert
    # rules avoid by grouping on the target.
    if any(m <= 0 for m, _r, _dp, _dr in cur.values()):
        return WARN, f"閘門運作中（贏才准上線），但仍輸給持平基準：{detail}{rule}"
    return OK, f"全數勝過持平基準：{detail}{rule}"


def probe_forecast():
    n = _n(psql("SELECT count(*) FROM forecast;"))
    if n is None:
        return UNKNOWN, "資料庫無回應"
    if n == 0:
        return WARN, "尚無已發布預測（閘門拒絕即為此結果）"
    return OK, f"{n} 筆已發布預測"


# The post-hoc scoring query. A MODULE CONSTANT, not an inline string, because
# it now has two readers: this probe (which turns it into a sentence for the
# board) and platform/mlops/pipeline_metrics.py (which turns it into numbers
# for Prometheus). Copied instead of shared, it would be the single most
# repeated defect on this platform -- and this particular query is the worst
# candidate for a copy that exists here: its first version omitted geo_code and
# visit_type from the join and fanned 2 forecasts out to 44 rows, a
# plausible-looking sample size built entirely from duplicates. A second copy
# would be a second chance to reintroduce exactly that.
#
# GROUPED BY HORIZON, and summed back up by score_totals() for the board. The
# board wants one sentence; the exporter wants a series per horizon, and the
# horizons are not interchangeable here -- t+1 has never passed the gate, so
# every scored forecast on this platform is a t+2 forecast. A total that hides
# that is a true number answering the wrong question.
FORECAST_SCORE_SQL = """
    WITH actual AS (
      -- geo_code and visit_type are in the GROUP BY, so they must also be
      -- SELECTed and joined on. Omitting them left one row per geography
      -- per week, and the LEFT JOIN fanned 2 forecasts out to 44 -- a
      -- plausible-looking sample size built entirely from duplicates.
      --
      -- DISEASE IS IN THE KEY for the same reason, added 2026-09-09. The
      -- disease was a WHERE clause fixing it to influenza-like illness while
      -- the forecast side was unfiltered, so the moment a second target was
      -- published every influenza forecast would have been scored against
      -- ILI's actual rate -- a number four times larger, on the same axis,
      -- producing a loss that says nothing about the model. Nothing about the
      -- output would have looked wrong.
      --
      -- THE TARGET IS ALSO SELECTED, added 2026-09-09 after the join above.
      -- Fixing the join stopped the wrong comparison; it did not make the
      -- result attributable. Grouping by horizon alone collapsed both targets
      -- into one bucket, so `1 scored, 3 pending` could not answer WHICH
      -- target was scored -- the aggregation-masking half of
      -- 「一個目前只有一個值的維度」. The comment in pipeline_metrics.scoring
      -- said "there is exactly one published horizon so nothing collides";
      -- that sentence was true when written and expired the day influenza was
      -- published. The target travels with the count from here on.
      SELECT tp.epi_year, tp.epi_week, f.geo_code, f.visit_type, f.disease_id,
             SUM(f.value)::float / NULLIF(SUM(f.denominator), 0) AS rate
      FROM surveillance_fact f
      JOIN time_period tp ON tp.period_id = f.period_id
      JOIN metric  m ON m.metric_id  = f.metric_id
      WHERE m.code = 'nhi_visits'
        AND tp.time_level = 'epi_week'
      GROUP BY 1, 2, 3, 4, 5
    )
    SELECT fc.horizon_weeks,
           coalesce(fs.target, 'unknown') AS target,
           count(*) FILTER (WHERE a.rate IS NOT NULL),
           count(*) FILTER (WHERE a.rate IS NULL),
           count(*) FILTER (WHERE a.rate IS NOT NULL
             AND abs(fc.predicted_value - a.rate)
               < abs(fc.observed_at_origin - a.rate))
    FROM forecast fc
    JOIN model_run   mr ON mr.model_run_id   = fc.model_run_id
    JOIN feature_set fs ON fs.feature_set_id = mr.feature_set_id
    LEFT JOIN actual a
      ON a.epi_year = fc.target_epi_year
     AND a.epi_week = fc.target_epi_week
     AND a.geo_code = fc.geo_code
     AND a.visit_type = fc.visit_type
     AND a.disease_id = fc.disease_id
    GROUP BY 1, 2 ORDER BY 1, 2;"""


def score_rows(raw):
    """Parse FORECAST_SCORE_SQL into (horizon, target, scored, pending, won).

    Raises ValueError on anything it cannot read, so a caller that expected
    five fields never silently proceeds with four.
    """
    out = []
    for line in (raw or "").strip().splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) != 5:
            raise ValueError(f"expected 5 fields, got {len(parts)}: {line}")
        h, target, scored, pending, won = parts
        out.append((int(h), target, int(scored), int(pending), int(won)))
    return out


def score_totals(raw):
    """The board's rollup: one number each, summed across horizon and target.

    The rollup still exists because the board needs one sentence, but it
    is now a DERIVED view of a per-target result rather than the only thing
    the query can produce. Prometheus takes the rows; only this node sums.
    """
    rows = score_rows(raw)
    if not rows:
        # No published forecasts at all. Not an error -- the gate publishes
        # rarely by design -- so this is the same shape as (0, 0, 0).
        return 0, 0, 0
    return (sum(r[2] for r in rows), sum(r[3] for r in rows),
            sum(r[4] for r in rows))


def probe_forecast_score():
    """Did the published forecasts turn out to be right?

    WHY THIS NODE DID NOT EXIST UNTIL 2026-09-08, AND WHY THAT MATTERED.

    Everything else on the mlops row is about the model BEFORE it is used:
    features built, backtests run, gate refused or allowed, forecast written.
    All five were green while nothing had ever compared a published number to
    what actually happened. The row read "MLOps 5/5" about a pilot whose
    predictions had never been scored -- the platform's own catalogued shape,
    「登記為存在，但不執行」, one layer up.

    Backtest MAE is not this measurement. A rolling-origin fold scores a model
    against history it was fitted around; this scores the number that was
    actually published, against the week that actually arrived.

    THE TARGET IS A RATE, NOT A COUNT. `predicted_value` is
    nhi_visits / denominator for one disease, geo and visit_type. Summing
    `surveillance_fact.value` across metrics to get an "actual" produces 18286
    against a prediction of 0.0198 -- a number three orders of magnitude out
    that still looks like a valid comparison. So the actual is recomputed with
    the SAME numerator/denominator as build_features.weekly_series, filtered
    by disease code, metric code, geo and visit_type.
    """
    rows_raw = psql(FORECAST_SCORE_SQL)
    if rows_raw is None:
        return UNKNOWN, "資料庫無回應"
    try:
        scored, pending, won = score_totals(rows_raw)
    except ValueError:
        return UNKNOWN, f"無法解析評分結果：{rows_raw[:60]}"
    if scored == 0:
        # Not a failure. A t+2 forecast cannot be scored for two weeks, and
        # calling that red would make the node permanently red by design.
        return OK, f"{pending} 筆已發布預測的目標週尚未到，無可評分者（正常）"
    tail = f"，另 {pending} 筆目標週未到" if pending else ""
    # THE SENTENCE NAMES THE TARGETS. The rollup "1/1 勝過持平基準" was true
    # and unreadable the moment a second disease was published: it cannot say
    # whether the one scored forecast was influenza or influenza-like illness,
    # and those are different claims about different models. Per-target detail
    # is appended whenever more than one target has published anything.
    per = ""
    try:
        rows = score_rows(rows_raw)
    except ValueError:
        rows = []
    targets = sorted({r[1] for r in rows})
    if len(targets) > 1:
        per = "；" + "／".join(
            f"{t} t+{h} {w}/{sc}"
            for h, t, sc, _p, w in sorted(rows, key=lambda r: (r[1], r[0]))
            if sc
        )
    # n is tiny by construction -- the gate publishes rarely on purpose. The
    # detail carries n so nobody reads 1/1 as a track record.
    status = WARN if won < scored else OK
    return status, (f"已發布預測事後評分：{won}/{scored} 勝過持平基準"
                    f"（n={scored}，尚不足以下結論）{tail}{per}")


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


CERT_WARN_DAYS = 30
CERT_ROOT = REPO_ROOT
CERT_GLOBS = ("platform/**/*.crt", "platform/**/*.pem",
              "pilots/**/*.crt", "pilots/**/*.pem")
# Probing ubu costs a TLS handshake over the LAN. It is skippable so a suite
# can assert on the file half deterministically -- not so production can turn
# it off, which is why the OK text says out loud when ubu was not read.
CERT_PROBE_UBU = True


def _seconds_until(not_after):
    """Parse OpenSSL's notAfter into seconds from now, or None if unparseable.

    Both formats are tried because the trailing zone is present on a file read
    (`GMT`) and absent on some builds; guessing one and silently returning
    None for the other would turn an expiring certificate into a skipped one.
    """
    for fmt in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y"):
        try:
            t = datetime.strptime(not_after.strip(), fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        return (t - datetime.now(timezone.utc)).total_seconds()
    return None


def _cert_not_after(path):
    """Seconds until the certificate at `path` expires, or None if it is not one.

    A .pem in this repo may be a private key or a chain. The honest answer for
    a key is "this is not a certificate", not "it never expires" -- so this
    returns None and the caller counts it separately rather than folding it
    into the healthy set.
    """
    rc, out, _ = run_diag(["openssl", "x509", "-in", path, "-noout", "-enddate"],
                          timeout=8)
    if rc != 0 or not out or "notAfter=" not in out:
        return None
    return _seconds_until(out.split("notAfter=", 1)[1])


def probe_certificates():
    """Every certificate this platform depends on, and how long it has left.

    NOTHING CHECKED THIS UNTIL 2026-09-10. That is a gap with a specific
    shape: a certificate does not degrade, it works perfectly and then stops,
    everywhere that uses it, at a timestamp decided months earlier by somebody
    else. The pinned TWCA intermediate under pilots/.../ingest/certs is the
    clearest case -- when it lapses, every public-health feed starts failing
    verification at once, and the error (CERTIFICATE_VERIFY_FAILED) names
    neither the file nor the date.

    Two sources, deliberately:
      files     what the repo carries. Missing ones are not an error here --
                a fresh clone has none of them (Runbook section 0) and that is
                what section 0 is for.
      ubu       the k3s API server certificate, read off the wire. It is not
                in this repo at all, and k3s only rotates it on restart within
                90 days of expiry -- a node that stays up for a year is
                exactly the case that expires.

    AN EMPTY SCAN IS REFUSED. If no file parsed as a certificate, this node
    reports UNKNOWN rather than OK: "nothing is expiring" and "nothing was
    read" produce the same silence otherwise, and this platform has already
    been caught by that five times.
    """
    seen, skipped = [], 0
    for pattern in CERT_GLOBS:
        for path in glob.glob(os.path.join(CERT_ROOT, pattern), recursive=True):
            # platform/tests/fixtures holds a DELIBERATELY EXPIRED certificate
            # -- it is the negative control that proves this node can go red,
            # and without this line it would hold the node red permanently.
            # Excluding a directory from a scan is also how a real certificate
            # hides, so the exclusion is exactly one path, spelled out, and the
            # suite asserts the fixture is still expired.
            if ("/venv/" in path or "/node_modules/" in path
                    or "/tests/fixtures/" in path):
                continue
            secs = _cert_not_after(path)
            if secs is None:
                skipped += 1
                continue
            seen.append((secs, os.path.relpath(path, CERT_ROOT)))

    # The one certificate that is not a file we own.
    rc, out = (1, "")
    if CERT_PROBE_UBU:
        rc, out, _ = run_diag(
            ["sh", "-c",
             "echo | openssl s_client -connect ubu.local:6443 -servername ubu.local "
             "2>/dev/null | openssl x509 -noout -enddate"], timeout=12)
    ubu_secs = (_seconds_until(out.split("notAfter=", 1)[1])
                if rc == 0 and out and "notAfter=" in out else None)
    if ubu_secs is not None:
        seen.append((ubu_secs, "ubu k3s API"))

    if not seen:
        return UNKNOWN, f"沒有讀到任何憑證（跳過 {skipped} 個非憑證檔）"

    seen.sort()
    secs, name = seen[0]
    days = secs / 86400.0
    tail = f"{len(seen)} 張憑證" + ("" if ubu_secs is not None else "（ubu 讀不到）")
    if days < 0:
        return FAIL, f"{name} 已過期 {abs(days):.0f} 天；{tail}"
    if days < CERT_WARN_DAYS:
        return WARN, f"{name} 剩 {days:.0f} 天（門檻 {CERT_WARN_DAYS}）；{tail}"
    return OK, f"最快到期的是 {name}，剩 {days:.0f} 天；{tail}"


# One definition, two readers. The Mac's disk and the production node's disk
# are different measurements of the same question, and two copies of these
# numbers would drift -- which is the failure statusdag/README.md lists four
# times over (a threshold in install.sh and again in its test, LINES here and
# again as a dashboard regex, RANK here and again as a Grafana mapping).
DISK_FAIL_PCT = 5
DISK_WARN_PCT = 15


def _disk_verdict(avail, size, label):
    pct = 100.0 * avail / size
    text = f"{label}可用 {avail / 1e9:.0f}G／{size / 1e9:.0f}G（{pct:.0f}%）"
    if pct < DISK_FAIL_PCT:
        return FAIL, text
    if pct < DISK_WARN_PCT:
        return WARN, text
    return OK, text


def probe_prod_node():
    """The production NODE, which is not the production cluster.

    `prodk8s` asks whether the API server answers and whether anything is
    running on it. Both can be true on a machine that is out of disk, under
    memory pressure, or that kubelet has started evicting from. They are
    different questions and they get different nodes, for the same reason the
    lab cluster and the prod cluster are not one node: a single node covering
    both goes green whenever EITHER answers.

    Read through kubectl rather than ssh, deliberately. The conditions are
    kubelet's own -- they are what will actually cause an eviction -- and the
    filesystem figures come from the same kubelet's stats endpoint, so this
    node reports what the thing making the decisions can see. An ssh + df
    would report a number nothing acts on.

    CONDITIONS ARE NOT ENOUGH ON THEIR OWN. DiskPressure only turns True at
    kubelet's eviction threshold, around 85-90% full: by then pods are already
    being killed. So the free-space percentage is judged too, at the same
    thresholds the Mac's disk uses, and it is the earlier of the two signals.
    """
    rc, out = run(["kubectl", "config", "get-contexts", "-o", "name"], timeout=10)
    if rc is None:
        return UNKNOWN, "kubectl 無法執行"
    if "ubu" not in (out or "").split():
        return UNKNOWN, "kubeconfig 裡沒有 ubu context（bootstrap_k3s.sh 尚未跑過）"

    rc, out, err = run_diag(["kubectl", "--context", "ubu", "--request-timeout=8s",
                             "get", "node", "-o", "json"], timeout=15)
    if rc != 0:
        return UNKNOWN, "生產節點讀不到：" + " ".join((err or "").split())[:70]
    try:
        items = json.loads(out or "{}").get("items") or []
    except json.JSONDecodeError:
        return UNKNOWN, "kubectl 回的不是 JSON"
    if not items:
        # A cluster with no nodes is not a healthy cluster; it is an answer
        # about nothing, and OK would be the vacuous green again.
        return UNKNOWN, "叢集回應了，但一個節點也沒有"

    bad, names = [], []
    for node in items:
        name = node.get("metadata", {}).get("name", "?")
        names.append(name)
        for c in node.get("status", {}).get("conditions") or []:
            t, v = c.get("type"), c.get("status")
            if t == "Ready" and v != "True":
                bad.append(f"{name} 未就緒（{c.get('reason', '?')}）")
            elif t in ("DiskPressure", "MemoryPressure", "PIDPressure") and v == "True":
                bad.append(f"{name} {t}")
    if bad:
        return FAIL, "；".join(bad[:3])

    # Free space, which turns amber long before kubelet starts evicting.
    worst = None
    for name in names:
        rc, out, _ = run_diag(
            ["kubectl", "--context", "ubu", "--request-timeout=8s", "get", "--raw",
             f"/api/v1/nodes/{name}/proxy/stats/summary"], timeout=15)
        if rc != 0:
            continue
        try:
            fs = json.loads(out or "{}").get("node", {}).get("fs") or {}
        except json.JSONDecodeError:
            continue
        avail, size = fs.get("availableBytes"), fs.get("capacityBytes")
        if not avail or not size:
            continue
        v = _disk_verdict(avail, size, f"{name} ")
        if worst is None or RANK.get(v[0], 0) > RANK.get(worst[0], 0):
            worst = v
    if worst is None:
        return WARN, f"{len(names)} 個節點條件正常，但讀不到磁碟用量——沒有量到就不是沒事"
    return worst


def probe_host_disk():
    """The number that stopped this whole platform once, and was not measured.

    Reads what host_disk_metrics.sh wrote rather than measuring again: the
    scheduler runs it every 300s (the shortest interval in jobs.conf) and a
    board that re-measured would disagree with the alert rule that fires on
    the same file. Staleness is therefore part of the verdict -- a fresh
    reading of a healthy disk and a two-hour-old reading of an unknown one are
    not the same claim.
    """
    path = os.path.join(EVIDENCE, "statusdag", "host_disk.prom")
    try:
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
    except OSError:
        return UNKNOWN, "host_disk.prom 不存在（disk job 從未跑過）"
    vals = {}
    for m in re.finditer(r"^(host_[a-z_]+)(?:\{[^}]*\})?\s+([0-9.e+]+)$", body, re.M):
        vals[m.group(1)] = float(m.group(2))
    size = vals.get("host_filesystem_size_bytes")
    avail = vals.get("host_filesystem_avail_bytes")
    gen = vals.get("host_disk_metrics_generated_seconds")
    if not size or avail is None:
        return UNKNOWN, "host_disk.prom 沒有大小/可用空間這兩個指標"
    age_min = ((datetime.now(timezone.utc).timestamp() - gen) / 60.0) if gen else None
    if age_min is not None and age_min > 30:
        return WARN, f"讀數已 {age_min:.0f} 分鐘沒更新（disk job 每 5 分鐘）"
    return _disk_verdict(avail, size, "")


def probe_secret_rotation():
    """Rotation coverage, not just the rotation verdict.

    PASS over 1 of 3 secrets and PASS over 3 of 3 print the same word, and the
    sweep already learned that lesson the hard way (see its own header: all
    three were once exempt and 'every non-exempt secret is within its
    interval' was true over the empty set). So this node reports the
    denominator, and refuses to call a sweep that checked nothing OK.
    """
    path = newest("vault/rotation_summary_*.json")
    data = load(path)
    if not data:
        return UNKNOWN, "沒有輪替掃描的證據（rotation job 每 7 天）"
    checked = data.get("checked_secrets")
    total = data.get("total_secrets")
    hours = age_hours(os.path.basename(path).replace(".json", "").split("_")[-1])
    verdict = data.get("gate_result")
    cover = f"檢查 {checked}/{total} 筆" + (f"，{data.get('exempt')} 筆豁免"
                                            if data.get("exempt") else "")
    if verdict == "FAIL":
        return FAIL, f"{data.get('due')} 筆逾期／{data.get('without_record')} 筆無紀錄；{cover}"
    if not checked:
        return WARN, f"這次掃描什麼都沒驗到（全部豁免）；{cover}"
    if hours is not None and hours > 24 * 10:
        return WARN, f"{cover}，但這份證據已 {hours / 24:.0f} 天"
    return OK, cover


IAC_DIR = os.path.join(REPO_ROOT, "platform", "iac")


def probe_iac():
    """Infrastructure-as-Code, which this board had no opinion about at all.

    `platform/statusdag/README.md` has carried "No `iac` node" as known gap #1
    since the layer existed, with the consequence written next to it: it is
    part of why platform/iac went unverified for months. The remote workflow
    checks it on push, but the board -- the thing a person actually looks at --
    could not tell you whether the layer even parsed.

    WHY NOT JUST READ THE WORKFLOW'S VERDICT. Because `gha` already does, and
    two nodes reporting one measurement is the "one definition, many readers"
    failure this directory's README warns about. This one runs the check
    locally, so it answers a different question: does the IaC in the WORKING
    TREE validate, right now, before it is pushed.

    NOT INITIALISED IS UNKNOWN, NOT OK. `tofu validate` without providers
    downloaded fails with a message about `tofu init`; treating that as a pass
    would be the exact vacuous green this platform keeps finding. The init
    command is named in the detail so the reader can act on it.
    """
    if not os.path.isdir(IAC_DIR):
        return UNKNOWN, "platform/iac 不存在"
    rc, out, err = run_diag(["sh", "-c", "command -v tofu || command -v terraform"],
                            timeout=8)
    if rc != 0 or not out:
        return UNKNOWN, "本機沒有 tofu/terraform，無法在推之前驗證"
    binary = out.strip().splitlines()[0]
    if not os.path.isdir(os.path.join(IAC_DIR, ".terraform")):
        return UNKNOWN, f"尚未 init：cd platform/iac && {os.path.basename(binary)} init"
    rc, out, err = run_diag([binary, "-chdir=" + IAC_DIR, "validate", "-json"],
                            timeout=60)
    try:
        report = json.loads(out or "{}")
    except json.JSONDecodeError:
        return UNKNOWN, "validate 的輸出不是 JSON：" + " ".join((err or "").split())[:80]
    if not report.get("valid"):
        first = ""
        for d in report.get("diagnostics") or []:
            first = (d.get("summary") or "")[:70]
            break
        return FAIL, f"{report.get('error_count', '?')} 個錯誤：{first}"
    rc_fmt, out_fmt, _ = run_diag([binary, "-chdir=" + IAC_DIR, "fmt",
                                   "-check", "-recursive"], timeout=30)
    warn = report.get("warning_count") or 0
    if rc_fmt != 0:
        files = " ".join((out_fmt or "").split())[:60] or "（未列出檔名）"
        return WARN, f"validate 通過，但格式未套用：{files}"
    return OK, f"validate 通過、格式一致" + (f"（{warn} 個警告）" if warn else "")


def probe_source_freshness():
    """Registered is not publishing.

    `probe_sources` counts rows in data_source and goes green at "22 個登記
    來源". That number cannot fall when a feed stops: a source that published
    nothing for a month is still registered, so the node stays green while the
    thing it is named after has stopped happening. This platform has met that
    shape repeatedly -- the Prometheus job watching a deleted service, the
    scheduler that detects a stopped job and not an absent one -- and this is
    the same shape in the data layer.

    The judgement is not "has it changed recently" but "has it changed within
    3x its OWN declared publication interval", because a yearly registry and a
    daily case count are both healthy at wildly different ages. That is the
    same expression as the SourcePublishedNothingNew alert rule, read from the
    same exported metrics, deliberately: two definitions of stale would drift
    apart and the board and the alert would start disagreeing.

    Retired sources are excluded. They are registered and deliberately no
    longer fetched, so counting them would make this node permanently amber
    for a state somebody chose.

    ZERO SOURCES IS UNKNOWN. A .prom with no source series means the exporter
    did not run or ran against nothing -- an answer about no sources, not an
    answer that no source is stale.
    """
    path = os.path.join(EVIDENCE, "statusdag", "dataops.prom")
    try:
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
    except OSError:
        return UNKNOWN, "dataops.prom 不存在（dataops 匯出器沒跑過）"

    def series(name):
        out = {}
        for m in re.finditer(r'^%s\{([^}]*)\}\s+([0-9.e+-]+)$' % name, body, re.M):
            labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
            if labels.get("source"):
                out[labels["source"]] = float(m.group(2))
        return out

    expected = series("dataops_source_expected_interval_seconds")
    unchanged = series("dataops_source_unchanged_seconds")
    retired = series("dataops_source_retired")
    live = {k: v for k, v in expected.items() if not retired.get(k)}
    if not live:
        return UNKNOWN, "dataops.prom 裡沒有任何在用的來源（匯出器對著空的跑）"

    stale = sorted(
        ((k, unchanged.get(k, 0.0) / 86400.0, v * 3 / 86400.0)
         for k, v in live.items() if unchanged.get(k, 0.0) > 3 * v),
        key=lambda r: -r[1])
    if not stale:
        return OK, f"{len(live)} 個在用來源都在自己的發布週期內"
    named = "、".join(f"{k}（{d:.1f} 天／門檻 {lim:.1f}）" for k, d, lim in stale[:3])
    more = f"，另 {len(stale) - 3} 個" if len(stale) > 3 else ""
    return WARN, f"{len(stale)}/{len(live)} 個來源超過 3 倍週期沒有新內容：{named}{more}"


def probe_prod_cluster():
    """The amd64 production cluster on ubu -- a SECOND machine, not a copy.

    Until 2026-09-03 nothing on this board knew ubu existed. That is the
    platform's oldest failure wearing a new hat: an unmonitored machine and a
    healthy one produce exactly the same board.

    THREE STATES, AND THE THIRD IS THE POINT.

      no context      the kubeconfig has no `ubu` entry at all. Distinct from
                      unreachable: one means never set up, the other means it
                      went away, and they need different actions.
      unreachable     the machine sleeps (it is a laptop with suspend still
                      enabled -- docs/Ubu-Prod-Bringup.md §3.1). WARN and not
                      FAIL because it carries no traffic yet; the day it does,
                      this must become FAIL and the runbook says so.
      ready, empty    WARN, deliberately. A reachable cluster running nothing
                      is the vacuous green this repo keeps catching: the
                      station1-hello rules stayed green for weeks by watching a
                      service that had been deleted, and looked healthiest at
                      the moment they had stopped monitoring anything. An empty
                      prod cluster proves the API server answers. It proves
                      nothing about prod.
    """
    rc, out = run(["kubectl", "config", "get-contexts", "-o", "name"], timeout=10)
    if rc is None:
        return UNKNOWN, "kubectl 無法執行"
    if "ubu" not in (out or "").split():
        return UNKNOWN, "kubeconfig 裡沒有 ubu context（bootstrap_k3s.sh 尚未跑過）"

    rc, _, err = run_diag(["kubectl", "--context", "ubu", "--request-timeout=8s",
                           "get", "--raw", "/readyz"], timeout=15)
    if rc != 0:
        # Report WHAT KUBECTL SAID, not a sentence we chose in advance.
        #
        # Only one cause is named here, and only because its message is
        # deterministic: a SAN mismatch always prints "certificate is valid
        # for". The timeout path is NOT branched on, deliberately -- the same
        # unreachable host was measured returning four different strings
        # ("context deadline exceeded", "request canceled while waiting for
        # connection", "no route to host", "Host is down"), so a branch on
        # those would be a guard that is right by luck. For everything else
        # the raw line is carried through: evidence the reader can act on
        # beats a cause we guessed.
        line = " ".join((err or "").split())[:110] or "無錯誤訊息"
        if "certificate is valid for" in (err or ""):
            return WARN, f"prod 叢集連不上：憑證 SAN 不符——{line}"
        return WARN, f"prod 叢集連不上（尚無工作負載，服務不受影響）：{line}"

    # THE SEPARATOR HAS TO SURVIVE PYTHON BEFORE IT REACHES KUBECTL.
    #
    # This was written as {'\n'} inside a normal double-quoted Python string,
    # so Python turned it into a REAL newline and kubectl received an
    # unterminated quoted string: rc=1, empty stdout, every time. The next line
    # then read that empty output as "no workloads" and the node reported
    # 「叢集就緒但沒有任何工作負載」-- a sentence that is also true when the
    # cluster genuinely has none, which is why it survived. Found 2026-09-08
    # while fixing the identical mistake in probe_bluegreen.
    rc, out = run(["kubectl", "--context", "ubu", "get", "deploy", "-A",
                   "--request-timeout=8s", "-o",
                   'jsonpath={range .items[*]}{.metadata.namespace}{"\\n"}{end}'],
                  timeout=15)
    if rc != 0:
        return WARN, "prod 叢集可連線，但列舉工作負載失敗——不能當成「沒有工作負載」"
    workloads = [n for n in (out or "").split() if n not in ("kube-system",)]
    if not workloads:
        return WARN, "叢集就緒但沒有任何工作負載——這裡的綠燈證不到任何服務"
    return OK, f"prod 叢集就緒，{len(workloads)} 個工作負載"


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
    colour = out.strip()

    # THE SELECTOR IS A POINTER, NOT A SERVICE.
    #
    # Reading it answers "which colour is traffic addressed to" and nothing
    # else. On 2026-09-08 migration 016 moved the database to schema 16 while
    # both colours were still deployed expecting 15; every pod answered 503,
    # the Service had no ready endpoint at all, and this node stayed GREEN
    # saying "traffic points at blue". It did point at blue. Blue was serving
    # nothing.
    #
    # Same shape as the model gate one layer up: a guard that refuses the bad
    # case is not a measurement that the good case is happening.
    rc2, pods = run(["kubectl", "--context", "k3d-devops-lab", "-n", "station2",
                     "get", "pods", "-l", f"app=station2-twin,color={colour}",
                     # Double quotes inside the jsonpath: kubectl's parser
                     # rejects the single-quoted form and exits non-zero, which
                     # this probe would have reported as "cannot tell".
                     "-o", 'jsonpath={range .items[*]}'
                     '{.status.containerStatuses[0].ready}{"\\n"}{end}'],
                    timeout=15)
    if rc2 is None or rc2 != 0:
        return WARN, f"目前流量指向 {colour}，但無法確認該顏色是否有就緒的 pod"
    states = [ln.strip() for ln in pods.splitlines() if ln.strip()]
    ready = sum(1 for st in states if st == "true")
    if not states:
        return WARN, f"Service 指向 {colour}，但該顏色一個 pod 都沒有"
    if ready == 0:
        return FAIL, (f"Service 指向 {colour}，但該顏色 {len(states)} 個 pod "
                      f"全部未就緒——流量有去處，沒有服務")
    if ready < len(states):
        return WARN, (f"目前流量指向 {colour}（{ready}/{len(states)} pod 就緒）")
    return OK, f"目前流量指向 {colour}（{ready}/{len(states)} pod 就緒）"


NODES = [
    # id,          label,               layer,          probe
    ("vault",      "Vault 機密/身分",     "foundation",  probe_vault),
    ("audit",      "稽核軌跡",            "foundation",  probe_audit),
    ("scheduler",  "排程器",              "foundation",  probe_scheduler),
    ("backup",     "備份",                "foundation",  probe_backup),
    ("restore",    "還原演練",            "foundation",  probe_restore_drill),
    # Three surfaces that had scripts and no node, added 2026-09-10. Each one
    # fails silently by construction: a certificate works perfectly until a
    # date somebody else chose; a disk is fine until the moment it stops the
    # whole platform; a rotation sweep prints PASS whether it checked three
    # secrets or none. All three were green the day they were added -- that is
    # the point of adding them BEFORE they are not.
    ("certs",      "憑證到期",            "foundation",  probe_certificates),
    ("hostdisk",   "主機磁碟",            "foundation",  probe_host_disk),
    ("rotation",   "機密輪替",            "foundation",  probe_secret_rotation),
    ("iac",        "IaC 驗證",            "foundation",  probe_iac),
    ("prodhost",   "prod 節點健康 (ubu)",  "k8s",        probe_prod_node),

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
    ("srcfresh",   "來源仍在發布",        "dataops",     probe_source_freshness),
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
    ("fcscore",    "預測事後評分",        "mlops",       probe_forecast_score),
    ("retrain",    "排程重訓",            "mlops",       probe_retrain),

    # --- Kubernetes（藍，A9/A10）-----------------------------------------
    ("k8s",        "k3d 叢集",            "k8s",         probe_k8s),
    ("bluegreen",  "藍綠切換",            "k8s",         probe_bluegreen),
    # The second machine (ADR-0008). Separate node rather than folded into
    # `k8s`: they are different architectures on different hardware, and one
    # node covering both would go green whenever EITHER answered -- which is
    # how a cluster disappears without the board changing colour.
    ("prodk8s",    "prod 叢集 (ubu/amd64)", "k8s",       probe_prod_cluster),
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
    ("forecast", "fcscore"),
    ("scheduler", "retrain"),
    ("retrain", "backtest"),

    # Kubernetes: 叢集是藍綠的底座；藍綠取代了 Compose 的 promote 路徑。
    ("k8s", "bluegreen"),
    ("registry", "bluegreen"),

    # prodk8s HAS NO EDGE, AND THAT IS THE ACCURATE STATE.
    #
    # It renders as an isolated node, which looks like an omission and is not.
    # Nothing depends on the prod cluster because nothing runs there yet, and
    # the prod cluster depends on the amd64 build chain -- which has no node,
    # because .github/workflows/pilot-image.yml has never executed.
    #
    # The tempting edge is ("registry", "prodk8s"). It would be false: that
    # registry is the k3d one on this Mac, serving arm64 images the amd64 node
    # cannot run. Drawing it would assert exactly the dependency ADR-0008
    # exists to deny, and an impact analysis built on it would be confidently
    # wrong. The edge appears when the ghcr chain has run once and there is
    # something real to point at.
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

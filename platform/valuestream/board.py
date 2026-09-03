#!/usr/bin/env python3
"""Value stream board -- DERIVED, never hand-maintained.

DORA separates this from system observability on purpose: the object under
observation is the flow of work, not a running service, and the audience is
whoever needs to see where work is stuck. See
https://dora.dev/capabilities/visibility-of-work-in-the-value-stream/

The one design decision everything else follows from: **every column is
computed from evidence the pipeline already produces**. A board someone has
to remember to drag cards across is a board that is quietly wrong within a
week, and a wrong board is worse than none because people trust it. Here,
"deployed to develop" means `deploy_develop_<sha>.json` exists and says
healthy -- there is no way for the board to disagree with reality.

DORA also warns against visualising only the slice one team owns, because
bottlenecks then hide in the parts nobody drew. So the stream runs from
commit all the way to production incidents, crossing CI, human approval and
runtime -- not just the build.

Usage:
  board.py [--json] [--out <path.html>]
"""

import argparse
import glob
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from datetime import datetime, timezone

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ALERTMANAGER = os.environ.get("ALERTMANAGER_URL", "http://127.0.0.1:19093")
COMMIT_WINDOW = 25

# WIP limits. DORA is explicit that the purpose is to EXPOSE PROBLEMS, not to
# make people work faster -- a column sitting over its limit is a signal that
# work is piling up somewhere, which is information, not a scolding.
WIP_LIMITS = {
    "built": 5,
    "develop": 3,
    "awaiting_approval": 2,
}

STAGES = [
    ("committed", "已提交", "有 commit，尚未建置"),
    ("built", "已建置", "映像已建置並通過掃描閘門"),
    ("develop", "develop 已部署", "已部署且健康檢查通過"),
    ("awaiting_approval", "待人工核可", "證據齊備，等待真人 PROMOTE"),
    ("live", "已上線", "production-like 正在服務"),
    ("incident", "線上異常", "Alertmanager 目前有告警"),
]


def git(*args):
    result = subprocess.run(
        ["git", "-C", REPO_ROOT, *args], capture_output=True, text=True
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def load_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def collect_commits():
    """Recent commits, newest first, as {sha: {subject, when}}."""
    raw = git("log", f"-{COMMIT_WINDOW}", "--format=%h%x1f%s%x1f%cI")
    commits = {}
    for line in raw.splitlines():
        parts = line.split("\x1f")
        if len(parts) == 3:
            sha, subject, when = parts
            commits[sha] = {"sha": sha, "subject": subject, "committed_at": when}
    return commits


def collect_evidence():
    """Per-pilot, per-sha evidence presence. Evidence IS the state."""
    state = {}
    evidence_root = os.path.join(REPO_ROOT, "evidence")
    if not os.path.isdir(evidence_root):
        return state

    for pilot in sorted(os.listdir(evidence_root)):
        pilot_dir = os.path.join(evidence_root, pilot)
        if not os.path.isdir(pilot_dir) or pilot in ("security", "observability"):
            continue

        for path in sorted(glob.glob(os.path.join(pilot_dir, "build_*.json"))):
            sha = re.sub(r"^build_|\.json$", "", os.path.basename(path))
            entry = state.setdefault((pilot, sha), {"pilot": pilot, "sha": sha})
            data = load_json(path) or {}
            entry["built_at"] = data.get("build_timestamp")
            entry["image_digest"] = data.get("image_digest")

        for path in sorted(glob.glob(os.path.join(pilot_dir, "deploy_develop_*.json"))):
            sha = re.sub(r"^deploy_develop_|\.json$", "", os.path.basename(path))
            entry = state.setdefault((pilot, sha), {"pilot": pilot, "sha": sha})
            data = load_json(path) or {}
            entry["develop_health"] = data.get("health_status")
            entry["deployed_at"] = data.get("deployed_at")

        for path in sorted(glob.glob(os.path.join(pilot_dir, "llm_review_*.json"))):
            sha = os.path.basename(path).split("_")[2]
            entry = state.setdefault((pilot, sha), {"pilot": pilot, "sha": sha})
            data = load_json(path) or {}
            if data.get("status") == "OK":
                entry["llm_verdict"] = data.get("verdict")

        for path in sorted(glob.glob(os.path.join(pilot_dir, "promote_*.json"))):
            sha = os.path.basename(path).split("_")[1]
            entry = state.setdefault((pilot, sha), {"pilot": pilot, "sha": sha})
            data = load_json(path) or {}
            entry["promoted_at"] = data.get("promoted_at")
            entry["active_color"] = data.get("active_color")

        live = load_json(os.path.join(pilot_dir, "production_like_state.json"))
        if live and live.get("promoted_sha"):
            key = (pilot, live["promoted_sha"])
            entry = state.setdefault(key, {"pilot": pilot, "sha": live["promoted_sha"]})
            entry["is_live"] = True
            entry["active_color"] = live.get("active_color")

    return state


def collect_alerts():
    """Production incidents. Unreachable Alertmanager is reported as unknown,
    never as zero -- 'no alerts' from a dead monitor is not 'no incidents'."""
    try:
        with urllib.request.urlopen(
            f"{ALERTMANAGER.rstrip('/')}/api/v2/alerts?active=true", timeout=5
        ) as response:
            return json.load(response), None
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        return None, str(exc)


def stage_for(entry):
    """Furthest stage this work item has reached."""
    if entry.get("is_live"):
        return "live"
    if entry.get("develop_health") == "healthy":
        # Evidence complete and waiting on a human is a DIFFERENT state from
        # merely deployed, and conflating them hides the queue that human
        # approval creates -- which is exactly the bottleneck DORA's
        # "streamlining change approval" capability is about.
        if entry.get("llm_verdict"):
            return "awaiting_approval"
        return "develop"
    if entry.get("built_at"):
        return "built"
    return "committed"


def lead_times(items):
    """commit -> promote, in hours. The DORA lead-time metric."""
    values = []
    for item in items:
        if item.get("promoted_at") and item.get("committed_at"):
            try:
                start = datetime.fromisoformat(item["committed_at"])
                end = datetime.fromisoformat(item["promoted_at"].replace("Z", "+00:00"))
                values.append((end - start).total_seconds() / 3600)
            except ValueError:
                continue
    return values


def collect_scheduler():
    """Scheduled-job freshness. A board that shows a green pipeline while the
    checks feeding it stopped running days ago is worse than no board, so the
    scheduler's own liveness is shown alongside the work."""
    state_dir = os.path.join(REPO_ROOT, "evidence", "scheduler")
    conf = os.path.join(REPO_ROOT, "platform", "scheduler", "jobs.conf")
    if not os.path.isfile(conf):
        return []
    now = datetime.now(timezone.utc)
    jobs = []
    for line in open(conf, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, interval, _, _ = line.split("|", 3)
        interval = int(interval)
        state = load_json(os.path.join(state_dir, f"{name}_last.json"))
        if not state:
            jobs.append({"job": name, "status": "never-run", "fresh": False,
                         "age_hours": None})
            continue
        try:
            started = datetime.strptime(state["started_at"], "%Y-%m-%dT%H:%M:%SZ")
            started = started.replace(tzinfo=timezone.utc)
            age = (now - started).total_seconds()
        except (KeyError, ValueError):
            age = None
        jobs.append({
            "job": name,
            "status": state.get("status", "unknown"),
            "fresh": age is not None and age <= interval * 2 + 60,
            "age_hours": round(age / 3600, 1) if age is not None else None,
        })
    return jobs


def collect_notifications(limit=5):
    path = os.path.join(REPO_ROOT, "evidence", "scheduler", "notifications.jsonl")
    if not os.path.isfile(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out[-limit:]


# THE BOARD CAN ONLY BE AS TRUE AS THE EVIDENCE IT READS (2026-09-02).
#
# Every item on this board sits in "committed", there have been zero
# promotions, and the median lead time is "no data". Read at face value that
# says the platform never ships anything. It is not what happened.
#
# `deploy_develop_<sha>.json` is written by `platform/compose/deploy.sh`. The
# pilot's deploy path moved to Kubernetes (ADR-0010), and the k8s path does not
# write that evidence file. So the contract this board reads is no longer
# produced by the thing that deploys, and the board renders the resulting
# silence as a measured funnel with everything stuck at the top.
#
# That is the vacuity failure inverted: not a green derived from an empty set,
# but a RED derived from one -- and the red is more convincing, because an
# empty pipeline looks exactly like a stalled one. So the board says which it
# is, rather than leaving the reader to assume the worse and wrong reading.
DEPLOY_EVIDENCE_WRITER = "platform/compose/deploy.sh"
CURRENT_DEPLOY_PATH = "platform/k8s/station2-twin/deploy.sh"


def deploy_feed():
    """Is anything currently writing the evidence contract this board reads?

    Retired pilots live one directory deeper under evidence/_retired/, so they
    do not count -- a board fed only by a pilot that was retired weeks ago is
    starved, not healthy.
    """
    root = os.path.join(REPO_ROOT, "evidence")
    active = sorted(glob.glob(os.path.join(root, "*", "deploy_develop_*.json")))
    retired = sorted(glob.glob(os.path.join(root, "_retired", "*", "deploy_develop_*.json")))
    return {
        "active_files": len(active),
        "retired_files": len(retired),
        "starved": len(active) == 0,
        "writer": DEPLOY_EVIDENCE_WRITER,
        "current_deploy_path": CURRENT_DEPLOY_PATH,
    }


def build_board():
    commits = collect_commits()
    evidence = collect_evidence()
    alerts, alert_error = collect_alerts()

    items = []
    for (pilot, sha), entry in evidence.items():
        merged = dict(entry)
        commit = commits.get(sha)
        if commit:
            merged["subject"] = commit["subject"]
            merged["committed_at"] = commit["committed_at"]
        merged["stage"] = stage_for(merged)
        items.append(merged)

    # Recent commits with no evidence at all: real work-in-progress that a
    # board built only from evidence would render invisible.
    seen = {item["sha"] for item in items}
    for sha, commit in commits.items():
        if sha not in seen:
            items.append({**commit, "pilot": "—", "stage": "committed"})

    items.sort(key=lambda i: i.get("committed_at") or "", reverse=True)

    columns = {key: [] for key, _, _ in STAGES}
    for item in items:
        columns[item["stage"]].append(item)

    incidents = []
    if alerts:
        for alert in alerts:
            incidents.append({
                "subject": alert["labels"].get("alertname"),
                "pilot": alert["labels"].get("service", "—"),
                "severity": alert["labels"].get("severity"),
                "summary": alert.get("annotations", {}).get("summary"),
                "runbook": alert.get("annotations", {}).get("runbook"),
                "stage": "incident",
            })
    columns["incident"] = incidents

    times = lead_times(items)
    promoted = [i for i in items if i.get("promoted_at")]
    scheduler = collect_scheduler()
    notifications = collect_notifications()

    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "columns": columns,
        "wip_limits": WIP_LIMITS,
        "wip_breaches": [
            {"stage": key, "count": len(columns[key]), "limit": limit}
            for key, limit in WIP_LIMITS.items()
            if len(columns[key]) > limit
        ],
        "metrics": {
            "lead_time_hours_median": (
                round(sorted(times)[len(times) // 2], 1) if times else None
            ),
            "promotions_total": len(promoted),
            "items_tracked": len(items),
        },
        "alert_source": (
            {"ok": True} if alerts is not None else {"ok": False, "error": alert_error}
        ),
        "deploy_feed": deploy_feed(),
        "scheduler": scheduler,
        "scheduler_stale": [j["job"] for j in scheduler if not j["fresh"]],
        "notifications": notifications,
    }


# --------------------------------------------------------------------------
# Rendering. The palette and type treatment originated in the hand-curated
# docs/System-State.html, deleted 2026-09-02 for being a stale status page; the
# treatment stayed because it is the one the other generated views use.
# on purpose: the platform's documents should read as one family, so a reader
# who has seen one already knows how to read the other.
# --------------------------------------------------------------------------

STAGE_TONE = {
    "committed": "neutral",
    "built": "neutral",
    "develop": "progress",
    "awaiting_approval": "waiting",
    "live": "good",
    "incident": "bad",
}


def esc(text):
    return (
        str(text if text is not None else "")
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )


def render_html(board):
    cols = []
    for key, title, hint in STAGES:
        items = board["columns"][key]
        limit = board["wip_limits"].get(key)
        over = limit is not None and len(items) > limit
        cards = []
        for item in items:
            meta = []
            if item.get("pilot") and item["pilot"] != "—":
                meta.append(esc(item["pilot"]))
            if item.get("sha"):
                meta.append(f'<code>{esc(item["sha"])}</code>')
            if item.get("llm_verdict"):
                meta.append(f'LLM {esc(item["llm_verdict"])}')
            if item.get("active_color"):
                meta.append(esc(item["active_color"]))
            if item.get("severity"):
                meta.append(esc(item["severity"]))
            extra = (
                f'<p class="card-sub">{esc(item["summary"])}</p>'
                if item.get("summary") else ""
            )
            cards.append(
                f'<article class="card t-{STAGE_TONE[key]}">'
                f'<p class="card-title">{esc(item.get("subject") or item.get("sha") or "—")}</p>'
                f"{extra}"
                f'<p class="card-meta">{" · ".join(meta)}</p>'
                "</article>"
            )
        if not cards:
            cards.append('<p class="empty">—</p>')
        badge = (
            f'<span class="wip over">WIP {len(items)}/{limit}</span>' if over
            else f'<span class="wip">WIP {len(items)}/{limit}</span>' if limit
            else f'<span class="wip">{len(items)}</span>'
        )
        cols.append(
            f'<section class="col"><header><h2>{esc(title)}</h2>{badge}'
            f'<p class="hint">{esc(hint)}</p></header>'
            f'<div class="cards">{"".join(cards)}</div></section>'
        )

    metrics = board["metrics"]
    lead = metrics["lead_time_hours_median"]
    lead_text = f"{lead} 小時" if lead is not None else "尚無資料"

    breaches = ""
    if board["wip_breaches"]:
        rows = "、".join(
            f'{b["stage"]}（{b["count"]}/{b["limit"]}）' for b in board["wip_breaches"]
        )
        breaches = (
            f'<div class="banner warn"><strong>WIP 超限：</strong>{esc(rows)}。'
            "DORA：WIP 限制的用途是讓問題浮現，不是要求做更快——超限代表工作正在某處堆積。</div>"
        )

    sched = board.get("scheduler") or []
    sched_html = ""
    if sched:
        chips = []
        for j in sched:
            if not j["fresh"]:
                tone, label = "bad", "未執行"
            elif j["status"] in ("critical", "failed", "timeout"):
                tone, label = "bad", j["status"]
            elif j["status"] in ("degraded", "unknown"):
                tone, label = "warn", j["status"]
            else:
                tone, label = "good", j["status"]
            age = f"{j['age_hours']}h" if j["age_hours"] is not None else "—"
            chips.append(
                f'<span class="sched s-{tone}"><b>{esc(j["job"])}</b> {esc(label)}'
                f'<i>{esc(age)}</i></span>')
        stale = board.get("scheduler_stale") or []
        warn = ""
        if stale:
            warn = ('<p class="sched-warn">排程器無法回報自己的缺席——'
                    f'<b>{esc("、".join(stale))}</b> 未在預期時間內執行。'
                    '空白的看板欄位可能只是沒人在跑檢查。</p>')
        sched_html = (f'<section class="sched-strip"><h2>排程器</h2>'
                      f'<div class="sched-row">{"".join(chips)}</div>{warn}</section>')

    notes = board.get("notifications") or []
    notes_html = ""
    if notes:
        rows = "".join(
            f'<li class="n-{esc(n.get("severity","info"))}">'
            f'<code>{esc(n.get("at","")[:16].replace("T"," "))}</code> '
            f'{esc(n.get("summary",""))}</li>'
            for n in reversed(notes))
        notes_html = (f'<section class="sched-strip"><h2>近期狀態轉換</h2>'
                      f'<ul class="notes">{rows}</ul></section>')

    # A starved board must say so on its face. A reader who sees "0 次上線"

    # on a page titled 價值流看板 will conclude the platform does not ship,

    # and that conclusion is wrong in the most damaging possible direction.

    feed = board["deploy_feed"]

    feed_note = ""

    if feed["starved"]:

        feed_note = (

            '<p class="feednote"><b>這張看板目前收不到部署證據。</b>'

            '「已部署／已上線」欄位靠 <code>deploy_develop_&lt;sha&gt;.json</code> 判斷，'

            f'而目前有效的 pilot 一個都沒有（退役的 station1-hello 還有 {feed["retired_files"]} 份，不計入）。'

            f'寫這份證據的是 <code>{esc(feed["writer"])}</code>，但 pilot 的部署路徑已改走 Kubernetes'

            f'（<code>{esc(feed["current_deploy_path"])}</code>），而 K8s 路徑沒有寫這份契約。'

            '所以下游全空<b>不代表沒有東西上線</b>，代表這條線的量測斷了——'

            '在接回來之前，不要把「0 次上線」當成量測結果。</p>')

    alert_note = ""
    if not board["alert_source"]["ok"]:
        alert_note = (
            '<div class="banner bad"><strong>線上異常欄無法判定：</strong>'
            f'Alertmanager 無法連線（{esc(board["alert_source"]["error"])}）。'
            "此欄為空<em>不代表</em>沒有異常。</div>"
        )

    return f"""<title>價值流看板</title>
<style>
:root {{
  --ground:#F7F8F9; --surface:#FFFFFF; --sunk:#EFF2F4; --ink:#16202B;
  --muted:#5A6875; --faint:#8794A1; --rule:#DDE3E8; --accent:#0F6E6B;
  --good:#2F7D4F; --good-s:#E1EFE6; --warn:#B07A16; --warn-s:#F7EEDA;
  --bad:#A03C3C; --bad-s:#F5E4E4; --prog:#2A5F8F; --prog-s:#E2EAF3;
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --ground:#10161C; --surface:#171F27; --sunk:#1E2831; --ink:#E3E9EE;
    --muted:#9AA8B4; --faint:#6E7D8A; --rule:#2A353F; --accent:#4FB3AF;
    --good:#6BBF8B; --good-s:#17301F; --warn:#D9A945; --warn-s:#302711;
    --bad:#D97676; --bad-s:#331B1B; --prog:#79A9D6; --prog-s:#16283A;
  }}
}}
:root[data-theme="dark"] {{
  --ground:#10161C; --surface:#171F27; --sunk:#1E2831; --ink:#E3E9EE;
  --muted:#9AA8B4; --faint:#6E7D8A; --rule:#2A353F; --accent:#4FB3AF;
  --good:#6BBF8B; --good-s:#17301F; --warn:#D9A945; --warn-s:#302711;
  --bad:#D97676; --bad-s:#331B1B; --prog:#79A9D6; --prog-s:#16283A;
}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--ground);color:var(--ink);
 font-family:-apple-system,BlinkMacSystemFont,"Noto Sans TC","PingFang TC",sans-serif;
 line-height:1.6;-webkit-font-smoothing:antialiased}}
.wrap{{max-width:1400px;margin:0 auto;padding:40px 24px 72px}}
.eyebrow{{font-family:ui-monospace,Menlo,monospace;font-size:11px;letter-spacing:.14em;
 text-transform:uppercase;color:var(--accent);margin:0 0 10px}}
h1{{font-size:clamp(26px,3.4vw,36px);font-weight:800;letter-spacing:-.025em;margin:0 0 10px}}
.lede{{color:var(--muted);max-width:64ch;margin:0 0 22px;font-size:15.5px}}
.strip{{display:flex;flex-wrap:wrap;gap:10px 30px;padding:14px 0;border-top:1px solid var(--rule);
 border-bottom:1px solid var(--rule);font-family:ui-monospace,Menlo,monospace;font-size:12.5px;
 color:var(--faint);font-variant-numeric:tabular-nums}}
.feednote{{margin:1rem 0;padding:.8rem 1rem;border-left:3px solid #A8372C;background:#FDF6F5;font-size:.85rem;line-height:1.6}}
.strip b{{color:var(--ink);font-weight:600}}
.banner{{margin:20px 0 0;padding:13px 18px;border-left:3px solid var(--warn);
 background:var(--warn-s);font-size:14.5px;border-radius:0 3px 3px 0}}
.banner.bad{{border-left-color:var(--bad);background:var(--bad-s)}}
.board{{display:grid;grid-template-columns:repeat(6,minmax(210px,1fr));gap:14px;margin-top:26px;
 overflow-x:auto;padding-bottom:8px}}
.col{{background:var(--sunk);border:1px solid var(--rule);border-radius:3px;padding:14px;
 display:flex;flex-direction:column;gap:12px;min-width:210px}}
.col header{{display:grid;gap:4px}}
.col h2{{font-size:13.5px;font-weight:700;letter-spacing:-.01em;margin:0}}
.wip{{font-family:ui-monospace,Menlo,monospace;font-size:10.5px;color:var(--faint);
 font-variant-numeric:tabular-nums}}
.wip.over{{color:var(--warn);font-weight:700}}
.hint{{font-size:11.5px;color:var(--faint);margin:0}}
.cards{{display:flex;flex-direction:column;gap:9px}}
.card{{background:var(--surface);border:1px solid var(--rule);border-left:3px solid var(--faint);
 border-radius:2px;padding:10px 12px}}
.card.t-progress{{border-left-color:var(--prog)}}
.card.t-waiting{{border-left-color:var(--warn)}}
.card.t-good{{border-left-color:var(--good)}}
.card.t-bad{{border-left-color:var(--bad)}}
.card-title{{margin:0;font-size:13.5px;font-weight:600;line-height:1.4;
 overflow-wrap:anywhere}}
.card-sub{{margin:5px 0 0;font-size:12.5px;color:var(--muted)}}
.card-meta{{margin:7px 0 0;font-family:ui-monospace,Menlo,monospace;font-size:11px;
 color:var(--faint)}}
.card-meta code{{font-size:11px}}
.empty{{margin:0;color:var(--faint);font-size:13px;text-align:center;padding:10px 0}}
footer{{margin-top:44px;padding-top:18px;border-top:1px solid var(--rule);
 font-size:13px;color:var(--faint)}}
a{{color:var(--accent)}}
.sched-strip{{margin-top:30px;padding-top:18px;border-top:1px solid var(--rule)}}
.sched-strip h2{{font-size:11px;font-weight:700;letter-spacing:.12em;
 text-transform:uppercase;color:var(--muted);margin:0 0 12px}}
.sched-row{{display:flex;flex-wrap:wrap;gap:8px}}
.sched{{display:inline-flex;align-items:baseline;gap:6px;padding:4px 10px;
 border-radius:2px;font-size:12px;font-family:ui-monospace,Menlo,monospace;
 border:1px solid var(--rule)}}
.sched b{{font-weight:700}}
.sched i{{font-style:normal;opacity:.65;font-size:11px}}
.s-good{{background:var(--good-s);color:var(--good)}}
.s-warn{{background:var(--warn-s);color:var(--warn)}}
.s-bad{{background:var(--bad-s);color:var(--bad)}}
.sched-warn{{margin:12px 0 0;padding:11px 16px;border-left:3px solid var(--bad);
 background:var(--bad-s);font-size:13.5px;border-radius:0 3px 3px 0}}
.notes{{margin:0;padding:0;list-style:none;display:flex;flex-direction:column;gap:5px}}
.notes li{{font-size:13px;padding:5px 10px;border-left:3px solid var(--faint);
 background:var(--surface);border-radius:0 2px 2px 0}}
.notes code{{font-size:11.5px;color:var(--faint);margin-right:8px}}
.n-critical{{border-left-color:var(--bad)}}
.n-warning{{border-left-color:var(--warn)}}
.n-recovered{{border-left-color:var(--good)}}
</style>
<div class="wrap">
<p class="eyebrow">價值流 · 衍生自實際證據</p>
<h1>價值流看板</h1>
<p class="lede">每一欄都由平台已產出的證據推導，沒有人需要拖卡片。
「develop 已部署」代表 <code>deploy_develop_&lt;sha&gt;.json</code> 存在且健康——
看板無法與現實不一致。</p>
<div class="strip">
  <span><b>{esc(metrics["items_tracked"])}</b> 追蹤中項目</span>
  <span>前置時間中位數 <b>{esc(lead_text)}</b></span>
  <span><b>{esc(metrics["promotions_total"])}</b> 次上線</span>
  <span>產生於 <b>{esc(board["generated_at"])}</b></span>
</div>
{breaches}
{feed_note}
{alert_note}
<div class="board">{"".join(cols)}</div>
{sched_html}
{notes_html}
<footer>由 <code>platform/valuestream/board.py</code> 產生。
分類依據 <a href="https://dora.dev/capabilities/work-visibility-in-value-stream/">DORA
Visibility of work in the value stream</a>：價值流必須畫到端點，只畫自己負責的一段會讓瓶頸藏在沒畫的地方。</footer>
</div>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--out", default=os.path.join(REPO_ROOT, "docs", "Value-Stream-Board.html")
    )
    args = parser.parse_args()

    board = build_board()

    if args.json:
        print(json.dumps(board, indent=2, ensure_ascii=False))
        return

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(render_html(board))

    for key, title, _ in STAGES:
        count = len(board["columns"][key])
        limit = board["wip_limits"].get(key)
        flag = "  <-- over WIP limit" if limit and count > limit else ""
        print(f"  {title:<16} {count:>3}{flag}")
    if not board["alert_source"]["ok"]:
        print(f"  WARNING: alert source unreachable ({board['alert_source']['error']})")
    print(f"\nartifact={args.out}")


if __name__ == "__main__":
    main()

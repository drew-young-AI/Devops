#!/usr/bin/env python3
"""Stage-level status report for a stage review, with the diagrams beside it.

WHY THIS EXISTS SEPARATELY FROM dag.py's OWN PAGE.

dag.py renders an engineer's board: every node, every container, one row each.
That is the right shape for the person on call and the wrong shape for a stage
review. "Grafana 檢視 — running" tells a reviewer nothing they can act on; it is
tool status, not stage status.

So this page reorganises the SAME live probes into the unit a reviewer thinks
in -- the STAGE -- and pairs each line with its architecture and flow diagram.
A stage is green only if every node under it is green, and the page names which
node is responsible when it is not. Nothing here is hand-written status: every
light comes from dag.build(), which queries the database and the cluster at the
moment this runs.

WHY IT IS GENERATED RATHER THAN WRITTEN.

A written status document is accurate on the day it is written and misleading
from the next. This one is regenerated, and its header carries the timestamp it
was generated at, so a stale copy announces itself.

Usage:
  platform/statusdag/stage_report.py            # -> docs/Stage-Report.html
"""
from __future__ import annotations

import html
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DIAGRAMS = os.path.join(REPO_ROOT, "docs", "diagrams")
OUT = os.path.join(REPO_ROOT, "docs", "Stage-Report.html")

_spec = importlib.util.spec_from_file_location("dag", os.path.join(HERE, "dag.py"))
dag = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dag)


# --------------------------------------------------------------------------
# Stage map. Nodes are grouped into the stages a reviewer asks about.
#
# The grouping is not cosmetic: it decides what a single light means. Four
# separate rows saying "Prometheus running / Loki running / Grafana running /
# Alertmanager no alerts" answer "which containers are up". One row saying
# "觀測" answers "can we see what the platform is doing", which is the question
# actually being asked.
# --------------------------------------------------------------------------

LINES = [
    ("devops", "DevOps", "交付與維運", [
        ("基礎",       ["vault", "audit", "scheduler"],
         "機密、身分、稽核軌跡與排程器——其他每一段都站在這上面"),
        ("原始碼閘門",  ["sast", "secrets"],
         "進建置之前擋下：原始碼弱點與歷史中的秘密"),
        ("建置與映像",  ["ci", "trivy", "registry"],
         "編譯、映像漏洞掃描、推送到 registry"),
        ("部署",       ["k8s", "bluegreen", "develop"],
         "Kubernetes 底座與藍綠切換（切換是改 Service 指向，不是滾動更新）"),
        ("驗證",       ["dast", "llmreview"],
         "對執行中的系統掃描，以及模型複審"),
        ("人工關卡",    ["gate"],
         "上 production-like 需要真人按下去，刻意不自動"),
        ("上線",       ["prodlike", "nginx"],
         "對外服務與入口"),
        ("觀測",       ["prometheus", "loki", "alertmgr", "grafana"],
         "指標、日誌、告警、檢視——平台能不能看見自己"),
        ("備份與還原",  ["backup", "restore"],
         "備份覆蓋率不得有漏；沒還原過的備份不算備份"),
    ]),
    ("dataops", "DataOps", "資料工程", [
        ("來源與權威",  ["sources", "geo"],
         "來源以列舉發現而非猜 URL；地理對照每筆帶證據"),
        ("載入",       ["facts"],
         "同一張事實表容納縣市×週、鄉鎮×年、鄉鎮×日"),
        ("血緣",       ["lineage"],
         "檔案列數 = 接受 + 拒絕 + 重複，是資料庫約束不是報表"),
        ("契約",       ["dcontract"],
         "資料契約進 CI；資料庫缺席時失敗而不是跳過"),
        ("時間軸對照",  ["epiweek"],
         "流行病學週要對得上日曆日，週資料與日資料才能結合"),
    ]),
    ("mlops", "MLOps", "模型維運", [
        ("特徵",       ["features"],
         "特徵集綁定產生它的程式碼雜湊"),
        ("回測",       ["backtest"],
         "rolling-origin，與兩個天真基準在同一批折上評分"),
        ("上線閘門",    ["mgate"],
         "輸了不准上線，是資料庫觸發器不是團隊慣例"),
        ("發布",       ["forecast"],
         "API 只做查詢，服務路徑不載入模型"),
        ("重訓",       ["retrain"],
         "每週排程；日曆觸發已實測，不是手動跑過就算"),
    ]),
]

STATE_ORDER = {dag.OK: 0, dag.SUPERSEDED: 1, dag.WARN: 2, dag.UNKNOWN: 3, dag.FAIL: 4}
STATE_LABEL = {dag.OK: "正常", dag.SUPERSEDED: "已被取代", dag.WARN: "注意",
               dag.UNKNOWN: "無法判定", dag.FAIL: "失敗"}
# A superseded stage is not something to act on -- it is a stage that moved.
# Keeping it out of the attention list is the whole reason the state exists:
# five permanently-amber migration rows were crowding out the two that need a
# decision, and an attention list nobody can act on stops being read.
ACTIONABLE = (dag.WARN, dag.UNKNOWN, dag.FAIL)


def esc(text):
    return html.escape(str(text), quote=True)


def svg_of(name):
    """Inline the diagram's SVG. Returns None rather than a placeholder if the
    file is missing -- a report that silently shows an empty frame where a
    diagram should be is worse than one that says the diagram is absent."""
    path = os.path.join(DIAGRAMS, name)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        match = re.search(r"<svg\b.*?</svg>", fh.read(), re.S)
    return match.group(0) if match else None


def stage_state(nodes):
    """Worst node wins. A stage with one failing node is not 'mostly fine'."""
    if not nodes:
        return dag.UNKNOWN
    return max((n["state"] for n in nodes), key=lambda s: STATE_ORDER[s])


def render():
    board = dag.build()
    by_id = {n["id"]: n for n in board["nodes"]}

    line_html = []
    attention = []          # every non-green stage, for the summary at the end
    totals = {}

    for line_id, line_name, line_sub, stages in LINES:
        green = 0
        superseded = 0
        stage_rows = []
        for stage_name, node_ids, why in stages:
            nodes = [by_id[i] for i in node_ids if i in by_id]
            state = stage_state(nodes)
            if state == dag.OK:
                green += 1
            elif state == dag.SUPERSEDED:
                superseded += 1
            if state in ACTIONABLE:
                attention.append((line_name, stage_name, state, nodes))
            node_html = "".join(
                f'<li class="n s-{esc(n["state"])}">'
                f'<span class="nl">{esc(n["label"])}</span>'
                f'<span class="nd">{esc(n["detail"])}</span></li>'
                for n in nodes)
            stage_rows.append(
                f'<article class="stage s-{esc(state)}">'
                f'  <header><h4>{esc(stage_name)}</h4>'
                f'  <span class="pill">{esc(STATE_LABEL[state])}</span></header>'
                f'  <p class="why">{esc(why)}</p>'
                f'  <ul class="nodes">{node_html}</ul>'
                f'</article>')
        totals[line_name] = (green, len(stages), superseded)
        # Named on the line header too, not only in the global tally: a reader
        # who sees "4 / 9" without it will assume five things are broken.
        sup_note = f"，{superseded} 已被取代" if superseded else ""

        arch = svg_of(f"{line_id}-architecture.html")
        flow = svg_of(f"{line_id}-flow.html")
        figs = ""
        for title, svg in (("架構", arch), ("流程", flow)):
            if svg:
                figs += (f'<figure><figcaption>{esc(line_name)} {esc(title)}圖</figcaption>'
                         f'<div class="canvas">{svg}</div></figure>')
            else:
                figs += (f'<figure><figcaption>{esc(line_name)} {esc(title)}圖</figcaption>'
                         f'<p class="missing">圖檔不存在（docs/diagrams/）</p></figure>')

        line_html.append(
            f'<section class="line" data-line="{esc(line_id)}">'
            f'  <header class="line-head">'
            f'    <div><p class="eyebrow">{esc(line_sub)}</p>'
            f'    <h2>{esc(line_name)}</h2></div>'
            f'    <span class="score">{green} / {len(stages)}'
            f'<small>階段正常{sup_note}</small></span>'
            f'  </header>'
            f'  <div class="figs">{figs}</div>'
            f'  <div class="stages">{"".join(stage_rows)}</div>'
            f'</section>')

    # ---- attention list -----------------------------------------------
    if attention:
        items = ""
        for line_name, stage_name, state, nodes in attention:
            culprits = "、".join(f"{n['label']}（{n['detail']}）"
                                 for n in nodes if n["state"] in ACTIONABLE)
            items += (f'<li class="s-{esc(state)}">'
                      f'<b>{esc(line_name)} · {esc(stage_name)}</b>'
                      f'<span>{esc(culprits)}</span></li>')
        attention_html = (f'<ul class="attention">{items}</ul>')
    else:
        attention_html = '<p class="all-clear">所有階段正常。</p>'

    unified_arch = svg_of("unified-architecture.html")
    unified_flow = svg_of("unified-flow.html")
    unified = ""
    for title, svg in (("架構", unified_arch), ("流程", unified_flow)):
        if svg:
            unified += (f'<figure><figcaption>三線統整{esc(title)}圖</figcaption>'
                        f'<div class="canvas">{svg}</div></figure>')

    total_green = sum(g for g, _, _ in totals.values())
    total_all = sum(t for _, t, _ in totals.values())
    total_super = sum(x for _, _, x in totals.values())

    return PAGE.format(
        generated=esc(board["generated_at"]),
        total_green=total_green,
        total_all=total_all,
        devops="{} / {}".format(totals["DevOps"][0], totals["DevOps"][1]),
        dataops="{} / {}".format(totals["DataOps"][0], totals["DataOps"][1]),
        mlops="{} / {}".format(totals["MLOps"][0], totals["MLOps"][1]),
        superseded=total_super,
        unified=unified,
        lines="".join(line_html),
        attention=attention_html,
    )


PAGE = """<title>三線階段燈號</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Noto+Sans+TC:wght@400;500;700&family=Noto+Serif+TC:wght@600;700&display=swap">
<style>
:root {{
  --ground:#F5F6F8; --surface:#FFFFFF; --sunk:#ECEFF3;
  --ink:#171C24; --soft:#4E5966; --faint:#7A8593;
  --rule:#D6DCE3; --rule-soft:#E6EAEF;
  --devops:#2E5AA8; --dataops:#2F7D52; --mlops:#8A5A2B;
  --ok:#2F7D52; --warn:#A8792A; --fail:#A8372C; --unknown:#6E7A88;
  --ok-w:#E6F0EA; --warn-w:#F7EFDD; --fail-w:#F7E7E5; --unknown-w:#EDF0F3;
}}
@media (prefers-color-scheme:dark) {{
  :root:not([data-theme="light"]) {{
    --ground:#12161C; --surface:#1A2029; --sunk:#212932;
    --ink:#E3E8EE; --soft:#A7B2BF; --faint:#79848F;
    --rule:#303A45; --rule-soft:#252E38;
    --devops:#7FA8E0; --dataops:#6FBF93; --mlops:#C99C6E;
    --ok:#6FBF93; --warn:#D9AE5C; --fail:#E28078; --unknown:#79848F;
    --ok-w:#182C21; --warn-w:#2E2612; --fail-w:#321F1D; --unknown-w:#212932;
  }}
}}
:root[data-theme="dark"] {{
  --ground:#12161C; --surface:#1A2029; --sunk:#212932;
  --ink:#E3E8EE; --soft:#A7B2BF; --faint:#79848F;
  --rule:#303A45; --rule-soft:#252E38;
  --devops:#7FA8E0; --dataops:#6FBF93; --mlops:#C99C6E;
  --ok:#6FBF93; --warn:#D9AE5C; --fail:#E28078; --unknown:#79848F;
  --ok-w:#182C21; --warn-w:#2E2612; --fail-w:#321F1D; --unknown-w:#212932;
}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--ground);color:var(--ink);line-height:1.8;
  font-family:"Noto Sans TC","PingFang TC",system-ui,sans-serif;font-size:15px;
  -webkit-font-smoothing:antialiased;padding:0 1.5rem 5rem}}
.wrap{{max-width:78rem;margin:0 auto;display:flex;flex-direction:column;gap:3.5rem}}
h1,h2,h3,h4{{font-family:"Noto Serif TC","Songti TC",serif;margin:0;text-wrap:balance;line-height:1.35}}
.eyebrow{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.7rem;
  letter-spacing:.14em;text-transform:uppercase;color:var(--faint);margin:0}}

header.top{{padding-top:3.5rem;display:flex;flex-direction:column;gap:1rem}}
header.top h1{{font-size:clamp(2rem,4.5vw,2.9rem)}}
.stamp{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.8rem;color:var(--faint)}}
.lede{{max-width:64ch;color:var(--soft);margin:0}}
.tally{{display:flex;flex-wrap:wrap;gap:2.25rem;border-top:1px solid var(--rule);
  padding-top:1.25rem;margin-top:.25rem}}
.tally div{{display:flex;flex-direction:column}}
.tally .n{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-variant-numeric:tabular-nums;
  font-size:1.9rem;line-height:1.15;font-weight:500}}
.tally .k{{font-size:.78rem;color:var(--faint)}}
.tally .devops .n{{color:var(--devops)}}
.tally .dataops .n{{color:var(--dataops)}}
.tally .mlops .n{{color:var(--mlops)}}

section{{display:flex;flex-direction:column;gap:1.5rem}}
section > h3{{font-size:1.35rem;border-bottom:2px solid var(--rule);padding-bottom:.5rem}}

figure{{margin:0;display:flex;flex-direction:column;gap:.5rem}}
figcaption{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.72rem;
  letter-spacing:.1em;text-transform:uppercase;color:var(--faint)}}
.canvas{{background:var(--surface);border:1px solid var(--rule-soft);border-radius:3px;
  padding:1rem;overflow-x:auto}}
.canvas svg{{display:block;min-width:900px;width:100%;height:auto}}
.missing{{color:var(--fail);font-size:.9rem;margin:0}}
.figs{{display:flex;flex-direction:column;gap:1.5rem}}

.line{{border-top:3px solid var(--accent);padding-top:1.5rem}}
.line[data-line="devops"]{{--accent:var(--devops);--wash:var(--ok-w)}}
.line[data-line="dataops"]{{--accent:var(--dataops)}}
.line[data-line="mlops"]{{--accent:var(--mlops)}}
.line-head{{display:flex;align-items:flex-end;justify-content:space-between;
  gap:1rem;flex-wrap:wrap}}
.line-head h2{{font-size:1.7rem;color:var(--accent)}}
.score{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-variant-numeric:tabular-nums;
  font-size:1.5rem;font-weight:500;color:var(--accent);display:flex;align-items:baseline;gap:.5rem}}
.score small{{font-family:"Noto Sans TC",sans-serif;font-size:.75rem;color:var(--faint)}}

.stages{{display:grid;grid-template-columns:repeat(auto-fill,minmax(19rem,1fr));gap:1rem}}
.stage{{background:var(--surface);border:1px solid var(--rule-soft);
  border-left:4px solid var(--tone);border-radius:3px;padding:1rem 1.15rem;
  display:flex;flex-direction:column;gap:.6rem;--tone:var(--ok);--tone-w:var(--ok-w)}}
.stage.s-warn{{--tone:var(--warn);--tone-w:var(--warn-w)}}
.stage.s-fail{{--tone:var(--fail);--tone-w:var(--fail-w)}}
.stage.s-unknown{{--tone:var(--unknown);--tone-w:var(--unknown-w)}}
.stage.s-superseded{{--tone:var(--faint);--tone-w:var(--sunk);opacity:.72}}
.stage header{{display:flex;align-items:baseline;justify-content:space-between;gap:.75rem}}
.stage h4{{font-size:1.02rem}}
.pill{{font-size:.7rem;letter-spacing:.06em;color:var(--tone);background:var(--tone-w);
  border-radius:999px;padding:.05rem .6rem;white-space:nowrap;line-height:1.7}}
.why{{margin:0;font-size:.85rem;color:var(--soft);line-height:1.65}}
.nodes{{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:.3rem;
  border-top:1px dashed var(--rule);padding-top:.6rem}}
.n{{display:flex;gap:.5rem;align-items:baseline;font-size:.82rem;flex-wrap:wrap}}
.n::before{{content:"";width:.5rem;height:.5rem;border-radius:999px;flex:none;
  background:var(--ok);transform:translateY(-1px)}}
.n.s-warn::before{{background:var(--warn)}}
.n.s-fail::before{{background:var(--fail)}}
.n.s-unknown::before{{background:var(--unknown)}}
.n.s-superseded::before{{background:var(--faint);opacity:.6}}
.nl{{font-weight:500;white-space:nowrap}}
.nd{{color:var(--faint);font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.72rem;
  font-variant-numeric:tabular-nums}}

.attention{{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:0}}
.attention li{{display:flex;flex-direction:column;gap:.15rem;padding:.85rem 0 .85rem 1rem;
  border-bottom:1px solid var(--rule-soft);border-left:4px solid var(--tone);--tone:var(--warn)}}
.attention li.s-fail{{--tone:var(--fail)}}
.attention li.s-unknown{{--tone:var(--unknown)}}
.attention li:last-child{{border-bottom:none}}
.attention b{{font-size:.95rem}}
.attention span{{color:var(--soft);font-size:.87rem}}
.all-clear{{color:var(--ok);margin:0}}

footer{{border-top:1px solid var(--rule);padding-top:1.25rem;color:var(--faint);
  font-size:.82rem;display:flex;flex-direction:column;gap:.35rem}}
code{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.85em;
  background:var(--sunk);padding:.1em .4em;border-radius:3px}}
</style>

<div class="wrap">

  <header class="top">
    <p class="eyebrow">階段檢視 · 由現場探測產生</p>
    <h1>三線階段燈號</h1>
    <p class="stamp">產生於 {generated}</p>
    <p class="lede">
      每一盞燈都來自<strong>當下的實測</strong>——查資料庫、問叢集、讀證據檔，不是文件上的記載。
      一個階段只有在它底下每個節點都正常時才是綠的；不是綠的，下面會寫出是哪個節點造成的。
    </p>
    <div class="tally">
      <div><span class="n">{total_green} / {total_all}</span><span class="k">階段正常（全平台）</span></div>
      <div><span class="n">{superseded}</span><span class="k">已被取代（遷移到 K8s）</span></div>
      <div class="devops"><span class="n">{devops}</span><span class="k">DevOps</span></div>
      <div class="dataops"><span class="n">{dataops}</span><span class="k">DataOps</span></div>
      <div class="mlops"><span class="n">{mlops}</span><span class="k">MLOps</span></div>
    </div>
  </header>

  <section>
    <h3>需要注意的階段</h3>
    {attention}
  </section>

  <section>
    <h3>三線統整</h3>
    {unified}
  </section>

  {lines}

  <footer>
    <span>本頁由 <code>platform/statusdag/stage_report.py</code> 產生，重跑即更新；標題下的時間戳記是它唯一的有效期宣告。</span>
    <span>圖檔來源 <code>docs/diagrams/</code>；節點探測邏輯 <code>platform/statusdag/dag.py</code>。</span>
  </footer>

</div>
"""


def main():
    page = render()
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(page)
    print(f"artifact={OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

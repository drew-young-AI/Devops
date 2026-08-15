# Value Stream Board

```bash
python3 platform/valuestream/board.py            # -> docs/Value-Stream-Board.html
python3 platform/valuestream/board.py --json     # machine-readable
```

## Why this is not part of observability

[DORA](https://dora.dev/capabilities/work-visibility-in-value-stream/)
separates the two, and the distinction is about audience, not tooling:

| | System observability | Value stream visibility |
|---|---|---|
| Object observed | a running service | the flow of work |
| Answers | "is it healthy right now?" | "where is work stuck? who is waiting?" |
| Audience | engineers, scheduled agents | managers, cross-team, audit |
| Here | Grafana / Prometheus / Loki | this board |

## Derived, never hand-maintained

Every column is computed from evidence the pipeline already produces. There
are no cards to drag.

This is the design decision everything else follows from: a board someone
must remember to update is quietly wrong within a week, and a wrong board is
worse than no board because people trust it. Here, "deployed to develop"
*means* `deploy_develop_<sha>.json` exists and says healthy — the board has
no way to disagree with reality.

| Column | Derived from |
|---|---|
| 已提交 | `git log`, no build evidence yet |
| 已建置 | `evidence/<pilot>/build_<sha>.json` |
| develop 已部署 | `deploy_develop_<sha>.json` with `health_status: healthy` |
| 待人工核可 | develop evidence **plus** an `llm_review_<sha>` verdict, not yet promoted |
| 已上線 | `production_like_state.json` |
| 線上異常 | Alertmanager active alerts |

DORA also warns against visualising only the slice one team owns, because
bottlenecks then hide in the parts nobody drew — so the stream runs from
commit through CI, human approval, and runtime incidents, not just the
build.

### "待人工核可" is a deliberate column, not a subdivision

Work whose evidence is complete and which is waiting on a person is a
*different state* from work that is merely deployed. Collapsing them hides
the queue that human approval creates — which is exactly the bottleneck
DORA's "streamlining change approval" capability is about. The platform's
`PROMOTE` gate is intentional and stays; making the queue it creates visible
is how you find out whether it is costing anything.

## WIP limits

`built: 5`, `develop: 3`, `awaiting_approval: 2`. A column over its limit is
flagged.

Per DORA, the purpose is to **expose problems**, not to make anyone work
faster: a column sitting over its limit means work is piling up somewhere,
which is information rather than a scolding.

## Failure handling

If Alertmanager is unreachable, the 線上異常 column reports **unknown**, not
zero, with a banner saying an empty column does not mean no incidents. Same
principle as `check_health.sh`'s exit 3 — silence from a broken source is
not good news.

## Known gaps

- **No post-release bug reports.** The stream currently ends at
  Alertmanager-detected incidents. Human-reported bugs (GitHub Issues) are
  not pulled in, so the "上線後人員回報" part of the stream is missing.
- **Lead time is commit→promote only.** True DORA lead time starts at idea
  or ticket creation, which needs a tracker this platform does not have.
- **Snapshot, not live.** Regenerating requires re-running the script; there
  is no auto-refresh or scheduled publish.
- **No process time or %C/A.** The board shows where work *is*, not how long
  it spent in each stage or how often it had to go back.

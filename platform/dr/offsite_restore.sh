#!/usr/bin/env bash
# Restore the off-site copy onto the OTHER MACHINE, in stages, for real.
#
# WHY THIS IS NOT `restore_drill.sh` (2026-09-20).
#
# `restore_drill.sh` proves an archive can become a working database. It does
# that on the machine that made the archive, in a scratch container, from the
# LOCAL copy. Three things it therefore cannot prove, and all three are the
# ones that matter when a machine is gone:
#
#   1. that the off-site copy is retrievable AT ALL -- rclone's crypt remote
#      has never been read back end to end by anything except its own verify;
#   2. that the archive restores on a DIFFERENT host, of a DIFFERENT
#      architecture (arm64 -> amd64, ADR-0008);
#   3. that the restored database is then good enough to SERVE -- a restore
#      that loads without error and cannot answer a query is not a recovery.
#
# So this runs the real path: pull from the off-site remote, verify, ship to
# ubu, load into the production cluster, and check the result against what the
# manifest says should be inside it.
#
# THE STAGES ARE THE POINT.
#
#   preflight  is the target host there, what is it, has it room, what is on it
#   fetch      pull from OFF-SITE (never the local archive) and verify sha256
#   ship       move the bytes to the target
#   restore    create the database if needed and load the dump
#   confirm    does the restored data match what the manifest says it holds
#   verify     can the restored database answer the platform's own queries
#
# Each stage writes evidence and, on failure, emits one event and stops with a
# stage-specific exit code. `--from <stage>` resumes: a disaster recovery that
# has to start from the beginning after every hiccup is one nobody finishes.
#
# WHAT IT WILL NOT DO. It never touches the Mac's database, and it refuses to
# drop an existing production database unless --force is given: a recovery tool
# whose failure mode is destroying the thing you were recovering to is not a
# recovery tool.
#
# Usage:
#   platform/dr/offsite_restore.sh                 # all stages
#   platform/dr/offsite_restore.sh --from restore  # resume
#   platform/dr/offsite_restore.sh --preflight-only
#   platform/dr/offsite_restore.sh --force         # allow reloading over data
#
# Exit codes: 0 ok · 10 preflight · 11 fetch · 12 ship · 13 restore ·
#             14 confirm · 15 verify · 2 usage
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
# Both overridable, because a TEST must not write the platform's real disaster
# recovery evidence or send a real "異地還原失敗" notification for a failure
# that never happened (found in review, 2026-09-20: the suite did exactly
# that, leaving a failed preflight in the state file the next real drill
# reads, and putting a false alarm in the notification channel).
EV_DIR="${DR_EVIDENCE_DIR:-$REPO_ROOT/evidence/dr}"
STATE="${DR_STATE_FILE:-$EV_DIR/offsite_restore_state.json}"
NOTIFY="${DR_NOTIFY:-$REPO_ROOT/platform/notify/emit_event.sh}"

TARGET_HOST="${DR_TARGET_HOST:-ubu}"
TARGET_CTX="${DR_TARGET_CONTEXT:-ubu}"
TARGET_NS="${DR_TARGET_NS:-station2}"
TARGET_TMP="${DR_TARGET_TMP:-/tmp/dr-restore}"
RCLONE_DIR="${RCLONE_DIR:-$REPO_ROOT/platform/backup/.rclone}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"
ENV_FILE="${RCLONE_ENV:-$REPO_ROOT/platform/backup/.rclone.env}"
# THE FETCHED COPY LIVES OUTSIDE THE REPO (2026-09-20).
#
# It was $REPO_ROOT/platform/backup/.dr-fetch, and the 55 MB dump it holds was
# then copied into every test sandbox -- test_sandbox_hygiene caught it at
# 71 MB against a 50 MB ceiling that exists because a 3.6 GB sandbox once
# caused an incident. Downloaded bytes are not repository content: they are
# reproducible from the remote, they are large, and they have no business in
# `git status` either.
WORK="${DR_WORK_DIR:-${TMPDIR:-/tmp}/devops-dr-fetch}"

STAGES=(preflight fetch ship restore confirm verify)
FROM="preflight"
FORCE=0
PREFLIGHT_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:?--from needs a stage}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    -h|--help) sed -n '1,48p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# AN UNRECOGNISED --from SKIPS EVERY STAGE AND STILL REPORTS SUCCESS.
#
# `should_run` walks STAGES looking for FROM; a typo (`--from resore`) matches
# nothing, so every stage is skipped, the script falls through to the final
# banner and emits an `ok` event for a drill that did not happen. A recovery
# tool reporting success for zero work is worse than one that crashes.
case " ${STAGES[*]} " in
  *" $FROM "*) ;;
  *) echo "unknown stage '$FROM' -- one of: ${STAGES[*]}" >&2; exit 2 ;;
esac

# --preflight-only means "stop after preflight". Combined with a --from that
# skips preflight it means "do nothing", which would exit 0 having probed
# nothing at all.
if [ "$PREFLIGHT_ONLY" -eq 1 ] && [ "$FROM" != "preflight" ]; then
  echo "--preflight-only with --from $FROM would run nothing at all" >&2
  exit 2
fi

mkdir -p "$EV_DIR" "$WORK"

say()  { printf '%s\n' "$*"; }
head2() { printf '\n=== %s ===\n' "$*"; }

fail() {  # <stage> <code> <detail...>
  local stage="$1" code="$2"; shift 2
  local detail="$*"
  say "FAILED at $stage: $detail" >&2
  record "$stage" "failed" "$detail"
  # One event, naming the stage. The operator's next action differs completely
  # between "the remote would not answer" and "the data came back short", so a
  # single "restore failed" would be the least useful true sentence available.
  [ -x "$NOTIFY" ] && "$NOTIFY" offsite-restore failed \
    "階段 ${stage}：${detail}（可用 --from ${stage} 續跑）" >/dev/null 2>&1
  exit "$code"
}

record() {  # <stage> <status> <detail>
  python3 - "$STATE" "$1" "$2" "${3:-}" "${SET_ID:-}" <<'PY'
import json, os, sys, datetime
path, stage, status, detail, set_id = sys.argv[1:6]
try:
    with open(path, encoding="utf-8") as fh:
        st = json.load(fh)
except (OSError, ValueError):
    st = {"history": []}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
st["updated_at"] = now
st["archive_set"] = set_id or st.get("archive_set")
if status == "ok":
    st["last_good_stage"] = stage
st["last_stage"] = stage
st["last_status"] = status
st["last_detail"] = detail
st.setdefault("history", []).append(
    {"at": now, "stage": stage, "status": status, "detail": detail})
st["history"] = st["history"][-50:]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(st, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
}

should_run() {  # <stage> -- true when this stage is at or after --from
  local want="$1" seen=0
  for s in "${STAGES[@]}"; do
    [ "$s" = "$FROM" ] && seen=1
    [ "$s" = "$want" ] && { [ "$seen" -eq 1 ] && return 0 || return 1; }
  done
  return 1
}

# EVERY ssh, not just the first one. The preflight probe used BatchMode and a
# connect timeout; `ship`, `restore` and every prod_psql did not, so a drill
# run from cron could sit forever on a host-key or password prompt with no
# output. A recovery procedure that can hang indefinitely is one that finishes
# only when someone is watching.
# sha256 OF A LOCAL FILE, ON EITHER MACHINE.
#
# `shasum -a 256` is what macOS ships; `sha256sum` is what GNU coreutils
# ships. This platform runs on both (ADR-0008) and the drill could be started
# from either side, so the tool is chosen rather than assumed -- the same
# class of trap as `sed -i ''` and `stat -f`, which test_static already guards.
sha256_local() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
sshq() { ssh "${SSH_OPTS[@]}" "$@"; }

rc_remote() {  # rclone, in the same container shape sync_remote.sh uses
  docker run --rm \
    -v "$RCLONE_DIR:/config/rclone" \
    -v "$WORK:/data" \
    "$RCLONE_IMAGE" "$@"
}

REMOTE="${RCLONE_REMOTE:-}"
if [ -z "$REMOTE" ] && [ -f "$ENV_FILE" ]; then
  REMOTE="$(sed -n 's/^RCLONE_REMOTE[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' \
    "$ENV_FILE" 2>/dev/null | head -1)"
fi
REMOTE="${REMOTE:-gdrive-crypt:}"

# On a resume the set id comes from the state file. Without it the final notice
# said "備份集 ?", and a report naming nothing cannot be checked against
# anything -- which is the entire reason the set is named.
CONFIRM_COMPARED=-1   # -1 = confirm did not run in this invocation
SET_ID=""
if [ -f "$STATE" ]; then
  SET_ID="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("archive_set") or "")
except Exception:
    print("")' "$STATE" 2>/dev/null)"
fi
DUMP=""

# THE GUARD THAT KEEPS --force MEANING SOMETHING.
#
# Two defects this replaces, both found in review (2026-09-20):
#
#   1. It lived only in `preflight`, and the documented resume path
#      (`--from restore`) skips preflight. So the one flag protecting a
#      populated production database was bypassed by following the README.
#   2. It read an empty result as "the database is empty". `kubectl exec` can
#      fail because the pod is mid-rollout, because exec is blocked, or
#      because the table was renamed -- and every one of those came back as
#      "0 rows, safe to wipe". A guard that fails OPEN is not a guard.
guard_existing_data() {
  [ "$FORCE" -eq 1 ] && return 0
  local rows rc
  rows="$(kubectl --context "$TARGET_CTX" -n "$TARGET_NS" exec prod-db-0 -- \
    psql -U twin -d twin -qtAX -c 'select count(*) from surveillance_fact' 2>/dev/null | tr -d ' \r')"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$rows" ]; then
    fail preflight 10 "prod-db 存在但問不出列數（rc=${rc}）——不知道裡面有沒有資料時不覆蓋；確定要覆蓋請加 --force"
  fi
  case "$rows" in
    ''|*[!0-9]*) fail preflight 10 "prod-db 回了無法判讀的列數 '$rows'——不覆蓋；確定要覆蓋請加 --force" ;;
  esac
  [ "$rows" = "0" ] && return 0
  fail preflight 10 "prod-db 已經有 ${rows} 列資料；要覆蓋請加 --force"
}

# --------------------------------------------------------------- preflight --
stage_preflight() {
  head2 "1/6 preflight — 目標主機、平台、容量、現況"

  sshq "$TARGET_HOST" true 2>/dev/null \
    || fail preflight 10 "ssh $TARGET_HOST 不通"

  local arch kernel
  arch="$(sshq "$TARGET_HOST" uname -m 2>/dev/null)"
  kernel="$(sshq "$TARGET_HOST" uname -sr 2>/dev/null)"
  say "  平台      $TARGET_HOST  $kernel  $arch"
  # The architecture is CHECKED, not assumed. A logical dump crosses
  # architectures; a tar of a PostgreSQL data directory does not, and the
  # fetch stage refuses one for that reason. Recording the arch here is what
  # makes that refusal explainable rather than arbitrary.
  case "$arch" in
    x86_64|aarch64|arm64) ;;
    *) fail preflight 10 "未知架構 $arch" ;;
  esac

  kubectl --context "$TARGET_CTX" get nodes --no-headers >/dev/null 2>&1 \
    || fail preflight 10 "kubectl --context $TARGET_CTX 無法取得節點"
  local ready
  ready="$(kubectl --context "$TARGET_CTX" get nodes --no-headers 2>/dev/null \
           | awk '{print $2}' | grep -c '^Ready' || true)"
  [ "${ready:-0}" -ge 1 ] || fail preflight 10 "叢集沒有 Ready 的節點"
  say "  叢集      $TARGET_CTX  ${ready} 個 Ready 節點"

  local avail_kb avail_gb mem_mb
  avail_kb="$(sshq "$TARGET_HOST" "df -Pk / | awk 'NR==2{print \$4}'" 2>/dev/null)"
  avail_gb=$(( ${avail_kb:-0} / 1024 / 1024 ))
  mem_mb="$(sshq "$TARGET_HOST" "free -m | awk 'NR==2{print \$7}'" 2>/dev/null)"
  say "  容量      磁碟可用 ${avail_gb}G，記憶體可用 ${mem_mb:-?}M"
  # Three times the archive: the compressed dump, its expansion, and the
  # database it becomes. Restoring into a disk that fills halfway leaves a
  # half-loaded database that starts and answers wrong.
  [ "${avail_gb:-0}" -ge 10 ] || fail preflight 10 "磁碟可用 ${avail_gb}G，低於 10G 門檻"
  [ "${mem_mb:-0}" -ge 512 ] || fail preflight 10 "記憶體可用 ${mem_mb}M，低於 512M 門檻"

  local existing
  existing="$(kubectl --context "$TARGET_CTX" -n "$TARGET_NS" \
    get statefulset prod-db --no-headers 2>/dev/null | awk '{print $2}')"
  if [ -n "$existing" ]; then
    say "  現況      prod-db 已存在（${existing}）"
    guard_existing_data
  else
    say "  現況      prod-db 尚未建立（這一輪會建）"
  fi

  docker info >/dev/null 2>&1 || fail preflight 10 "本機 docker 不可用（rclone 需要它）"
  rc_remote lsd "$REMOTE" >/dev/null 2>&1 || fail preflight 10 "異地遠端 $REMOTE 無法列出"
  say "  異地      $REMOTE 可列出"

  record preflight ok "arch=$arch disk=${avail_gb}G mem=${mem_mb}M"
  say "  PASS"
}

# ------------------------------------------------------------------- fetch --
stage_fetch() {
  head2 "2/6 fetch — 從異地取回並驗證"

  SET_ID="$(rc_remote lsd "$REMOTE" 2>/dev/null | awk '{print $NF}' | sort | tail -1)"
  [ -n "$SET_ID" ] || fail fetch 11 "異地沒有任何備份集"
  say "  最新備份集  $SET_ID"

  rm -rf "${WORK:?}/set"
  mkdir -p "$WORK/set"
  rc_remote copy "$REMOTE$SET_ID/manifest.json" "/data/set" >/dev/null 2>&1 \
    || fail fetch 11 "取不回 $SET_ID/manifest.json"

  DUMP="$(python3 - "$WORK/set/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for v in m.get("volumes", []):
    if v.get("volume", "").endswith("twin-db"):
        print(v["archive"])
        break
PY
)"
  [ -n "$DUMP" ] || fail fetch 11 "清單裡沒有 pilot 資料庫的封存"
  case "$DUMP" in
    *.dump) ;;
    # A tar of a data directory cannot cross architectures, and this drill
    # exists precisely to cross one. Refusing here names the reason; loading it
    # would fail later with a message about page headers.
    *) fail fetch 11 "封存是 $DUMP —— 資料目錄的 tar 不能跨架構還原，需要 pg_dump 格式" ;;
  esac

  say "  取回        $DUMP"
  rc_remote copy "$REMOTE$SET_ID/$DUMP" "/data/set" >/dev/null 2>&1 \
    || fail fetch 11 "取不回 $SET_ID/$DUMP"

  local want got
  want="$(python3 - "$WORK/set/manifest.json" "$DUMP" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
print(next(v["sha256"] for v in m["volumes"] if v["archive"] == sys.argv[2]))
PY
)"
  got="$(sha256_local "$WORK/set/$DUMP")"
  [ "$want" = "$got" ] || fail fetch 11 "sha256 不符：清單 ${want}，取回 $got"
  say "  驗證        sha256 相符"

  record fetch ok "set=$SET_ID archive=$DUMP"
  say "  PASS"
}

# -------------------------------------------------------------------- ship --
stage_ship() {
  head2 "3/6 ship — 搬到目標主機"
  [ -n "$DUMP" ] || DUMP="$(ls "$WORK/set"/*.dump 2>/dev/null | head -1 | xargs -r basename)"
  [ -n "$DUMP" ] || fail ship 12 "本地沒有取回的封存，先跑 --from fetch"

  sshq "$TARGET_HOST" "mkdir -p $TARGET_TMP" 2>/dev/null \
    || fail ship 12 "無法在 $TARGET_HOST 建立 $TARGET_TMP"
  scp -q "$WORK/set/$DUMP" "$TARGET_HOST:$TARGET_TMP/" \
    || fail ship 12 "scp 失敗"

  # Verified again ON THE TARGET. The local check proved the download; this
  # proves the transfer, and they are different journeys.
  local want got
  want="$(sha256_local "$WORK/set/$DUMP")"
  got="$(sshq "$TARGET_HOST" "sha256sum $TARGET_TMP/$DUMP 2>/dev/null | cut -d' ' -f1")"
  [ "$want" = "$got" ] || fail ship 12 "搬運後 sha256 不符（來源 ${want}，目標 ${got}）"
  say "  搬運        $DUMP → $TARGET_HOST:${TARGET_TMP}（sha256 相符）"

  record ship ok "$TARGET_HOST:$TARGET_TMP/$DUMP"
  say "  PASS"
}

# ----------------------------------------------------------------- restore --
stage_restore() {
  head2 "4/6 restore — 建立（或沿用）生產資料庫並載入"
  [ -n "$DUMP" ] || DUMP="$(sshq "$TARGET_HOST" "ls $TARGET_TMP/*.dump 2>/dev/null | head -1 | xargs -r basename")"
  [ -n "$DUMP" ] || fail restore 13 "目標上沒有封存，先跑 --from ship"

  # THE FILE ON THE TARGET IS NOT AUTOMATICALLY THE FILE WE FETCHED.
  #
  # $TARGET_TMP is never cleaned, so `--from restore` picks up whatever *.dump
  # a previous drill left there. Drill 1 ships set A and fails; drill 2 fetches
  # set B, fails at ship, the operator resumes at restore -- and set A gets
  # loaded while `confirm` compares it against set B's manifest. The counts
  # differ, and the message says the restore came back short: a true sentence
  # about the wrong problem.
  if [ -f "$WORK/set/manifest.json" ]; then
    WANT_SHA="$(python3 -c 'import json,sys
m=json.load(open(sys.argv[1], encoding="utf-8"))
print(next((v["sha256"] for v in m["volumes"] if v["archive"]==sys.argv[2]), ""))' \
      "$WORK/set/manifest.json" "$DUMP" 2>/dev/null)"
    GOT_SHA="$(sshq "$TARGET_HOST" "sha256sum $TARGET_TMP/$DUMP 2>/dev/null" | cut -d' ' -f1)"
    if [ -n "$WANT_SHA" ] && [ "$WANT_SHA" != "$GOT_SHA" ]; then
      fail restore 13 "目標上的 $DUMP 不是本地清單裡那一份（可能是上一次演練的殘留）——請跑 --from ship 重新搬運"
    fi
    say "  封存        與本地清單的 sha256 相符"
  else
    say "  封存        本地沒有清單可比對，沿用目標上的 ${DUMP}（UNVERIFIED）"
  fi

  # Checked HERE too, not only in preflight: `--from restore` is the
  # documented resume and it skips preflight entirely.
  if kubectl --context "$TARGET_CTX" -n "$TARGET_NS" get statefulset prod-db --no-headers >/dev/null 2>&1; then
    guard_existing_data
  fi

  kubectl --context "$TARGET_CTX" apply -f "$REPO_ROOT/platform/k8s/prod-db/postgres.yaml" >/dev/null \
    || fail restore 13 "套用 prod-db 宣告檔失敗"

  # The bootstrap password is generated INTO the cluster and never printed,
  # never written to this repo. It is a bootstrap credential only: dynamic
  # credentials come from the prod Vault once it exists (B-class: its unseal
  # keys can only be held by the platform owner).
  if ! kubectl --context "$TARGET_CTX" -n "$TARGET_NS" get secret prod-db-bootstrap >/dev/null 2>&1; then
    kubectl --context "$TARGET_CTX" -n "$TARGET_NS" create secret generic prod-db-bootstrap \
      --from-literal=password="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)" >/dev/null \
      || fail restore 13 "建立 prod-db-bootstrap secret 失敗"
    say "  憑證        已在叢集內產生（不經過這台機器的檔案，也不印出）"
  fi

  kubectl --context "$TARGET_CTX" -n "$TARGET_NS" rollout status statefulset/prod-db \
    --timeout=180s >/dev/null 2>&1 || fail restore 13 "prod-db 沒有在 180s 內就緒"
  say "  資料庫      prod-db-0 就緒"

  sshq "$TARGET_HOST" "kubectl -n $TARGET_NS cp $TARGET_TMP/$DUMP prod-db-0:/tmp/$DUMP" 2>/dev/null \
    || fail restore 13 "把封存送進 pod 失敗"

  # --clean --if-exists so a resumed run is idempotent, and the whole thing in
  # one transaction so a failure leaves the database as it was rather than
  # half-loaded. A half-loaded database starts, answers, and is wrong.
  #
  # --no-acl IS NOT COSMETIC, AND THE FIRST RUN FAILED WITHOUT IT (2026-09-20).
  #
  # The source database hands out DYNAMIC credentials from Vault, so its dump
  # carries `GRANT USAGE ON SCHEMA public TO "v-approle-station2-<lease>"` for
  # every lease that existed when pg_dump ran. Those roles are leases on THAT
  # machine's Vault. On a fresh host none of them exist, the first GRANT
  # errors, and --single-transaction correctly rolls the whole restore back.
  #
  # Dropping the ACLs is right rather than convenient: the target gets its own
  # Vault issuing its own leases, so copying the source's grants would install
  # references to credentials that will never exist here. What the application
  # needs is recreated by the platform's own setup, not by the dump.
  #
  # This is also the first time the pilot DATABASE has been restore-tested at
  # all: restore_drill.sh restores Vault only.
  local out
  out="$(sshq "$TARGET_HOST" "kubectl -n $TARGET_NS exec prod-db-0 -- \
    pg_restore -U twin -d twin --clean --if-exists --no-owner --no-acl --single-transaction /tmp/$DUMP" 2>&1)"
  local rc=$?
  if [ $rc -ne 0 ]; then
    fail restore 13 "pg_restore rc=$rc: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
  say "  載入        pg_restore 完成"

  record restore ok "pg_restore ok"
  say "  PASS"
}

# SQL goes through ssh, then the remote shell, then kubectl exec, so it is
# written WITHOUT any quote characters at all. Two things were learned the
# hard way here (2026-09-20): a single quote does not survive that chain
# (`time_level='week'` arrived as `time_level=week`, read as a column name),
# and `$$` dollar quoting does not either (the remote shell expands it to its
# own PID). So the week filter asks `epi_week is not null` instead, which is
# the same question with no literal in it.
#
# The other lesson is older and blunter: the first version of the join used
# `time_period_id` on BOTH sides. Neither table has it -- the fact table
# calls it `period_id` and so does the dimension.
# A schema read from memory is a guessed mapping, and CLAUDE.md forbids those
# for exactly the reason it cost here.
prod_psql() { sshq "$TARGET_HOST" "kubectl -n $TARGET_NS exec prod-db-0 -- psql -U twin -d twin -qtAX -c \"$1\"" 2>/dev/null | tr -d ' \r'; }

# "NO ANSWER" AND "ZERO" ARE DIFFERENT FACTS (2026-09-23).
#
# prod_psql returns the empty string for both a failed connection and a query
# that legitimately returned nothing. Without this, a sleeping target host
# produced `disease 表為空` -- a sentence about data loss for what is actually
# a machine being asleep. Every stage that reads the database asks this first.
prod_db_reachable() {
  local probe
  probe="$(prod_psql 'select 1')"
  [ "$probe" = "1" ]
}

# ----------------------------------------------------------------- confirm --
stage_confirm() {
  head2 "5/6 confirm — 還原出來的東西和清單說的一致嗎"
  prod_db_reachable || fail confirm 14 "連不到 ${TARGET_HOST} 上的 prod 資料庫（主機可能休眠或 pod 未就緒）——這不是「資料不符」"
  local mf="$WORK/set/manifest.json"
  [ -f "$mf" ] || fail confirm 14 "本地沒有清單，先跑 --from fetch"

  local expect_schema expect_sf expect_df
  eval "$(python3 - "$mf" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
c = {}
for v in m.get("volumes", []):
    if v.get("volume", "").endswith("twin-db"):
        c = v.get("contents") or {}
# A JSON null must come out EMPTY, not as the string "None" (found by review,
# 2026-09-23). backup.sh writes null for any count whose psql probe failed, so
# c.get(k, "") returns None and %s renders it as the four characters None.
# The emptiness test in the shell then sees a non-empty value, skips UNVERIFIED
# branch, and compares a real row count against the literal "None" -- which
# nothing can equal. The restore is byte-perfect and the operator is told
# "schema 版本不符", forever, on every retry.
def out(key):
    v = c.get(key)
    return "" if v is None else v

print("expect_schema=%s" % out("schema_version"))
print("expect_sf=%s" % out("surveillance_fact"))
print("expect_df=%s" % out("demographic_fact"))
PY
)"
  # A null in the manifest arrives as the EMPTY STRING, not as "None": the
  # extractor prints nothing for a missing key. Comparing against "None" could
  # never match, and that failure would read as data loss rather than as a
  # backup that did not record its own contents.
  if [ -z "$expect_sf" ] || [ -z "$expect_schema" ] || [ -z "$expect_df" ]; then
    # An older archive predates contents-in-the-manifest. Say so rather than
    # inventing a comparison: "cannot check" and "checked and fine" must not
    # print the same line.
    say "  清單        這個備份集沒有內容欄位，無法逐項比對（UNVERIFIED）"
    CONFIRM_COMPARED=0
    record confirm ok "manifest has no contents block -- comparison skipped"
    return 0
  fi

  local got_schema got_sf got_df
  got_schema="$(prod_psql 'select coalesce(max(version),-1) from schema_migrations')"
  got_sf="$(prod_psql 'select count(*) from surveillance_fact')"
  got_df="$(prod_psql 'select count(*) from demographic_fact')"
  say "  schema      清單 v$expect_schema / 還原 v${got_schema:-?}"
  say "  監測事實    清單 $expect_sf / 還原 ${got_sf:-?}"
  say "  人口事實    清單 $expect_df / 還原 ${got_df:-?}"

  [ "$got_schema" = "$expect_schema" ] || fail confirm 14 "schema 版本不符"
  [ "$got_sf" = "$expect_sf" ] || fail confirm 14 "surveillance_fact 列數不符"
  [ "$got_df" = "$expect_df" ] || fail confirm 14 "demographic_fact 列數不符"

  CONFIRM_COMPARED=1
  record confirm ok "schema=$got_schema sf=$got_sf df=$got_df"
  say "  PASS"
}

# ------------------------------------------------------------------ verify --
stage_verify() {
  head2 "6/6 verify — 還原出來的資料庫答得出平台自己的問題嗎"
  prod_db_reachable || fail verify 15 "連不到 ${TARGET_HOST} 上的 prod 資料庫（主機可能休眠或 pod 未就緒）——這不是「表是空的」"

  # Loading without error is not recovery. These are the questions the
  # platform's own probes ask; a database that cannot answer them is not
  # serving, whatever pg_restore said.
  local diseases sources latest
  diseases="$(prod_psql 'select count(*) from disease')"
  sources="$(prod_psql 'select count(*) from data_source')"
  latest="$(prod_psql "select max(epi_year*100+epi_week) from time_period where epi_week is not null")"
  say "  疾病        ${diseases:-?} 筆"
  say "  登記來源    ${sources:-?} 筆"
  say "  最新週次    ${latest:-?}"

  [ "${diseases:-0}" -gt 0 ] 2>/dev/null || fail verify 15 "disease 表為空"
  [ "${sources:-0}" -gt 0 ] 2>/dev/null || fail verify 15 "data_source 表為空"
  [ -n "$latest" ] && [ "$latest" != "" ] || fail verify 15 "沒有任何週次"

  # A join across three tables: the tables can all be non-empty and still not
  # line up, which is what a partial restore looks like from the outside.
  local joined
  joined="$(prod_psql "select count(*) from surveillance_fact f join disease d on d.disease_id = f.disease_id join time_period t on t.period_id = f.period_id where t.epi_week is not null")"
  say "  可連結事實  ${joined:-?} 列"
  [ "${joined:-0}" -gt 0 ] 2>/dev/null || fail verify 15 "事實表無法與維度連結"

  record verify ok "diseases=$diseases sources=$sources joined=$joined"
  say "  PASS"
}

# -------------------------------------------------------------------- main --
say "=== 異地還原到 ${TARGET_HOST}（$TARGET_CTX/${TARGET_NS}）==="
say "來源：$REMOTE   從階段 $FROM 開始"

should_run preflight && stage_preflight
[ "$PREFLIGHT_ONLY" -eq 1 ] && { say ""; say "--preflight-only：停在這裡"; exit 0; }
should_run fetch    && stage_fetch
should_run ship     && stage_ship
should_run restore  && stage_restore
should_run confirm  && stage_confirm
should_run verify   && stage_verify

head2 "完成"
# THREE OUTCOMES, NOT TWO. The first version had a flag that meant "compared"
# or "manifest had nothing to compare", and everything else -- including
# `--from verify`, where confirm never ran at all -- fell into the "compared"
# branch and printed 「內容確認 → 查詢驗證，全部通過」. A resume that skipped
# the comparison would report it as passed, which is the same class of lie as
# reporting an unverifiable result in verified words.
case "$CONFIRM_COMPARED" in
  1)
    say "異地備份 → $TARGET_HOST 還原 → 內容確認 → 查詢驗證，全部通過。"
    DETAIL="異地備份集 ${SET_ID:-?} 已還原到 ${TARGET_HOST} 並通過內容與查詢驗證"
    ;;
  0)
    say "異地備份 → $TARGET_HOST 還原 → 查詢驗證，通過。"
    say "內容比對：UNVERIFIED（這個備份集的清單沒有內容欄位）"
    DETAIL="異地備份集 ${SET_ID:-?} 已還原到 ${TARGET_HOST}；查詢驗證通過，內容比對 UNVERIFIED"
    ;;
  *)
    say "這一輪從 ${FROM} 開始，**沒有執行內容比對**（confirm 不在這次的階段範圍內）。"
    say "已執行的階段都通過；要比對內容請跑 --from confirm。"
    DETAIL="異地備份集 ${SET_ID:-?}：從 ${FROM} 續跑的階段皆通過，但這一輪未執行內容比對"
    ;;
esac
say "狀態：$STATE"
[ -x "$NOTIFY" ] && "$NOTIFY" offsite-restore ok "$DETAIL" >/dev/null 2>&1
exit 0

#!/usr/bin/env bash
# Trigger the remote pass the way a reviewer does, wait for it, and print its verdict.
#
#   ./scripts/dev-push.sh <change> [--only <repo>|backend] [--allow-destroy] [--no-wait]
#   ./scripts/dev-push.sh --lock --pr <control PR> [--no-wait]
#   ./scripts/dev-push.sh --lock [--ref <control branch>] [--no-wait]
#
# A change: comments `/dev-push[-<repo>]` on the change's control PR, so the run a lane
# starts is the run a reviewer sees in the PR. `--lock`: dispatches the workflow on a ref
# with lock semantics — every repo at that ref's gitlinks — which is what `make dev-up` runs
# on main. `--lock --pr N`: comments `/dev-push` on control PR N instead — same lock
# semantics, visible in the PR; `/realign` uses this. docs/adr/0018 §3, §11.
#
# The evidence lands in changes/<change>/runs/dev-push-<run id>/ (or runs/ for --lock):
# deploy-set.json, verify-remote.json, the logs.
#
# Exit 0 verified (or deployed-partial with --only) · 1 the deploy or an assertion failed ·
# 2 refused — no PR, expired credentials, a run that produced no verdict. docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONTROL="$("$ROOT"/scripts/repos.py owner)/agent-app-project"
CHANGE=""; ONLY=""; LOCK=0; REF=""; PR_ARG=""; ALLOW=""; WAIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift ;;
    --lock) LOCK=1 ;;
    --ref) REF="$2"; shift ;;
    --pr) PR_ARG="$2"; shift ;;
    --allow-destroy) ALLOW=" --allow-destroy" ;;
    --no-wait) WAIT=0 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "dev-push: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
say() { echo "dev-push: $*"; }
refuse() { say "$*" >&2; exit 2; }

if [ -n "$ONLY" ]; then
  case " backend $("$ROOT"/scripts/repos.py names) " in
    *" $ONLY "*) ;; *) refuse "--only takes a submodule ($("$ROOT"/scripts/repos.py names)) or backend" ;; esac
fi
{ [ "$LOCK" = "1" ] && [ -z "$CHANGE" ]; } || { [ "$LOCK" = "0" ] && [ -n "$CHANGE" ]; } \
  || refuse "usage: dev-push.sh <change> [--only <repo>] | dev-push.sh --lock [--pr <n> | --ref <branch>]"
[ -z "$PR_ARG" ] || { [ "$LOCK" = "1" ] && [ -z "$REF" ]; } || refuse "--pr goes with --lock, and not with --ref"

SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "$PR_ARG" ]; then
  PR="$PR_ARG"
  head="$(gh pr view "$PR" -R "$CONTROL" --json state,headRefName --jq 'select(.state=="OPEN") | .headRefName')"
  [ -n "$head" ] || refuse "$CONTROL#$PR is not an open pull request"
  case "$head" in feat/*) refuse "#$PR is a change PR — use dev-push.sh ${head#feat/}" ;; esac
  BODY="/dev-push${ONLY:+-$ONLY}$ALLOW"
  gh pr comment "$PR" -R "$CONTROL" --body "$BODY" >/dev/null
  EVENT="issue_comment"
  OUT_ROOT="runs"
  say "commented \`$BODY\` on $CONTROL#$PR (every repo at its gitlinks)"
elif [ "$LOCK" = "1" ]; then
  REF="${REF:-main}"
  WANT_REF="$(git ls-remote --heads origin "$REF" | awk -v r="refs/heads/$REF" '$2==r{print $1}')"
  [ -n "$WANT_REF" ] || refuse "$REF is not on origin — push it first; CI deploys what is pushed"
  gh workflow run dev-push.yml -R "$CONTROL" --ref "$REF" -f lock=true \
    ${ALLOW:+-f allow_destroy=true} ${ONLY:+-f only="$ONLY"}
  EVENT="workflow_dispatch"
  OUT_ROOT="runs"
  say "dispatched dev-push.yml on $REF (every repo at its gitlinks)"
else
  [ -d "changes/$CHANGE" ] || refuse "no such change: changes/$CHANGE"
  PR="$(gh pr list -R "$CONTROL" --head "feat/$CHANGE" --state open --json number --jq '.[0].number // empty')"
  [ -n "$PR" ] || refuse "no open control PR from feat/$CHANGE — /ship phase 5 opens it (prs.sh --create)"
  BODY="/dev-push${ONLY:+-$ONLY}$ALLOW"
  gh pr comment "$PR" -R "$CONTROL" --body "$BODY" >/dev/null
  EVENT="issue_comment"
  OUT_ROOT="changes/$CHANGE/runs"
  say "commented \`$BODY\` on $CONTROL#$PR"
fi

# The run is located by what it says it was for, never by timing. Every PR comment starts a
# run — most skip at the job `if` and leave no artifact — and another PR's /dev-push can land
# in the same minute. So each run created after the trigger is waited on in turn, and the
# first whose trigger.json names this trigger is ours. trigger.json is written before
# anything can refuse, so even a run that stopped early is identifiable.
[ "$WAIT" = "1" ] || { say "not waiting — gh run list -R $CONTROL --workflow dev-push.yml"; exit 0; }
DEADLINE=$(( $(date +%s) + 120 * 60 ))
SEEN=" "; RUN=""; OUT=""
while [ -z "$RUN" ]; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || refuse "no dev-push run for this trigger finished within two hours"
  CANDIDATES="$(gh run list -R "$CONTROL" --workflow dev-push.yml --event "$EVENT" --limit 30 \
      --json databaseId,createdAt \
      --jq "[.[] | select(.createdAt >= \"$SINCE\")] | sort_by(.createdAt) | .[].databaseId")"
  NEXT=""
  for id in $CANDIDATES; do case "$SEEN" in *" $id "*) ;; *) NEXT="$id"; break ;; esac; done
  if [ -z "$NEXT" ]; then sleep 10; continue; fi
  SEEN="$SEEN$NEXT "
  gh run watch "$NEXT" -R "$CONTROL" --interval 30 >/dev/null 2>&1 || true
  TMP_OUT="$OUT_ROOT/dev-push-$NEXT"
  rm -rf "$TMP_OUT"; mkdir -p "$TMP_OUT"
  gh run download "$NEXT" -R "$CONTROL" -n dev-push-evidence -D "$TMP_OUT" >/dev/null 2>&1 || true
  if python3 - "$TMP_OUT/trigger.json" "$LOCK" "$CHANGE" "${PR:-}" "${WANT_REF:-}" <<'PY'
import json, sys
path, lock, change, pr, want_ref = sys.argv[1:6]
try:
    t = json.load(open(path))
except Exception:
    sys.exit(1)
if lock == "1" and pr:
    ok = t.get("mode") == "lock" and t.get("pr") == pr
elif lock == "1":
    ok = t.get("mode") == "lock" and t.get("control_ref") == want_ref
else:
    ok = t.get("mode") == "change" and t.get("change") == change and t.get("pr") == pr
sys.exit(0 if ok else 1)
PY
  then RUN="$NEXT"; OUT="$TMP_OUT"
  else rm -rf "$TMP_OUT"
  fi
done
say "run https://github.com/$CONTROL/actions/runs/$RUN"

VR="$(find "$OUT" -name verify-remote.json | head -1)"
if [ -z "$VR" ]; then
  say "the run produced no verify-remote.json — it stopped before the remote pass began."
  say "Read the log: gh run view $RUN -R $CONTROL --log-failed"
  say "An expired session says so there; \`make login && make push-gh-creds\` is the fix."
  exit 2
fi

python3 - "$VR" "$ONLY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); only = sys.argv[2]
a = d.get("assertions") or {}
print(f"dev-push: {d.get('outcome')} — {a.get('passed', 0)} passed, {a.get('failed', 0)} failed"
      + (f", {a.get('from_change_suite', 0)} from {a['change_suite']}" if a.get("change_suite") else ""))
if d.get("failed_stage"):
    print(f"dev-push: failed at: {d['failed_stage']}")
if d.get("owners_failing"):
    print(f"dev-push: answerable: {' '.join(d['owners_failing'])}")
for repo, e in ((d.get("deploy_set") or {}).get("repos") or {}).items():
    print(f"dev-push:   {repo:16} {e.get('tag')}  {e.get('from')} ({e.get('source')})")
print(f"dev-push: evidence: {sys.argv[1]}")
outcome = d.get("outcome")
if outcome == "verified" or (only and outcome == "deployed-partial"):
    sys.exit(0)
sys.exit(2 if d.get("fault") == "harness" else 1)
PY

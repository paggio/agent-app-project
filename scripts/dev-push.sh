#!/usr/bin/env bash
# Trigger the remote pass the way a reviewer does, wait for it, and print its verdict.
#
#   ./scripts/dev-push.sh <change> [--only backend|frontend|infra] [--allow-destroy] [--no-wait]
#   ./scripts/dev-push.sh --lock [--ref <control branch>] [--no-wait]
#
# A change: comments `/dev-push[-<repo>]` on the change's control PR, so the run a lane
# starts is the run a reviewer sees in the PR. `--lock`: dispatches the workflow on a ref
# with lock semantics — every repo at that ref's gitlinks — which is what /realign runs on
# its own branch, and what `make dev-up` runs on main. docs/adr/0018 §3, §11.
#
# The evidence lands in changes/<change>/runs/dev-push-<run id>/ (or runs/ for --lock):
# deploy-set.json, verify-remote.json, the logs.
#
# Exit 0 verified (or deployed-partial with --only) · 1 the deploy or an assertion failed ·
# 2 refused — no PR, expired credentials, a run that produced no verdict. docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONTROL="Paggio/agent-app-project"
CHANGE=""; ONLY=""; LOCK=0; REF=""; ALLOW=""; WAIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift ;;
    --lock) LOCK=1 ;;
    --ref) REF="$2"; shift ;;
    --allow-destroy) ALLOW=" --allow-destroy" ;;
    --no-wait) WAIT=0 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "dev-push: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
say() { echo "dev-push: $*"; }
refuse() { say "$*" >&2; exit 2; }

case "$ONLY" in ""|backend|frontend|infra) ;; *) refuse "--only takes backend, frontend or infra" ;; esac
{ [ "$LOCK" = "1" ] && [ -z "$CHANGE" ]; } || { [ "$LOCK" = "0" ] && [ -n "$CHANGE" ]; } \
  || refuse "usage: dev-push.sh <change> [--only <repo>] | dev-push.sh --lock [--ref <branch>]"

SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$LOCK" = "1" ]; then
  REF="${REF:-main}"
  git ls-remote --exit-code --heads origin "$REF" >/dev/null 2>&1 \
    || refuse "$REF is not on origin — push it first; CI deploys what is pushed"
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

# The run is located, not guessed: the first dev-push run of this event created after the
# trigger. A second trigger in the same minute would be the second run in the queue, and
# `concurrency: env-dev` serialises them anyway.
RUN=""
for _ in $(seq 1 30); do
  RUN="$(gh run list -R "$CONTROL" --workflow dev-push.yml --event "$EVENT" --limit 20 \
          --json databaseId,createdAt \
          --jq "[.[] | select(.createdAt >= \"$SINCE\")] | sort_by(.createdAt) | .[0].databaseId // empty")"
  [ -n "$RUN" ] && break
  sleep 4
done
[ -n "$RUN" ] || refuse "no dev-push run appeared within two minutes. Is dev-push.yml on main? (issue_comment runs main's copy)"
URL="https://github.com/$CONTROL/actions/runs/$RUN"
say "run $URL"
[ "$WAIT" = "1" ] || exit 0

gh run watch "$RUN" -R "$CONTROL" --interval 30 >/dev/null 2>&1 || true
OUT="$OUT_ROOT/dev-push-$RUN"
mkdir -p "$OUT"
gh run download "$RUN" -R "$CONTROL" -n dev-push-evidence -D "$OUT" >/dev/null 2>&1 || true
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

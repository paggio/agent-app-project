#!/usr/bin/env bash
# Trigger an eval run against `dev` the way a reviewer does, wait for it, print its verdict.
#
#   ./scripts/dev-eval.sh <change> [--judge bedrock|heuristic] [--no-wait]
#   ./scripts/dev-eval.sh --pr <control PR> [--judge …] [--no-wait]   (a realign PR)
#
# Comments `/dev-eval` on the change's control PR. The run evaluates whatever dev runs — a
# `/dev-push` of the PR first, if you want this PR's code. Evidence lands in
# changes/<change>/runs/dev-eval-<run id>/. docs/adr/0018 §13.
#
# Exit 0 thresholds met · 1 breached or an example errored · 2 refused — no PR, dev down,
# expired credentials, a run that produced no verdict. docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONTROL="$("$ROOT"/scripts/repos.py owner)/agent-app-project"
CHANGE=""; JUDGE=""; PR=""; WAIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --judge) JUDGE="$2"; shift ;;
    --pr) PR="$2"; shift ;;
    --no-wait) WAIT=0 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "dev-eval: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
say() { echo "dev-eval: $*"; }
refuse() { say "$*" >&2; exit 2; }

case "$JUDGE" in ""|bedrock|heuristic) ;; *) refuse "--judge takes bedrock or heuristic" ;; esac
{ [ -n "$CHANGE" ] && [ -z "$PR" ]; } || { [ -z "$CHANGE" ] && [ -n "$PR" ]; } \
  || refuse "usage: dev-eval.sh <change> | dev-eval.sh --pr <n>  [--judge bedrock|heuristic]"
if [ -n "$CHANGE" ]; then
  [ -d "changes/$CHANGE" ] || refuse "no such change: changes/$CHANGE"
  PR="$(gh pr list -R "$CONTROL" --head "feat/$CHANGE" --state open --json number --jq '.[0].number // empty')"
  [ -n "$PR" ] || refuse "no open control PR from feat/$CHANGE"
  OUT_ROOT="changes/$CHANGE/runs"
else
  [ -n "$(gh pr view "$PR" -R "$CONTROL" --json state --jq 'select(.state=="OPEN") | .state')" ] \
    || refuse "$CONTROL#$PR is not an open pull request"
  OUT_ROOT="runs"
fi

"$ROOT"/scripts/gh-creds-fresh.sh || exit 2   # before the comment
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BODY="/dev-eval${JUDGE:+ --judge $JUDGE}"
gh pr comment "$PR" -R "$CONTROL" --body "$BODY" >/dev/null
say "commented \`$BODY\` on $CONTROL#$PR"
[ "$WAIT" = "1" ] || { say "not waiting — gh run list -R $CONTROL --workflow dev-eval.yml"; exit 0; }

# Found by what trigger.json says the run was for, never by timing — as dev-push.sh does.
DEADLINE=$(( $(date +%s) + 150 * 60 ))
SEEN=" "; RUN=""; OUT=""
while [ -z "$RUN" ]; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || refuse "no dev-eval run for this trigger finished within 150 minutes"
  CANDIDATES="$(gh run list -R "$CONTROL" --workflow dev-eval.yml --event issue_comment --limit 30 \
      --json databaseId,createdAt \
      --jq "[.[] | select(.createdAt >= \"$SINCE\")] | sort_by(.createdAt) | .[].databaseId")"
  NEXT=""
  for id in $CANDIDATES; do case "$SEEN" in *" $id "*) ;; *) NEXT="$id"; break ;; esac; done
  if [ -z "$NEXT" ]; then sleep 10; continue; fi
  SEEN="$SEEN$NEXT "
  gh run watch "$NEXT" -R "$CONTROL" --interval 30 >/dev/null 2>&1 || true
  TMP_OUT="$OUT_ROOT/dev-eval-$NEXT"
  rm -rf "$TMP_OUT"; mkdir -p "$TMP_OUT"
  gh run download "$NEXT" -R "$CONTROL" -n dev-eval-evidence -D "$TMP_OUT" >/dev/null 2>&1 || true
  if python3 -c '
import json, sys
try:
    t = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if (t.get("change"), t.get("pr"), t.get("judge")) == tuple(sys.argv[2:5]) else 1)' \
      "$TMP_OUT/trigger.json" "$CHANGE" "$PR" "${JUDGE:-bedrock}"
  then RUN="$NEXT"; OUT="$TMP_OUT"
  else rm -rf "$TMP_OUT"
  fi
done
say "run https://github.com/$CONTROL/actions/runs/$RUN"

ER="$(find "$OUT" -name eval-remote.json | head -1)"
if [ -z "$ER" ]; then
  say "the run produced no eval-remote.json — it stopped before the eval began."
  say "Read the log: gh run view $RUN -R $CONTROL --log-failed"
  exit 2
fi
python3 - "$ER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"dev-eval: {d.get('outcome')} (exit {d.get('exit')})")
for k in ("reason", "experiment_url", "backend_base_url"):
    if d.get(k):
        print(f"dev-eval:   {k}: {d[k]}")
if d.get("deployed_is_this_pr") is False:
    print("dev-eval:   dev is NOT running this PR's deploy set — /dev-push first to evaluate it")
print(f"dev-eval: evidence: {sys.argv[1]}")
sys.exit(d.get("exit") if d.get("exit") in (0, 1) else 2)
PY

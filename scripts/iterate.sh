#!/usr/bin/env bash
# Fan out a change, deploy it, smoke it, and send failures back to the repo that caused
# them — up to a bounded number of attempts.
#
# This is the loop the harness was missing. Before it, the cycle was: dispatch three
# agents, read three PR links, and find out whether the pieces fit together by hand, later.
# Now the oracle runs immediately and its output is machine-addressable, so a failing
# assertion goes back to one agent with the evidence attached instead of to a human with
# a shrug.
#
# It is a deterministic script that DISPATCHES agents, not an agent that orchestrates
# repos — see docs/adr/0002. The control flow, the attribution and the stopping
# conditions are all fixed here, where they can be read and audited.
#
#   ./scripts/iterate.sh <change> [options]
#
#     --max-attempts N  total passes, including the first (default 2, or 1 when this
#                       change deploys infra — see below)
#     --no-repair       fan out and verify once, then stop and report
#     --verify-only     skip dispatching entirely; just deploy and check what is on disk
#     --only a,b        dispatch only these slices on the FIRST attempt. Repair passes
#                       follow `owners_failing` wherever it leads, because by then the
#                       evidence names the answerable repo and it outranks the caller's
#                       guess. Every verify still asserts the whole suite. /ship-correct
#                       uses it: a correction one repo is answerable for should not buy a
#                       fresh session in the other two. With --no-repair, or a budget of
#                       1 — which is the DEFAULT when this change deploys infra, below —
#                       there is no repair pass, so a wrong --only is never corrected and
#                       the run reports `failed` having dispatched the wrong repo.
#     --keep-up         leave the stack running after the final attempt
#     --e2e             also run Playwright on each verify
#     --no-build        reuse existing images
#     --no-infra        ignore deploy.infra; local deploy and local assertions only.
#                       The outcome is then `verified-local`, never `verified`.
#
# `verified` requires an ASSERTED REMOTE ENVIRONMENT (docs/adr/0004). A change with
# `deploy.infra: false` has none, so its best outcome is `verified-local` — a full pass, and
# the honest name for one that proves nothing about a deployment.
#     --plan-only       plan the infra change, never apply it
#     --allow-destroy   let the infra plan destroy or replace a resource
#
# Outcomes: verified | verified-local | failed | contract-gap | blocked | unattributable
#
# WHEN deploy.infra IS TRUE, the default attempt budget drops to 1. Automatic repair that
# costs a real `terraform apply` per attempt is a different product from automatic repair
# that costs a container rebuild. Pass --max-attempts explicitly to override.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHANGE=""; MAX_ATTEMPTS=""; REPAIR=1; VERIFY_ONLY=0; KEEP_UP=0; E2E=0; NO_BUILD=""
NO_INFRA=0; PLAN_ONLY=0; ALLOW_DESTROY=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      # A flag with no value is the harness refusing. Bare "$2" under `set -u` exits 1,
      # which docs/adr/0003 reserves for the thing under test having failed. An empty
      # value is the same mistake with a worse ending: it falls through ${ONLY:-…} to
      # every slice, and the report then does not say it was ever narrowed.
      { [ $# -ge 2 ] && [ -n "${2:-}" ]; } || {
        echo "iterate: --only needs a comma-separated list of slices" >&2; exit 2; }
      ONLY="$(echo "$2" | tr ',' ' ')"; shift ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift ;;
    --no-repair) REPAIR=0 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --keep-up) KEEP_UP=1 ;;
    --e2e) E2E=1 ;;
    --no-build) NO_BUILD="--no-build" ;;
    --no-infra) NO_INFRA=1 ;;
    --plan-only) PLAN_ONLY=1 ;;
    --allow-destroy) ALLOW_DESTROY=1 ;;
    -h|--help) sed -n '2,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "iterate: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
[ -n "$CHANGE" ] || { echo "usage: iterate.sh <change> [options]" >&2; exit 2; }

CHANGE_DIR="changes/$CHANGE"
[ -d "$CHANGE_DIR" ] || { echo "iterate: no such change: $CHANGE_DIR" >&2; exit 2; }

eval "$(./scripts/manifest.py "$CHANGE_DIR" --shell)"
[ "${MANIFEST_OK:-0}" = "1" ] || {
  echo "iterate: change.yaml has problems (above) — fix them first" >&2; exit 2; }

# --only is validated here, before a run directory or a lock exists: a name that is not a
# slice is the harness refusing, not a result about the change, and dispatching nothing on
# a typo would report `failed` for the change. Exit 2 — see docs/adr/0003.
if [ -n "$ONLY" ]; then
  if [ "$VERIFY_ONLY" = "1" ]; then
    echo "iterate: --only and --verify-only contradict each other — --verify-only" >&2
    echo "iterate: dispatches nothing at all. Pick one." >&2
    exit 2
  fi
  KEPT=""
  for r in $ONLY; do
    case " $CHANGE_SLICES " in
      # Deduplicated: `--only frontend,frontend` would otherwise dispatch two concurrent
      # sessions into one repo on one branch.
      *" $r "*) case " $KEPT " in *" $r "*) ;; *) KEPT="$KEPT $r" ;; esac ;;
      *) echo "iterate: --only names $r, which is not a slice of $CHANGE." >&2
         echo "iterate: slices are: $CHANGE_SLICES" >&2
         exit 2 ;;
    esac
  done
  ONLY="${KEPT# }"
  # `--only ,` and `--only " "` pass the -n guard above, then word-split to zero words, so
  # the loop never runs and KEPT is empty — and ${ONLY:-…} below would read that as "every
  # slice" with nothing in the report saying it had been narrowed. The caller asked for a
  # subset; an empty one is a refusal, not the whole set.
  [ -n "$ONLY" ] || {
    echo "iterate: --only matched no slices — it was given separators or blanks only" >&2
    echo "iterate: slices are: $CHANGE_SLICES" >&2
    exit 2; }
fi

# A repair attempt against a real environment costs an apply, so the budget is 1 unless
# the human says otherwise.
REMOTE_RUN=0
if [ "$CHANGE_DEPLOY_INFRA" = "1" ] && [ "$NO_INFRA" = "0" ] && [ "$PLAN_ONLY" = "0" ]; then
  REMOTE_RUN=1
fi
if [ -z "$MAX_ATTEMPTS" ]; then
  if [ "$REMOTE_RUN" = "1" ]; then MAX_ATTEMPTS=1; else MAX_ATTEMPTS=2; fi
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ROOT="$CHANGE_DIR/runs/$TS"
mkdir -p "$RUN_ROOT"
REPORT="$RUN_ROOT/report.md"

# One run per environment, held for the WHOLE run rather than per verify — otherwise two
# runs serialise their applies and then interleave their smoke against one origin.
LOCK_OWNED=0
if [ "$REMOTE_RUN" = "1" ]; then
  LOCK_DIR=".locks/infra-$CHANGE_DEPLOY_ENVIRONMENT.lock"
  mkdir -p .locks
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf 'pid=%s\nrun=%s\nchange=%s\n' "$$" "$RUN_ROOT" "$CHANGE" > "$LOCK_DIR/owner"
    LOCK_OWNED=1
    export INFRA_LOCK_HELD="$CHANGE_DEPLOY_ENVIRONMENT"
  else
    echo "iterate: environment '$CHANGE_DEPLOY_ENVIRONMENT' is locked by:" >&2
    sed 's/^/iterate:   /' "$LOCK_DIR/owner" 2>/dev/null >&2 || true
    exit 2
  fi
fi

say() { echo "iterate: $*"; }
banner() {
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "════════════════════════════════════════════════════════════════"
}

TARGETS="${ONLY:-$CHANGE_SLICES}"
ATTEMPT=1
# One run per change per working tree. docs/adr/0004 gave infra an atomic lock because two
# runs cannot share one environment; a LOCAL run shares just as much — the change dir, the
# runs/ tree, the stack, the published ports and the postgres volume. Two overlapping runs
# produced a commit landing under one of them and a .pyc swept into the other, and telling
# that apart from a harness bug cost a trip through the reflog.
RUN_LOCK="$ROOT/.locks/run-$CHANGE.lock"
mkdir -p "$ROOT/.locks"
if mkdir "$RUN_LOCK" 2>/dev/null; then
  printf 'pid=%s\nchange=%s\n' "$$" "$CHANGE" > "$RUN_LOCK/owner"
  RUN_LOCK_OWNED=1
else
  RUN_LOCK_OWNED=0
  echo "iterate: another run holds $RUN_LOCK" >&2
  sed 's/^/iterate:   /' "$RUN_LOCK/owner" 2>/dev/null >&2 || true
  echo "iterate: two runs in one working tree share the change dir, the stack, the ports" >&2
  echo "iterate: and the postgres volume. Wait for it, or remove the directory if it is stale." >&2
  exit 2
fi
OUTCOME="unknown"
SUMMARY=""

record() { SUMMARY="$SUMMARY$1
"; }

write_report() {
  {
    echo "# $CHANGE — iterate report"
    echo
    echo "- run: \`$RUN_ROOT\`"
    echo "- outcome: **$OUTCOME**"
    echo "- attempts used: $((ATTEMPT > MAX_ATTEMPTS ? MAX_ATTEMPTS : ATTEMPT)) of $MAX_ATTEMPTS"
    echo "- slices: $CHANGE_SLICES"
    # Which slices were dispatched is not cosmetic: a reader who does not know the first
    # attempt was narrowed reads a green suite as evidence about all three.
    if [ -n "$ONLY" ]; then
      echo "- first dispatch restricted to (\`--only\`): $ONLY"
    fi
    echo "- infra deploy: $([ "$REMOTE_RUN" = "1" ] && echo "yes ($CHANGE_DEPLOY_ENVIRONMENT)" || echo no)"
    # The assertion count, so a report can never say `verified` above an empty one.
    LAST_VERIFY="$(ls -1d "$RUN_ROOT"/attempt-*/verify.json 2>/dev/null | tail -1 || true)"
    if [ -n "$LAST_VERIFY" ]; then
      python3 - "$LAST_VERIFY" <<'ASSERTPY' || true
import json, sys
d = json.load(open(sys.argv[1]))
a = d.get("assertions") or {}
print(f"- assertions: {a.get('passed', 0)} passed, {a.get('failed', 0)} failed "
      f"({a.get('from_change_suite', 0)} from {a.get('change_suite', 'the change suite')})")
# A one-shot run is a different kind of evidence from an HTTP assertion, and a reader has
# to be able to tell them apart — a change whose central criterion is "this process exits
# non-zero on a breach" has all of its weight here and none of it in the suite.
j = d.get("jobs") or {}
if j.get("ran"):
    print(f"- one-shot jobs: {j.get('passed', 0)} of {j.get('ran', 0)} exited as declared")
st = d.get("stages") or {}
skipped = [f"{k} ({v})" for k, v in st.items() if str(v).startswith("skipped")]
if skipped:
    print(f"- skipped: {', '.join(skipped)}")
ASSERTPY
    fi
    echo
    echo "## What happened"
    echo
    printf '%s' "$SUMMARY"
    echo
    echo "## Evidence"
    echo
    for d in "$RUN_ROOT"/attempt-*; do
      [ -d "$d" ] || continue
      echo "- \`$d\`"
      [ -f "$d/fanout.json" ] && echo "  - dispatch results: \`$d/fanout.json\`"
      [ -f "$d/smoke.json" ]  && echo "  - smoke results: \`$d/smoke.json\`"
      [ -f "$d/verify.json" ] && echo "  - verify result: \`$d/verify.json\`"
    done
    echo
    echo "## Next"
    echo
    if [ "$OUTCOME" = "verified" ]; then
      echo "The change is deployed and asserted, locally and against"
      echo "\`$CHANGE_DEPLOY_ENVIRONMENT\`. Review the PRs and merge in dependency order —"
      echo "merging is a human decision. Once they are merged, run \`/realign\`."
    elif [ "$OUTCOME" = "verified-local" ]; then
      echo "The change is deployed and asserted **locally only** — no remote environment"
      echo "was touched, so nothing here says it works deployed."
      if [ "$CHANGE_DEPLOY_INFRA" = "1" ]; then
        echo "Re-run without \`--no-infra\`/\`--plan-only\` before treating this as shippable."
      else
        echo "That is all this change declares (\`deploy.infra: false\`), so it is the best"
        echo "outcome available to it rather than a step that was skipped. Review the PRs and"
        echo "merge in dependency order — merging is a human decision. Once they are merged,"
        echo "run \`/realign\`."
      fi
    elif [ "$OUTCOME" = "contract-gap" ]; then
      echo "A slice reported that it cannot be implemented against the frozen contract."
      echo "Do not patch around it. Go back to \`/ship\` phase 2 — re-freeze \`contracts/\`"
      echo "in a commit of its own, update \`freeze_sha\` in \`change.yaml\`, and re-run."
    elif [ "$OUTCOME" = "blocked" ]; then
      echo "A precondition was unmet, so nothing was dispatched and nothing was deployed."
      echo "There is no deploy evidence to read — fix what the dispatcher named above, in"
      echo "this repo, and re-run. \`./scripts/manifest.py changes/$CHANGE --validate\`"
      echo "names most of these before a run starts."
    else
      echo "Attempts exhausted with the assertions still failing. Read the failing steps"
      echo "above and the briefs at \`$RUN_ROOT/attempt-*/failure-*.md\` — those are exactly"
      echo "what the agents were given. If an assertion is wrong, fix it here in the"
      echo "control repo; if the implementation is wrong, re-run with more attempts."
    fi
  } > "$REPORT"
}

# STATUS.md is the one place that knows the state of all three PRs at once. A green CI
# column there only ever meant "each repo is internally consistent"; this line is what
# says they work together, so it belongs next to the PR table rather than buried in runs/.
update_status() {
  STATUS_FILE="$CHANGE_DIR/STATUS.md"
  [ -f "$STATUS_FILE" ] || return 0
  python3 - "$STATUS_FILE" "$OUTCOME" "$RUN_ROOT" "$TS" "$REPORT" "$ATTEMPT" "$ONLY" <<'STATUSPY'
import json, os, re, sys

path, outcome, run_root, ts, report, attempt, only = sys.argv[1:8]
text = open(path).read()
if "<!-- iterate:begin -->" not in text:
    raise SystemExit(0)

# The shell already knows which attempt is last. Listing the directory and sorting the
# names is what made attempt-10 sort before attempt-2 and attempt-9 read as "last".
stage = owners = ""
used = int(attempt) if attempt.isdigit() else 1
try:
    v = json.load(open(os.path.join(run_root, f"attempt-{used}", "verify.json")))
    stage = v.get("failed_stage") or ""
    owners = " ".join(v.get("owners_failing") or [])
except Exception:
    pass

lines = [f"- **{outcome}** \u2014 {ts}, {used} attempt(s)"]
# The same argument as the report's: this file is the one place that knows the state of
# every slice at once, so an outcome here reads as evidence about all of them. It is not,
# if the first dispatch was narrowed.
if only.strip():
    lines.append(f"- first dispatch: {only.strip()} (`--only`)")
if outcome not in ("verified", "verified-local"):
    if stage:
        lines.append(f"- failed at: `{stage}`")
    if owners:
        lines.append(f"- answerable: {owners}")
lines.append(f"- report: `{report}`")

block = "<!-- iterate:begin -->\n" + "\n".join(lines) + "\n<!-- iterate:end -->"
text = re.sub(r"<!-- iterate:begin -->.*?<!-- iterate:end -->", block, text, flags=re.S)
open(path, "w").write(text)
print(f"iterate: STATUS.md updated ({outcome})")
STATUSPY
}

release_lock() {
  [ "${LOCK_OWNED:-0}" = "1" ] && rm -rf "${LOCK_DIR:?}" 2>/dev/null || true
  [ "${RUN_LOCK_OWNED:-0}" = "1" ] && rm -rf "${RUN_LOCK:?}" 2>/dev/null || true
  return 0
}

REPORTED=0
finish() {
  REPORTED=1
  # The pull requests, on a green outcome only — a PR for a change that did not verify is
  # an invitation to merge something nothing asserted. Idempotent, so a slice that opened
  # its own keeps it, and prs.json is the checked fact next to fanout.json's claim.
  case "$OUTCOME" in
    verified|verified-local)
      banner "$CHANGE — pull requests"
      if ./scripts/prs.sh --create "$CHANGE" --run-dir "$RUN_ROOT"; then
        record ""
        record "**Pull requests:** opened or already open — see \`$RUN_ROOT/prs.json\`"
      else
        record ""
        record "**Pull requests:** at least one could not be opened — see \`$RUN_ROOT/prs.json\`"
      fi ;;
  esac
  write_report
  update_status
  release_lock
  banner "$CHANGE — $OUTCOME"
  printf '%s' "$SUMMARY"
  echo
  say "report: $REPORT"
  [ "$KEEP_UP" = "1" ] && say "stack left running — ./scripts/stack.sh down when finished"
  case "$OUTCOME" in
    verified|verified-local) exit 0 ;;
    *) exit 1 ;;
  esac
}

# There was no trap here, so an unguarded failure-brief.py crash under `set -e` exited
# before any report.md or STATUS.md was written and the run simply vanished.
iterate_die() {
  local code=$?
  [ "$REPORTED" = "1" ] && exit $code
  OUTCOME="unattributable"
  record ""
  record "**harness:** iterate.sh died before reporting (exit $code). This is a bug in the"
  record "loop rather than a result about $CHANGE. Evidence, such as it is: \`$RUN_ROOT\`."
  write_report
  update_status
  release_lock
  say "report: $REPORT"
  exit $code
}
trap iterate_die EXIT

while :; do
  ATT_DIR="$RUN_ROOT/attempt-$ATTEMPT"
  mkdir -p "$ATT_DIR"

  # ── dispatch ────────────────────────────────────────────────────────────────
  DISPATCH_OK=1
  if [ "$VERIFY_ONLY" = "1" ]; then
    say "verify-only — dispatching nothing, checking what is on disk"
    record "**Attempt $ATTEMPT — dispatch:** skipped (\`--verify-only\`)"
  else
    banner "attempt $ATTEMPT/$MAX_ATTEMPTS — dispatch [${TARGETS# }]"
    PREV="$RUN_ROOT/attempt-$((ATTEMPT - 1))"
    FANOUT_ARGS=("$CHANGE" --repos "$(echo "${TARGETS# }" | tr ' ' ',')"
                 --run-dir "$ATT_DIR" --attempt "$ATTEMPT")
    # Each repo picks up its own failure-<repo>.md, so a repair pass hands every agent
    # only the evidence it is answerable for — and they still go out in parallel.
    [ "$ATTEMPT" -gt 1 ] && FANOUT_ARGS+=(--prompt-extra-dir "$PREV")

    [ "$ATTEMPT" -gt 1 ] && FANOUT_ARGS+=(--require-brief)

    FANOUT_FAILED=""
    set +e
    ./scripts/fanout.sh "${FANOUT_ARGS[@]}" 2>&1 | tee "$ATT_DIR/fanout.log"
    FANOUT_RC=${PIPESTATUS[0]}
    set -e

    # Exit 2 is fanout REFUSING to dispatch: a bad manifest, a missing slice file, a
    # repair pass with no evidence. Nothing ran, so there is nothing to verify — and this
    # is where the loop used to swallow the code and go on to deploy and smoke anyway,
    # which is how a change with its freeze SHA in the wrong file reported `verified`
    # with no implementation at all. See docs/adr/0003.
    if [ "$FANOUT_RC" = "2" ]; then
      OUTCOME="blocked"
      record "**Attempt $ATTEMPT — dispatch:** refused. Nothing was dispatched and nothing"
      record "was deployed, so there is no deploy evidence to read."
      record ""
      record "\`\`\`"
      record "$(tail -12 "$ATT_DIR/fanout.log" 2>/dev/null || echo 'see the output above')"
      record "\`\`\`"
      finish
    fi

    if [ "$FANOUT_RC" != "0" ]; then
      DISPATCH_OK=0
      FANOUT_FAILED="$(python3 -c "
import json
try:
    print(' '.join(json.load(open('$ATT_DIR/fanout.json')).get('failed') or []))
except Exception:
    print('${TARGETS# }')
" 2>/dev/null || echo "${TARGETS# }")"
    fi

    # A slice that stopped on a contract gap is a hard stop, always. Read as a FIELD:
    # the old substring search over the whole file turned `FAIL:contract tests in my repo
    # are red` into a hard stop for the entire change, and let a genuine gap phrased
    # differently through to a repair pass that would work around a frozen contract.
    GAPS="$(python3 -c "
import json
try:
    d = json.load(open('$ATT_DIR/fanout.json'))
    print(' '.join(d.get('contract_gaps') or []))
except Exception:
    pass
" 2>/dev/null || true)"
    if [ -n "${GAPS// /}" ]; then
      OUTCOME="contract-gap"
      record "**Attempt $ATTEMPT — dispatch:** stopped. ${GAPS} reported a contract gap."
      record ""
      python3 -c "
import json
d = json.load(open('$ATT_DIR/fanout.json'))
for r in (d.get('contract_gaps') or []):
    print('- **' + r + '**: ' + (d['repos'][r].get('contract_gap') or '(no detail)'))
" 2>/dev/null | while IFS= read -r l; do record "$l"; done
      record ""
      record "A frozen contract cannot be worked around in a slice. This needs a new"
      record "contract-freeze pass in the control repo before anything else happens."
      finish
    fi

    if [ -n "$FANOUT_FAILED" ]; then
      record "**Attempt $ATTEMPT — dispatch:** failed for:${FANOUT_FAILED}"
    else
      record "**Attempt $ATTEMPT — dispatch:** all slices reported OK"
    fi
  fi

  # ── deploy + assert ─────────────────────────────────────────────────────────
  banner "attempt $ATTEMPT/$MAX_ATTEMPTS — deploy and smoke"
  VERIFY_ARGS=("$CHANGE" --run-dir "$ATT_DIR")
  [ -n "$NO_BUILD" ] && VERIFY_ARGS+=("$NO_BUILD")
  # A change whose criteria can only be proved in a browser says so in change.yaml, rather
  # than depending on whoever ran the loop remembering the flag.
  if [ "$E2E" = "1" ] || [ "${CHANGE_SMOKE_E2E:-0}" = "1" ]; then VERIFY_ARGS+=(--e2e); fi
  [ "$NO_INFRA" = "1" ] && VERIFY_ARGS+=(--no-infra)
  [ "$PLAN_ONLY" = "1" ] && VERIFY_ARGS+=(--plan-only)
  [ "$ALLOW_DESTROY" = "1" ] && VERIFY_ARGS+=(--allow-destroy)
  # --verify-only means "check what is on disk", so the branch check would be wrong there.
  [ "$VERIFY_ONLY" = "1" ] && VERIFY_ARGS+=(--any-branch)
  # Keep the stack up between attempts: rebuilding from cold on every pass is most of the
  # wall-clock, and the repair agent may want to poke at a running system.
  if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ] || [ "$KEEP_UP" = "1" ]; then
    VERIFY_ARGS+=(--keep-up)
  fi

  if ./scripts/verify.sh "${VERIFY_ARGS[@]}"; then
    # A green suite over a slice that never reported completion proves nothing about the
    # slice — the stack was already fine. Previously this said `verified` directly above a
    # line reading "dispatch: failed for: chatbot-backend frontend".
    if [ "$DISPATCH_OK" = "0" ]; then
      record "**Attempt $ATTEMPT — verify:** PASS, but${FANOUT_FAILED} never reported a"
      record "completed slice. Not verified: a passing suite over an unfinished slice"
      record "proves only that the stack still works."
    else
      REMOTE_ASSERTED="$(python3 -c "
import json
try:
    print('1' if (json.load(open('$ATT_DIR/verify.json')).get('infra') or {}).get('remote_asserted') else '0')
except Exception:
    print('0')
" 2>/dev/null || echo 0)"
      # `verified` is the strongest word this harness owns, and docs/adr/0004 defines it as
      # "deployed together to a real environment and the acceptance criteria held". The
      # condition used to also require CHANGE_DEPLOY_INFRA=1, so a change that declares no
      # deploy target could never reach `verified-local` and was handed `verified` for a run
      # with `remote_asserted: false` — the label claiming what its own evidence denied.
      # One fact decides it: was a remote environment asserted.
      if [ "$REMOTE_ASSERTED" != "1" ]; then
        OUTCOME="verified-local"
        record "**Attempt $ATTEMPT — verify:** PASS locally. No remote environment was"
        record "touched, so this does not say the change works deployed."
      else
        OUTCOME="verified"
        record "**Attempt $ATTEMPT — verify:** PASS. The joined stack came up and every"
        record "assertion held through \`$CHANGE_SMOKE_BASE\`."
        record "The same suite also held against \`$CHANGE_DEPLOY_ENVIRONMENT\`."
      fi
      finish
    fi
  fi

  # ── attribute ───────────────────────────────────────────────────────────────
  OWNERS="$(python3 -c "
import json
try:
    d = json.load(open('$ATT_DIR/verify.json'))
    print(' '.join(d.get('owners_failing') or []))
except Exception:
    print('')
" 2>/dev/null || true)"
  STAGE="$(python3 -c "
import json
try:
    print(json.load(open('$ATT_DIR/verify.json')).get('failed_stage') or 'unknown')
except Exception:
    print('unknown')
" 2>/dev/null || echo unknown)"

  # Nothing named an owner (a stage that fails before any assertion runs, e.g. preflight).
  # Retrying blind would just burn an attempt, so stop and say why.
  if [ -z "${OWNERS// /}" ]; then
    OWNERS="$(echo "${FANOUT_FAILED:-}" | tr -s ' ')"
  fi
  record "**Attempt $ATTEMPT — verify:** FAIL at \`$STAGE\`"
  FAULT="$(python3 -c "
import json
try:
    print(json.load(open('$ATT_DIR/verify.json')).get('fault') or '')
except Exception:
    print('')
" 2>/dev/null || true)"
  if [ -z "${OWNERS// /}" ]; then
    OUTCOME="unattributable"
    record ""
    if [ "$FAULT" = "harness" ]; then
      record "This failed in the harness rather than in a slice — the stage name above says"
      record "where. Fix it in this repo; there is nothing for a product-repo agent to do."
    else
      record "No repo could be held answerable for this failure — it happened before any"
      record "owned assertion ran. This is a harness or environment problem, not a slice"
      record "problem. See \`$ATT_DIR\`."
    fi
    finish
  fi

  # Split the owners BEFORE reporting them. The report used to print the unfiltered list as
  # `answerable:` while only the sliced subset got a brief, so it named repos that were
  # never told anything.
  TARGETS=""; OUTSIDE=""
  for r in $OWNERS; do
    case " $CHANGE_SLICES " in
      *" $r "*) TARGETS="$TARGETS $r" ;;
      *)        OUTSIDE="$OUTSIDE $r" ;;
    esac
  done
  record "answerable:${TARGETS}"
  if [ -n "${OUTSIDE// /}" ]; then
    # A `say` here never reached report.md, so this fact was invisible to whoever read it.
    record "also failing, outside this change's slices (no brief written, not dispatched):${OUTSIDE}"
  fi
  if [ -z "${TARGETS// /}" ]; then
    OUTCOME="unattributable"
    record ""
    record "Every failing owner is outside this change's slices; nothing to repair."
    finish
  fi

  # ── stop, or repair ─────────────────────────────────────────────────────────
  if [ "$REPAIR" = "0" ]; then
    OUTCOME="failed"
    record ""
    record "Repair disabled (\`--no-repair\`)."
    finish
  fi
  if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    OUTCOME="failed"
    record ""
    if [ "$REMOTE_RUN" = "1" ] && [ "$MAX_ATTEMPTS" = "1" ]; then
      record "Attempts exhausted (1). This change deploys infra, so the budget is 1 by"
      record "default — each attempt costs a real apply. Pass \`--max-attempts N\` if a"
      record "repair pass against \`$CHANGE_DEPLOY_ENVIRONMENT\` is genuinely wanted."
    else
      record "Attempts exhausted ($MAX_ATTEMPTS)."
    fi
    finish
  fi

  banner "attempt $ATTEMPT/$MAX_ATTEMPTS — preparing repair briefs for [${TARGETS# }]"
  REPAIRABLE=""
  for r in $TARGETS; do
    set +e
    ./scripts/failure-brief.py --run-dir "$ATT_DIR" --repo "$r" \
      --change "$CHANGE" --attempt "$ATTEMPT" -o "$ATT_DIR/failure-$r.md"
    BRIEF_RC=$?
    set -e
    # Exit 3 means the brief carried no evidence. Re-dispatching an agent with a stage
    # string and nothing else is the blind retry --require-brief exists to refuse.
    if [ "$BRIEF_RC" = "3" ]; then
      record "no evidence was captured for $r; not re-dispatching it blind"
      say "warning — no evidence for $r; dropping it from this repair pass"
      # A killed session writes its log at exit, so the artifact meant to explain the
      # failure is empty and this branch reads as "the slice produced nothing". Once it did
      # not: the agent had committed four commits and a clean tree before the watchdog fired.
      # fanout.sh records what is on the branch; this is the one place a reader looks.
      LEFT="$(python3 -c "
import json
try:
    d = json.load(open('$ATT_DIR/fanout.json'))['repos']['$r']
    lb = d.get('left_on_branch') or {}
    if lb.get('commits'):
        print('but its branch \`' + (d.get('branch') or '?') + '\` carries '
              + str(lb['commits']) + ' commit(s) and ' + str(lb.get('uncommitted'))
              + ' uncommitted file(s) — read \`git -C $r log --oneline\` before'
              ' concluding it did nothing')
except Exception:
    pass
" 2>/dev/null || true)"
      [ -n "$LEFT" ] && record "$LEFT"
      continue
    elif [ "$BRIEF_RC" != "0" ]; then
      OUTCOME="unattributable"
      record ""
      record "failure-brief.py failed for $r (exit $BRIEF_RC) — that is a harness bug."
      finish
    fi
    REPAIRABLE="$REPAIRABLE $r"
  done

  TARGETS="$REPAIRABLE"
  if [ -z "${TARGETS// /}" ]; then
    OUTCOME="failed"
    record ""
    record "No repo could be given evidence to repair from, so nothing was re-dispatched."
    finish
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

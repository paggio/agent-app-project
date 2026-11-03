#!/usr/bin/env bash
# Deploy a change locally and assert it actually works.
#
# Deliberately usable on its own, with no agent anywhere near it: this is the same check
# a human runs by hand, which is what makes it trustworthy as the loop's oracle. Each
# repo's own gates already proved the repo is internally consistent. This proves the
# three of them are consistent WITH EACH OTHER, through the origin a browser would use.
#
#   ./scripts/verify.sh <change> [options]
#
#     --keep-up        leave the stack running (the iteration lever: then use
#                      `./scripts/stack.sh rebuild backend` instead of a full cycle)
#     --no-build       reuse existing images
#     --e2e            also run the frontend's Playwright suite against the joined origin
#     --any-branch     verify whatever is checked out, even if a slice repo is not on
#                      feat/<change>. Strict is the default: asserting against code this
#                      change did not write is a pass that means nothing.
#     --run-dir DIR    where to write logs and json (default: changes/<change>/runs/<ts>)
#
# LOCAL ONLY. The remote pass — publish, apply, the suites against `dev` — is
# scripts/verify-remote.sh, run in CI by /dev-push (docs/adr/0018). This script never
# touches AWS, so the strongest thing it can report is `remote_asserted: false`.
#
# Exit 1 = the thing under test failed. Exit 2 = this script refused to judge it, which
# here means only what is detected BEFORE the EXIT trap is installed: bad arguments and an
# unparseable manifest. A refusal detected later — a malformed suite, a corrupt outputs
# document — exits 1 with `fault: "harness"` in verify.json, and that field is the signal to
# read, not the exit code. See docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The variables the smoke suites interpolate, supplied by the ship process rather than by a
# human remembering to export them. smoke.py dies on an undefined ${VAR} on purpose, so
# this is what stops "you forgot SIGNUP_CODE" from being a recurring failure mode. The real
# environment wins — see scripts/dev-env.sh.
. "$ROOT/scripts/dev-env.sh"

CHANGE=""; KEEP_UP=0; E2E=0; STRICT_BRANCH=1; RUN_DIR=""; BUILD_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-up) KEEP_UP=1 ;;
    --no-build) BUILD_FLAG="--no-build" ;;
    --e2e) E2E=1 ;;
    --any-branch) STRICT_BRANCH=0 ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "verify: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
[ -n "$CHANGE" ] || { echo "usage: verify.sh <change> [options]" >&2; exit 2; }

CHANGE_DIR="changes/$CHANGE"
[ -d "$CHANGE_DIR" ] || { echo "verify: no such change: $CHANGE_DIR" >&2; exit 2; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$RUN_DIR" ] || RUN_DIR="$CHANGE_DIR/runs/$TS"
mkdir -p "$RUN_DIR"

# The run nonce that namespaces every identity a suite creates. Lowercased, because it ends
# up in an email local part and the backend normalises addresses to lower case — an
# uppercase nonce could never match the value it just registered.
SMOKE_RUN_ID="$(printf '%s' "$TS" | tr '[:upper:]' '[:lower:]')"
export SMOKE_RUN_ID

eval "$(./scripts/manifest.py "$CHANGE_DIR" --shell)"
[ "${MANIFEST_OK:-0}" = "1" ] || {
  echo "verify: change.yaml has problems (above) — fix them first" >&2; exit 2; }

BASE="$CHANGE_SMOKE_BASE"
DIRECT_BASE="${BACKEND_DIRECT_BASE:-http://localhost:8000}"
# `incomplete`, not `pass`. The old default meant any unexpected `set -e` death fired the
# EXIT trap with STATUS still "pass", printed the PASS line and wrote a pass-shaped
# verify.json while exiting non-zero. A pass is now something this script has to reach on
# purpose, at the terminal marker. See docs/adr/0003.
STATUS="incomplete"
FAILED_STAGE=""
OWNERS=""
CURRENT_STAGE="startup"
FAULT=""
# Repos whose docs-currency assertion failed. Deferred, not fatal at once: the run goes on
# so the same repair brief also carries any smoke failure. fail_stage merges them in.
DOCS_OWNERS=""
CHANGE_SUITE="$CHANGE_DIR/$CHANGE_SMOKE_FILE"

note()  { echo "verify: $*"; }
stage() { CURRENT_STAGE="$1"; echo; echo "-- $* --------------------------------------------------"; }

# Assertions actually evaluated, accumulated across every suite this run executed. A pass
# requires at least one of them to have come from the change's own suite — otherwise the
# run proves the stack still works, not that this change does.
ASSERT_PASSED=0
ASSERT_FAILED=0
ASSERT_FROM_CHANGE=0
# One-shot jobs, counted separately as well as folded into the totals above.
# Separately, because "an exit code matched what the change declared" and "an HTTP
# assertion held" are different kinds of evidence, and a reader should not have to
# guess which kind a number is.
JOBS_RAN=0
JOBS_PASSED=0
JOBS_FAILED=0

count_assertions() {
  # $1 = a smoke.py --json file. Adds its counts to the running totals.
  [ -f "$1" ] || return 0
  local counts
  counts="$(python3 - "$1" "$CHANGE_SUITE" <<'PY' 2>/dev/null || echo "0 0 0"
import json, sys
d = json.load(open(sys.argv[1]))
steps = d.get("steps") or []
passed = sum(1 for s in steps if s.get("ok"))
failed = sum(1 for s in steps if not s.get("ok"))
from_change = sum(1 for s in steps if s.get("suite") == sys.argv[2])
print(passed, failed, from_change)
PY
)"
  set -- $counts
  ASSERT_PASSED=$((ASSERT_PASSED + ${1:-0}))
  ASSERT_FAILED=$((ASSERT_FAILED + ${2:-0}))
  ASSERT_FROM_CHANGE=$((ASSERT_FROM_CHANGE + ${3:-0}))
}

finish() {
  local code=$?
  # Never reached the terminal marker: something died in a stage rather than failing an
  # assertion. Name the stage and say whose fault it is, instead of reporting a pass.
  if [ "$STATUS" = "incomplete" ]; then
    STATUS="fail"
    FAILED_STAGE="harness: verify.sh died in stage '$CURRENT_STAGE'"
    FAULT="harness"
    OWNERS=""
  fi
  # A self-check on the mechanism above: exiting 0 without having reached the marker is
  # itself a bug in this script, and it must not read as a pass.
  if [ "$code" = "0" ] && [ "$STATUS" != "pass" ]; then
    STATUS="fail"
    [ -n "$FAILED_STAGE" ] || FAILED_STAGE="harness: verify.sh exited 0 without reaching the pass marker"
    FAULT="harness"
  fi
  if [ "$STATUS" != "pass" ]; then
    note "capturing container logs into $RUN_DIR"
    ./scripts/stack.sh dump "$RUN_DIR" || true
    # A provider refusing the stack's credentials is no slice's fault, and routing it as one
    # burned a repair dispatch in 0002, 0003, 0005, 0006 and 0008. docs/adr/0017 named this
    # class as the answer if it recurred with the reporting in place; it did.
    if [ "$FAULT" = "slice" ]; then
      rejected="$(grep -lE 'UnrecognizedClientException|ExpiredTokenException' \
                    "$RUN_DIR"/*.container.log 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || true)"
      if [ -n "$rejected" ]; then
        FAULT="environment"; OWNERS=""
        FAILED_STAGE="$FAILED_STAGE; the provider rejected the stack's credentials (${rejected% }) — refresh stack/secrets.env (make login) or run CHAT_MODEL=echo"
      fi
    fi
  fi
  if [ "$KEEP_UP" = "1" ]; then
    note "stack left running (--keep-up) at $BASE — tear down with ./scripts/stack.sh down"
  else
    ./scripts/stack.sh down >/dev/null 2>&1 || true
  fi
  python3 - "$RUN_DIR/verify.json" "$STATUS" "$FAILED_STAGE" "$OWNERS" "$CHANGE" "$BASE" \
           "$FAULT" "$ASSERT_PASSED" "$ASSERT_FAILED" "$ASSERT_FROM_CHANGE" "$CHANGE_SUITE" \
           "$STAGE_LOG" "${CHANGE_DEPLOY_ENVIRONMENT:-}" \
           "$JOBS_RAN" "$JOBS_PASSED" "$JOBS_FAILED" "${CHANGE_JOBS_COUNT:-0}" \
           "${CHAT_MODEL:-}" "${EVAL_JUDGE:-}" "$RUN_DIR/docs-currency.json" <<'PY'
import json, sys
(out, status, stage, owners, change, base,
 fault, passed, failed, from_change, change_suite, stage_log,
 environment, jobs_ran, jobs_passed, jobs_failed,
 jobs_declared, chat_model, eval_judge, docs_json) = sys.argv[1:21]
try:
    dc = json.load(open(docs_json))
except (OSError, ValueError):
    dc = None
json.dump({
    "change": change, "status": status, "failed_stage": stage or None,
    "owners_failing": [o for o in owners.split() if o], "base": base,
    "fault": fault or None,
    "assertions": {
        "passed": int(passed), "failed": int(failed),
        "from_change_suite": int(from_change), "change_suite": change_suite,
    },
    "stages": dict(p.split("=", 1) for p in stage_log.split("\n") if "=" in p),
    # The loop reads this to decide between `verified` and `verified-local`. This script
    # never touches a remote environment, so it never claims to have asserted one; the
    # remote verdict is verify-remote.json, from a /dev-push run. docs/adr/0018.
    "infra": {"environment": environment or None, "remote_asserted": False},
    # One-shot runs declared by this change. `ran` is what makes a green line readable:
    # a change that declared two jobs and ran none means something different from one
    # that declared none, and the totals above cannot tell them apart.
    # `declared` beside `ran`, because the two disagreeing IS the defect this stage shipped
    # with: a reader of "ran: 1, passed: 1" cannot tell it from a one-job change.
    "jobs": {"declared": int(jobs_declared), "ran": int(jobs_ran),
             "passed": int(jobs_passed), "failed": int(jobs_failed)},
    # WHICH CONFIGURATION THIS PASS WAS OBTAINED UNDER. Two runs are otherwise
    # byte-identical although one called a real provider and the other did not, and an
    # expired credential has been charged to a slice four times because nothing recorded
    # that the run was reaching for one. Empty means the compose default.
    "configuration": {"chat_model": chat_model or None,
                      "eval_judge": eval_judge or None},
    # One assertion per slice repo that changed; null = the stage never ran. docs/adr/0019.
    "docs_currency": dc and {
        "checked": len(dc["steps"]),
        "passed": sum(1 for s in dc["steps"] if s["ok"]),
        "failed": len(dc["failures"]),
        "unchanged": len(dc["unchanged"]),
        "refused": len(dc["refused"]),
    },
}, open(out, "w"), indent=2)
PY
  echo
  if [ "$STATUS" = "pass" ]; then
    note "PASS — $CHANGE verified against $BASE"
    note "$ASSERT_PASSED assertion(s) passed, $ASSERT_FROM_CHANGE of them from $CHANGE_SUITE"
    [ "$JOBS_RAN" != "0" ] && note "$JOBS_PASSED of $JOBS_RAN one-shot job(s) exited as declared (of ${CHANGE_JOBS_COUNT:-0} declared)"
  else
    note "FAIL — $CHANGE failed at: $FAILED_STAGE"
    [ -n "$OWNERS" ] && note "answerable repo(s): $OWNERS"
    [ "$FAULT" = "harness" ] && note "fault: harness — fix this in the control repo, not in a product repo"
    [ "$FAULT" = "environment" ] && note "fault: environment — nothing for a product repo to repair"
    note "evidence: $RUN_DIR"
  fi
  exit $code
}
STAGE_LOG=""
trap finish EXIT

# Newline-separated `stage=outcome`, so a reader can see what ran and what was skipped
# rather than inferring it from the absence of a failure. Assigned above, before the trap
# that reads it is installed.
record_stage() { STAGE_LOG="$STAGE_LOG
$1=$2"; }

fail_stage() {
  STATUS="fail"; FAILED_STAGE="$1"; OWNERS="${2:-}"; FAULT="${3:-slice}"
  if [ "$FAULT" = "slice" ] && [ -n "$DOCS_OWNERS" ]; then
    OWNERS="$(printf '%s\n' $OWNERS $DOCS_OWNERS | awk '!s[$0]++' | tr '\n' ' ')"
    case "$FAILED_STAGE" in docs-currency:*) ;; *) FAILED_STAGE="$FAILED_STAGE; docs-currency failed for $DOCS_OWNERS" ;; esac
  fi
  record_stage "$CURRENT_STAGE" "fail"
  exit 1
}

# ------------------------------------------------------------------- preflight
stage "preflight"

# A stopped daemon is the machine, not this repo: `harness` sent 0008's amendment to "fix it
# in this repo" and overwrote STATUS.md's verified record with `unattributable`.
docker info >/dev/null 2>&1 || fail_stage "preflight: docker daemon unreachable — start Docker and re-run" "" environment

# Every slice, infra included — fanout.sh switches it to feat/<change> like any other, so
# the old exemption meant an infra slice was verified against whatever was checked out.
for repo in $CHANGE_SLICES; do
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  want="feat/$CHANGE"
  if [ "$branch" != "$want" ]; then
    if [ "$STRICT_BRANCH" = "1" ]; then
      note "$repo is on '$branch', expected '$want'."
      note "This run would assert against code this change did not write."
      note "Pass --any-branch if that is deliberate."
      fail_stage "preflight: $repo is on '$branch', expected '$want'" "" harness
    fi
    note "warning — $repo is on '$branch', not '$want'; verifying whatever is checked out"
  fi
done

# Ports must be free, or already held by our own project. Anything else is a stale stack
# from a hand-run `make up` in a product repo, and it would silently answer the smoke
# suite instead of the code under test — a false pass, which is worse than a failure.
OURS="$(docker compose -f stack/compose.yml ps -q 2>/dev/null | grep -c . || true)"
if [ "${OURS:-0}" = "0" ]; then
  for port in 8080 8000; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      note "port $port is held by another process:"
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '2,3p' | sed 's/^/verify:   /'
      note "a stale stack would answer smoke instead of the code under test."
      note "clear it (each repo has a \`make down\`) and retry."
      fail_stage "preflight: port $port already in use" "" harness
    fi
  done
fi

# Not a failure: verify always tests the working tree, and during a change the submodules
# are supposed to be ahead of the lock. Said out loud so a stale pin is never mistaken for
# a verified one.
for repo in chatbot-backend chatbot-eval frontend infra; do
  pinned="$(awk -v r="$repo" '$1==r{print $2}' repos.lock 2>/dev/null || true)"
  current="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$pinned" ] && [ -n "$current" ] && [ "$pinned" != "$current" ]; then
    note "note — $repo is ahead of repos.lock (verifying the working tree, not the lock)"
  fi
done

# Each product repo verifies its implementation against its OWN vendored copy. A slice that
# implements the frozen contract without re-vendoring leaves its CI green against the old
# promise — observed on 0002, in both slices at once. check-docs.py knows how to spot it but
# runs as a make/CI gate, so the loop was blind to exactly the drift it exists to catch.
# vendor-contracts.sh --check is the one definition of what a repo must carry — the two
# YAML specs and every events schema whose x-consumers names it.
for _r in $CHANGE_SLICES; do
  set +e
  ./scripts/vendor-contracts.sh --check --repos "$_r" 2>&1 | sed 's/^/verify:   /'
  _vc="${PIPESTATUS[0]}"
  set -e
  case "$_vc" in
    0) ;;
    1) fail_stage "preflight: $_r's vendored contracts/ differs from contracts/ — the dispatch publishes it, so this means the slice edited it or the publish did not run: ./scripts/vendor-contracts.sh" "$_r" slice ;;
    *) fail_stage "preflight: vendor-contracts.sh refused (exit $_vc) — fix contracts/ here" "" harness ;;
  esac
done

note "preflight ok"

# The change's own suite must exist. It used to be a note, and the run continued on the
# four baseline steps and reported PASS — a change verified against nothing it introduced.
[ -f "$CHANGE_SUITE" ] || fail_stage \
  "preflight: $CHANGE_SUITE does not exist — write the acceptance criteria as steps" "" harness

# -------------------------------------------------------------- docs currency
# Docs move with the code, per slice, as an owned assertion. docs/adr/0019.
stage "docs-currency: each slice's docs moved with its code"
CURRENT_STAGE="docs_currency"
set +e
./scripts/docs-currency.py --repos "$CHANGE_SLICES" --json "$RUN_DIR/docs-currency.json"
DC_RC=$?
set -e
count_assertions "$RUN_DIR/docs-currency.json"
case "$DC_RC" in
  0) record_stage docs_currency pass ;;
  1) DOCS_OWNERS="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['owners_failing']))" \
                    "$RUN_DIR/docs-currency.json")"
     record_stage docs_currency "fail: $DOCS_OWNERS"
     note "docs-currency failed for $DOCS_OWNERS — deferred, so the brief also carries smoke" ;;
  *) fail_stage "docs-currency: refused — a slice repo has no origin/main to compare against (see above)" "" harness ;;
esac

# ---------------------------------------------------------------- local deploy
if [ "$CHANGE_DEPLOY_LOCAL" = "1" ]; then
  stage "deploy: joined local stack"
  # Tee'd, because compose names the failing service on a BUILD failure — and a build
  # failure leaves nothing "unhealthy" for `ps` to report, which is exactly the case where
  # the responsible repo used to be told nothing at all.
  if ! ./scripts/stack.sh up ${BUILD_FLAG:+$BUILD_FLAG} 2>&1 | tee "$RUN_DIR/stack-up.log"; then
    bad="$(docker compose -f stack/compose.yml ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
           | awk '$2!="healthy" && $2!="" {print $1}' | tr '\n' ' ')"
    owners="$(./scripts/service-owner.sh --log "$RUN_DIR/stack-up.log" --services "$bad" \
              --slices "$CHANGE_SLICES" 2>/dev/null || true)"
    note "unhealthy service(s): ${bad:-none reported}"
    note "answerable: ${owners:-unknown}"
    fail_stage "deploy: stack did not come up healthy (${bad:-build failed})" "$owners"
  fi
  record_stage deploy_local pass
  note "stack healthy at $BASE"
else
  record_stage deploy_local "skipped: deploy.local=false"
  note "deploy.local is false in change.yaml — skipping the local stack"
fi

# ------------------------------------------------------------- contract vs served
# Structural drift, caught BEFORE smoke: smoke.py --contract only checks that a path,
# method and status are declared, never a body, so a suite can pass against something that
# is not the promise. A drift here means the suite is about to assert the wrong thing, and
# that is the right first failure. docs/adr/0003 records the residual gap this closes.
if [ "$CHANGE_DEPLOY_LOCAL" = "1" ]; then
  stage "contract: served vs contracts/openapi.yaml"
  set +e
  ./scripts/harvest-contract.py --diff --from "$DIRECT_BASE/openapi.json" \
    2>&1 | tee "$RUN_DIR/harvest.log"
  HARVEST_RC="${PIPESTATUS[0]}"
  set -e
  case "$HARVEST_RC" in
    0) record_stage contract_harvest pass ;;
    1) case " $CHANGE_SLICES " in
         *" chatbot-backend "*)
           fail_stage "contract: the served spec has drifted from the frozen contract in a way that breaks a consumer — see $RUN_DIR/harvest.log" "chatbot-backend" slice ;;
         # The backend is not a slice of this change, so nothing dispatched here can have
         # caused it: either contracts/ is wrong or the backend drifted in another change.
         *) fail_stage "contract: the served spec disagrees with contracts/openapi.yaml, and chatbot-backend is not a slice of this change — see $RUN_DIR/harvest.log" "" harness ;;
       esac ;;
    *) fail_stage "contract: could not read the served spec at $DIRECT_BASE/openapi.json" "" harness ;;
  esac
fi

# ------------------------------------------------------------------------ jobs
# A criterion whose oracle is a PROCESS rather than a request. smoke.py speaks HTTP against
# a stack somebody else brought up, so it can never start a container — and "the run exits
# non-zero when a threshold is breached" is not a thing any HTTP client can ask. Before this
# stage such a criterion had two homes and neither was an assertion: a paragraph under
# "a gap in the oracle", or a make target a human was trusted to run. See docs/adr/0014.
#
# BEFORE SMOKE, and that ordering is the point: a job produces the state the suite then
# asserts. The joined stack forgets everything on `down` (docs/adr/0011), so a suite reading
# what a job produced without the job having run in the same pass would be asserting the
# leftovers of whatever somebody did last — or, on a cold stack, nothing at all.
if [ "$CHANGE_DEPLOY_LOCAL" = "1" ] && [ "${CHANGE_JOBS_COUNT:-0}" != "0" ]; then
  stage "jobs: $CHANGE_JOBS_COUNT one-shot run(s) in the joined stack"
  JOB_TAB="$(printf '\t')"
  # Collected to a file before the loop rather than piped in from a process substitution.
  # Belt to the `< /dev/null` brace below: the list is then somewhere the loop body cannot
  # reach even if a future runner forgets to close its stdin.
  ./scripts/manifest.py "$CHANGE_DIR" --jobs > "$RUN_DIR/jobs.tsv" || \
    fail_stage "jobs: could not read the job list from change.yaml" "" harness
  while IFS="$JOB_TAB" read -r j_name j_service j_owner j_expect j_timeout j_env; do
    [ -n "$j_name" ] || continue
    j_log="$RUN_DIR/job-$j_name.log"
    note "job '$j_name': run $j_service, expect exit $j_expect, budget ${j_timeout}s"
    [ -n "$j_env" ] && note "  with: $j_env"

    # $j_env is deliberately unquoted — it is a space-separated list of KEY=VALUE words,
    # and manifest.py refuses a value containing whitespace so the split is safe.
    #
    # `< /dev/null` IS NOT TIDINESS. `docker compose run -T` still attaches stdin, and this
    # loop reads its job list from stdin — so without it the first job's container consumed
    # the second job's line, the loop ended after one iteration, and the stage reported
    # "1 of 1 job(s) exited as declared" for a two-job change. A pass that silently skipped
    # an assertion, and self-concealing: the counter and the loss had the same cause. The
    # count check after the loop is what makes it impossible rather than merely fixed.
    set +e
    ./scripts/stack.sh run "$j_service" $j_env < /dev/null > "$j_log" 2>&1 &
    j_pid=$!
    # No timeout(1) on macOS, so a watchdog per job — the same shape fanout.sh uses and for
    # the same reason: one hung run must not hold the loop open forever. The marker is
    # written BEFORE the signal, so collection can tell a timeout from a job that happened
    # to fail at the same moment.
    ( sleep "$j_timeout"; touch "$RUN_DIR/.job-timeout-$j_name"
      kill -TERM "$j_pid" 2>/dev/null ) >/dev/null 2>&1 &
    j_dog=$!
    wait "$j_pid"; j_rc=$?
    kill "$j_dog" 2>/dev/null
    set -e

    JOBS_RAN=$((JOBS_RAN + 1))
    if [ -f "$RUN_DIR/.job-timeout-$j_name" ]; then
      rm -f "$RUN_DIR/.job-timeout-$j_name"
      JOBS_FAILED=$((JOBS_FAILED + 1)); ASSERT_FAILED=$((ASSERT_FAILED + 1))
      note "job '$j_name' exceeded its ${j_timeout}s budget — see $j_log"
      fail_stage "jobs: '$j_name' timed out after ${j_timeout}s" "$j_owner" slice
    fi
    if [ "$j_rc" = "$j_expect" ]; then
      JOBS_PASSED=$((JOBS_PASSED + 1)); ASSERT_PASSED=$((ASSERT_PASSED + 1))
      note "job '$j_name' exited $j_rc as declared"
      continue
    fi
    JOBS_FAILED=$((JOBS_FAILED + 1)); ASSERT_FAILED=$((ASSERT_FAILED + 1))
    note "job '$j_name' exited $j_rc, expected $j_expect — see $j_log"
    tail -20 "$j_log" 2>/dev/null | sed 's/^/verify:   /' || true
    # Exit 2 from a job is that process refusing to judge, in the vocabulary this script
    # already uses (docs/adr/0003). Still the owner's to fix — a job that cannot reach what
    # it measures is a real failure — but calling it a threshold breach would send a repair
    # agent after a number when the cause is a missing precondition.
    if [ "$j_rc" = "2" ] && [ "$j_expect" != "2" ]; then
      fail_stage "jobs: '$j_name' refused to judge (exit 2) rather than producing a result" \
                 "$j_owner" slice
    fi
    fail_stage "jobs: '$j_name' exited $j_rc, expected $j_expect" "$j_owner" slice
  done < "$RUN_DIR/jobs.tsv"

  # THE COUNTED-EVIDENCE GATE FOR JOBS. A stage that runs a subset of what the change
  # declared and reports a pass is exactly what docs/adr/0003 forbids, and this stage did
  # it on its first outing. `fault: harness`, because a job that never started is not a
  # product repo's failure and must not be sent to one as a repair brief.
  if [ "$JOBS_RAN" != "$CHANGE_JOBS_COUNT" ]; then
    note "change.yaml declares $CHANGE_JOBS_COUNT job(s) and only $JOBS_RAN ran."
    note "The missing one asserted nothing, and this stage would otherwise have reported"
    note "a pass over the subset that did run."
    fail_stage "jobs: $JOBS_RAN of $CHANGE_JOBS_COUNT declared job(s) ran" "" harness
  fi
  record_stage jobs pass
  note "$JOBS_PASSED of $JOBS_RAN declared job(s) exited as declared"
elif [ "$CHANGE_DEPLOY_LOCAL" = "1" ]; then
  record_stage jobs "skipped: change declares none"
else
  record_stage jobs "skipped: deploy.local=false"
fi

# ----------------------------------------------------------------------- smoke
if [ "$CHANGE_DEPLOY_LOCAL" = "1" ]; then
  stage "smoke: baseline + $CHANGE_SMOKE_FILE"
  SUITES=(smoke/baseline.yaml "$CHANGE_SUITE")

  # `remote` steps assert the deployed origin and cannot pass here. Excluded rather than
  # filtered in, so an ordinary untagged step is asserted against BOTH origins by default.
  set +e
  BACKEND_DIRECT_BASE="$DIRECT_BASE" SMOKE_ORIGIN="$BASE" SMOKE_RUN_ID="$SMOKE_RUN_ID" \
    ./scripts/smoke.py "${SUITES[@]}" \
      --base "$BASE" \
      --contract contracts/openapi.yaml \
      --timeout "$CHANGE_SMOKE_TIMEOUT" \
      --exclude-tag remote \
      --keep-going \
      --json "$RUN_DIR/smoke.json"
  SMOKE_RC=$?
  set -e
  count_assertions "$RUN_DIR/smoke.json"
  case "$SMOKE_RC" in
    0) record_stage smoke pass ;;
    1) owners="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['owners_failing']))" \
                 "$RUN_DIR/smoke.json" 2>/dev/null || true)"
       fail_stage "smoke: assertions failed" "$owners" slice ;;
    # Exit 2 is smoke.py refusing to judge: a malformed step, an undefined ${VAR}, an empty
    # selection. That is this repo's fault, not a slice's, and routing it to a product repo
    # as a repair brief is how an agent gets asked to fix a suite it does not own.
    *) fail_stage "smoke: the suite is invalid — fix it here, not in a product repo" "" harness ;;
  esac
fi

# ----------------------------------------------------------------------- infra
if [ "$CHANGE_DEPLOY_INFRA" = "1" ]; then
  record_stage infra "not here: /dev-push"
  note "deploy.infra is true — this is the local half. The remote pass runs in CI:"
  note "  ./scripts/dev-push.sh $CHANGE    (or comment /dev-push on the control PR)"
else
  record_stage infra "skipped: deploy.infra=false"
fi

# ------------------------------------------------------------------------- e2e
if [ "$E2E" = "1" ]; then
  stage "e2e: frontend Playwright against $BASE"
  # playwright.config.ts drops its own webServer block when PLAYWRIGHT_BASE_URL is set,
  # so it drives the joined stack instead of standing up an isolated preview server.
  if ! ( cd frontend && PLAYWRIGHT_BASE_URL="$BASE" npx playwright test ) 2>&1 \
        | tee "$RUN_DIR/e2e.log"; then
    fail_stage "e2e: playwright failed" "frontend"
  fi
  record_stage e2e pass
else
  record_stage e2e "skipped: --e2e not given"
fi

# The deferred docs-currency failure, if nothing above already carried it.
if [ -n "$DOCS_OWNERS" ]; then
  CURRENT_STAGE="docs_currency"
  fail_stage "docs-currency: code changed without docs in: $DOCS_OWNERS" "$DOCS_OWNERS" slice
fi

# ------------------------------------------------------- the counted-evidence gate
# Everything above can pass without anything having been asserted about THIS change.
# This is the clause that makes that impossible, including for skip branches nobody has
# written yet. See docs/adr/0003.
stage "verdict"
# A job declared by THIS change is evidence about this change, exactly as one of its
# own steps is, so it satisfies the gate. Written as `or` rather than folded into
# ASSERT_FROM_CHANGE, because a reader of the notes below has to be able to see which
# kind of evidence a pass actually rests on.
if [ "$ASSERT_FROM_CHANGE" -lt 1 ] && [ "$JOBS_PASSED" -lt 1 ]; then
  note "no assertion from $CHANGE_SUITE was evaluated, and no job of this change ran."
  note "This run proves the stack still works, not that $CHANGE does."
  note "Write the acceptance criteria as steps, or check whether every step is tagged"
  note "out of the passes this run executed."
  fail_stage "verdict: no assertion from the change's own suite or jobs ran" "" harness
fi
note "$ASSERT_PASSED assertion(s) evaluated, $ASSERT_FROM_CHANGE from $CHANGE_SUITE"
[ "$JOBS_RAN" != "0" ] && note "$JOBS_PASSED of $JOBS_RAN one-shot job(s) exited as declared (of ${CHANGE_JOBS_COUNT:-0} declared)"

# The terminal marker. STATUS starts at `incomplete` and only this line makes it a pass,
# so a death anywhere above reports the stage it died in rather than a PASS.
STATUS="pass"
CURRENT_STAGE="done"
exit 0

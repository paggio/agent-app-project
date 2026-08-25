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
#     --no-infra       ignore deploy.infra — local deploy and local assertions only.
#                      Reports verified-local, never verified.
#     --plan-only      plan the infra change, never apply it, and skip the remote pass
#     --allow-destroy  proceed when `make -C infra plan` reports a destroy or replace
#     --run-dir DIR    where to write logs and json (default: changes/<change>/runs/<ts>)
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
NO_INFRA=0; PLAN_ONLY=0; ALLOW_DESTROY=0; REMOTE_SKIPPED=0
BACKEND_IMAGE=""; FRONTEND_IMAGE=""
# The outputs a remote pass cannot work without. Checked against the CONTRACT before any
# apply, so a contract that still promises nothing fails before it costs money.
REQUIRED_INFRA_OUTPUTS="app_base_url api_path_prefix deployed_backend_image deployed_frontend_image"
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-up) KEEP_UP=1 ;;
    --no-build) BUILD_FLAG="--no-build" ;;
    --e2e) E2E=1 ;;
    --any-branch) STRICT_BRANCH=0 ;;
    --no-infra) NO_INFRA=1 ;;
    --plan-only) PLAN_ONLY=1 ;;
    --allow-destroy) ALLOW_DESTROY=1 ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
CHANGE_SUITE="$CHANGE_DIR/$CHANGE_SMOKE_FILE"

note()  { echo "verify: $*"; }
stage() { CURRENT_STAGE="$1"; echo; echo "-- $* --------------------------------------------------"; }

# Assertions actually evaluated, accumulated across every suite this run executed. A pass
# requires at least one of them to have come from the change's own suite — otherwise the
# run proves the stack still works, not that this change does.
ASSERT_PASSED=0
ASSERT_FAILED=0
ASSERT_FROM_CHANGE=0

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
  fi
  if [ "$KEEP_UP" = "1" ]; then
    note "stack left running (--keep-up) at $BASE — tear down with ./scripts/stack.sh down"
  else
    ./scripts/stack.sh down >/dev/null 2>&1 || true
  fi
  # Release the environment lock only if this process took it. Never `make destroy` —
  # teardown of a real environment is a human decision, under any flag.
  [ "${LOCK_OWNED:-0}" = "1" ] && rm -rf "${LOCK_DIR:?}" 2>/dev/null || true
  python3 - "$RUN_DIR/verify.json" "$STATUS" "$FAILED_STAGE" "$OWNERS" "$CHANGE" "$BASE" \
           "$FAULT" "$ASSERT_PASSED" "$ASSERT_FAILED" "$ASSERT_FROM_CHANGE" "$CHANGE_SUITE" \
           "$STAGE_LOG" "${CHANGE_DEPLOY_ENVIRONMENT:-}" "$REMOTE_SKIPPED" <<'PY'
import json, sys
(out, status, stage, owners, change, base,
 fault, passed, failed, from_change, change_suite, stage_log,
 environment, remote_skipped) = sys.argv[1:15]
json.dump({
    "change": change, "status": status, "failed_stage": stage or None,
    "owners_failing": [o for o in owners.split() if o], "base": base,
    "fault": fault or None,
    "assertions": {
        "passed": int(passed), "failed": int(failed),
        "from_change_suite": int(from_change), "change_suite": change_suite,
    },
    "stages": dict(p.split("=", 1) for p in stage_log.split("\n") if "=" in p),
    # The loop reads this to decide between `verified` and `verified-local`. A pass that
    # never touched the remote environment must not claim it did.
    "infra": {"environment": environment or None,
              "remote_asserted": not int(remote_skipped) and bool(environment)},
}, open(out, "w"), indent=2)
PY
  echo
  if [ "$STATUS" = "pass" ]; then
    note "PASS — $CHANGE verified against $BASE"
    note "$ASSERT_PASSED assertion(s) passed, $ASSERT_FROM_CHANGE of them from $CHANGE_SUITE"
  else
    note "FAIL — $CHANGE failed at: $FAILED_STAGE"
    [ -n "$OWNERS" ] && note "answerable repo(s): $OWNERS"
    [ "$FAULT" = "harness" ] && note "fault: harness — fix this in the control repo, not in a product repo"
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
  record_stage "$CURRENT_STAGE" "fail"
  exit 1
}

# ------------------------------------------------------------------- preflight
stage "preflight"

docker info >/dev/null 2>&1 || fail_stage "preflight: docker daemon unreachable" "" harness

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
for repo in chatbot-backend frontend infra; do
  pinned="$(awk -v r="$repo" '$1==r{print $2}' repos.lock 2>/dev/null || true)"
  current="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$pinned" ] && [ -n "$current" ] && [ "$pinned" != "$current" ]; then
    note "note — $repo is ahead of repos.lock (verifying the working tree, not the lock)"
  fi
done

# ---- guards that only apply when this run will touch a real environment ----------
if [ "$CHANGE_DEPLOY_INFRA" = "1" ] && [ "$NO_INFRA" = "0" ]; then
  [ -n "${CHANGE_DEPLOY_ENVIRONMENT:-}" ] || fail_stage \
    "preflight: deploy.infra is true but deploy.environment names no environment" "" harness

  # Check the CONTRACT before spending an apply to discover it still promises nothing.
  ./scripts/infra-outputs.py --contract-only \
      --contract contracts/infra-outputs.yaml \
      $(for r in $REQUIRED_INFRA_OUTPUTS; do printf ' --require %s' "$r"; done) \
    || fail_stage "preflight: contracts/infra-outputs.yaml does not promise what a remote pass needs" "" harness

  # The remote pass registers accounts. If SIGNUP_CODE came from the committed default in
  # stack/dev.env, one of two bad things is true: the register steps will 403 and a bug
  # that does not exist gets routed to the backend, or the placeholder really is deployed
  # and registration is open with a committed code. Refuse before creating anything.
  for v in SIGNUP_CODE SMOKE_PASSWORD; do
    case " ${DEV_ENV_DEFAULTED:-} " in
      *" $v "*)
        note "$v was filled in from stack/dev.env, which is a local-dev placeholder."
        note "A remote pass would register into '$CHANGE_DEPLOY_ENVIRONMENT' with it."
        note "Supply the real value in the environment before shipping to a real target."
        fail_stage "preflight: $v is the committed local default, not a real secret" "" harness ;;
    esac
  done

  # Every identity the suite creates must live in a reserved domain, so a smoke run can
  # never collide with a real user. `.test` is reserved by RFC 2606.
  stray="$(grep -hoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' smoke/baseline.yaml "$CHANGE_SUITE" 2>/dev/null \
           | grep -vE '^smoke-[^@]*@auth\.test$' | sort -u | tr '\n' ' ' || true)"
  if [ -n "${stray// /}" ]; then
    note "these addresses are not in the reserved smoke namespace: $stray"
    note "a remote pass must only create smoke-*@auth.test identities."
    fail_stage "preflight: suite uses an address outside smoke-*@auth.test" "" harness
  fi

  # One run per environment. Terraform's own state lock stops state corruption; it does
  # not stop two runs interleaving their smoke data against one origin. mkdir is atomic
  # and there is no flock on macOS.
  LOCK_DIR=".locks/infra-$CHANGE_DEPLOY_ENVIRONMENT.lock"
  if [ "${INFRA_LOCK_HELD:-}" = "$CHANGE_DEPLOY_ENVIRONMENT" ]; then
    note "environment lock already held by the calling loop"
  else
    mkdir -p .locks
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf 'pid=%s\nrun=%s\nchange=%s\n' "$$" "$RUN_DIR" "$CHANGE" > "$LOCK_DIR/owner"
      LOCK_OWNED=1
    else
      note "environment '$CHANGE_DEPLOY_ENVIRONMENT' is locked by:"
      sed 's/^/verify:   /' "$LOCK_DIR/owner" 2>/dev/null || true
      fail_stage "preflight: environment '$CHANGE_DEPLOY_ENVIRONMENT' is already being deployed" "" harness
    fi
  fi

  stage "publish: application images"
  # Nothing else builds and pushes the app. Without this the remote pass would assert
  # whatever image is already deployed, while the local pass asserted the code under test.
  if ! ./scripts/publish.sh --env "$CHANGE_DEPLOY_ENVIRONMENT" \
        --json "$RUN_DIR/published.json" 2>&1 | tee "$RUN_DIR/publish.log"; then
    fail_stage "publish: could not build and push the application images" "" harness
  fi
  BACKEND_IMAGE="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['backend_image'])" "$RUN_DIR/published.json")"
  FRONTEND_IMAGE="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['frontend_image'])" "$RUN_DIR/published.json")"
  record_stage publish pass
fi

# Each product repo verifies its implementation against its OWN vendored copy. A slice that
# implements the frozen contract without re-vendoring leaves its CI green against the old
# promise — observed on 0002, in both slices at once. check-docs.py knows how to spot it but
# runs as a make/CI gate, so the loop was blind to exactly the drift it exists to catch.
for _r in $CHANGE_SLICES; do
  for _f in openapi.yaml infra-outputs.yaml; do
    [ -f "$_r/contracts/$_f" ] || continue
    if ! cmp -s "contracts/$_f" "$_r/contracts/$_f"; then
      fail_stage "preflight: $_r/contracts/$_f differs from contracts/$_f — the dispatch publishes it, so this means the slice edited it or the publish did not run: ./scripts/vendor-contracts.sh" "$_r" slice
    fi
  done
done

note "preflight ok"

# The change's own suite must exist. It used to be a note, and the run continued on the
# four baseline steps and reported PASS — a change verified against nothing it introduced.
[ -f "$CHANGE_SUITE" ] || fail_stage \
  "preflight: $CHANGE_SUITE does not exist — write the acceptance criteria as steps" "" harness

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
if [ "$CHANGE_DEPLOY_INFRA" = "1" ] && [ "$NO_INFRA" = "1" ]; then
  record_stage infra "skipped: --no-infra"
  note "deploy.infra is true but --no-infra was passed — nothing was deployed remotely"
  REMOTE_SKIPPED=1
elif [ "$CHANGE_DEPLOY_INFRA" = "1" ]; then
  ENV_NAME="$CHANGE_DEPLOY_ENVIRONMENT"
  stage "infra: interface"
  # The interface the infra repo must satisfy, stated in one place: `make plan` gates,
  # `make deploy` applies, `make outputs` prints a flat JSON object of the outputs
  # promised in contracts/infra-outputs.yaml. Absent targets fail loudly rather than
  # skipping — a silently skipped deploy reported as a pass is the outcome worth
  # preventing (docs/adr/0002 §4).
  for t in plan deploy outputs; do
    make -C infra -n "$t" ENV="$ENV_NAME" >/dev/null 2>&1 || {
      note "change.yaml sets deploy.infra: true, but the infra repo does not declare"
      note "\`make $t\`. Required: plan (gate), deploy (apply), outputs (flat JSON of the"
      note "outputs promised in contracts/infra-outputs.yaml). See docs/infra-interface.md."
      fail_stage "infra: deploy requested but infra declares no '$t' target" "infra"
    }
  done

  stage "infra: plan"
  set +e
  make -C infra plan ENV="$ENV_NAME" \
    BACKEND_IMAGE="$BACKEND_IMAGE" FRONTEND_IMAGE="$FRONTEND_IMAGE" \
    2>&1 | tee "$RUN_DIR/infra-plan.txt"
  PLAN_RC=${PIPESTATUS[0]}
  set -e
  case "$PLAN_RC" in
    0) note "plan is additive" ;;
    3) if [ "$ALLOW_DESTROY" = "1" ]; then
         note "plan contains a destroy or replace — proceeding under --allow-destroy"
       else
         note "the plan would destroy or replace a resource. Read $RUN_DIR/infra-plan.txt."
         note "A repair attempt must never do this implicitly; pass --allow-destroy if it"
         note "is genuinely intended."
         fail_stage "infra: plan would destroy or replace a resource" "infra"
       fi ;;
    *) fail_stage "infra: plan failed (exit $PLAN_RC)" "infra" ;;
  esac
  if [ "$PLAN_ONLY" = "1" ]; then
    record_stage infra "planned only: --plan-only"
    note "--plan-only — stopping before apply"
    REMOTE_SKIPPED=1
  else

  stage "infra: apply"
  # Re-applying on a repair attempt perturbs the very environment the failure is being
  # diagnosed against, and costs a real apply. If the infra slice has not moved since the
  # apply that succeeded earlier in this run, refresh outputs instead. Safe only because
  # the image cross-check below proves what is actually running.
  INFRA_HEAD="$(git -C infra rev-parse HEAD 2>/dev/null || echo unknown)"
  APPLIED_SHA_FILE="$(dirname "$RUN_DIR")/infra-applied.sha"
  if [ -f "$APPLIED_SHA_FILE" ] && [ "$(cat "$APPLIED_SHA_FILE")" = "$INFRA_HEAD" ]; then
    note "infra unchanged since the apply earlier in this run — skipping apply, refreshing outputs"
    record_stage infra_apply "skipped: unchanged"
  else
    if ! make -C infra deploy ENV="$ENV_NAME" \
           BACKEND_IMAGE="$BACKEND_IMAGE" FRONTEND_IMAGE="$FRONTEND_IMAGE" \
           2>&1 | tee "$RUN_DIR/infra-deploy.log"; then
      fail_stage "infra: deploy failed" "infra"
    fi
    echo "$INFRA_HEAD" > "$APPLIED_SHA_FILE"
    record_stage infra_apply pass
  fi

  if ! make -C infra outputs ENV="$ENV_NAME" \
         > "$RUN_DIR/infra-outputs.json" 2>"$RUN_DIR/infra-outputs.err"; then
    note "$(head -5 "$RUN_DIR/infra-outputs.err" 2>/dev/null || true)"
    fail_stage "infra: outputs target failed" "infra"
  fi

  stage "infra: outputs vs contract"
  # --env-out turns the promised, kind: value outputs into shell exports, and only after
  # the check passes. So the exported set is exactly the checked set: a suite cannot
  # interpolate an output the contract does not promise.
  if ! ./scripts/infra-outputs.py --actual "$RUN_DIR/infra-outputs.json" \
        --contract contracts/infra-outputs.yaml \
        --env-out "$RUN_DIR/infra-outputs.env" \
        $(for r in $REQUIRED_INFRA_OUTPUTS; do printf ' --require %s' "$r"; done) \
        --json "$RUN_DIR/infra-outputs-check.json"; then
    fail_stage "infra: outputs do not match contracts/infra-outputs.yaml" "infra"
  fi
  # shellcheck disable=SC1090
  . "$RUN_DIR/infra-outputs.env"

  stage "infra: cross-checks"
  ./scripts/infra-crosscheck.py --outputs "$RUN_DIR/infra-outputs.json" \
      --contract contracts/openapi.yaml --strip-prefix "$INFRA_API_PATH_PREFIX" \
      --backend-sha "$(git -C chatbot-backend rev-parse HEAD 2>/dev/null || true)" \
      --frontend-sha "$(git -C frontend rev-parse HEAD 2>/dev/null || true)" \
    || fail_stage "infra: the deployed environment disagrees with the frozen contract" "infra"

  stage "remote: readiness at $INFRA_APP_BASE_URL"
  ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -o /dev/null --max-time 10 \
         "${INFRA_APP_BASE_URL%/}${INFRA_API_PATH_PREFIX%/}/healthz"; then ready=1; break; fi
    sleep 6
  done
  [ "$ready" = "1" ] || fail_stage "remote: $INFRA_APP_BASE_URL never became ready" "infra"

  stage "smoke: remote pass against $INFRA_APP_BASE_URL"
  # The SAME suites, retargeted. `local` steps are excluded — a container port with no
  # remote analogue, and the per-process throttle. Everything else is asserted against
  # both origins, which is the point of the default.
  set +e
  SMOKE_ORIGIN="$INFRA_APP_BASE_URL" SMOKE_RUN_ID="$SMOKE_RUN_ID" \
    ./scripts/smoke.py smoke/baseline.yaml "$CHANGE_SUITE" \
      --base "$INFRA_APP_BASE_URL" \
      --contract contracts/openapi.yaml \
      --strip-prefix "$INFRA_API_PATH_PREFIX" \
      --timeout "$CHANGE_SMOKE_TIMEOUT" \
      --exclude-tag local \
      --keep-going \
      --json "$RUN_DIR/smoke-remote.json"
  REMOTE_RC=$?
  set -e
  count_assertions "$RUN_DIR/smoke-remote.json"
  case "$REMOTE_RC" in
    0) record_stage smoke_remote pass ;;
    1) owners="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['owners_failing']))" \
                 "$RUN_DIR/smoke-remote.json" 2>/dev/null || true)"
       fail_stage "smoke: remote assertions failed" "${owners:-infra}" slice ;;
    *) fail_stage "smoke: the remote suite is invalid — fix it here, not in a product repo" "" harness ;;
  esac
  fi  # PLAN_ONLY
else
  record_stage infra "skipped: deploy.infra=false"
  note "deploy.infra is false — skipping infra deploy (set it in change.yaml to enable)"
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

# ------------------------------------------------------- the counted-evidence gate
# Everything above can pass without anything having been asserted about THIS change.
# This is the clause that makes that impossible, including for skip branches nobody has
# written yet. See docs/adr/0003.
stage "verdict"
if [ "$ASSERT_FROM_CHANGE" -lt 1 ]; then
  note "no assertion from $CHANGE_SUITE was evaluated."
  note "This run proves the stack still works, not that $CHANGE does."
  note "Write the acceptance criteria as steps, or check whether every step is tagged"
  note "out of the passes this run executed."
  fail_stage "verdict: no assertion from the change's own suite ran" "" harness
fi
note "$ASSERT_PASSED assertion(s) evaluated, $ASSERT_FROM_CHANGE from $CHANGE_SUITE"

# The terminal marker. STATUS starts at `incomplete` and only this line makes it a pass,
# so a death anywhere above reports the stage it died in rather than a PASS.
STATUS="pass"
CURRENT_STAGE="done"
exit 0

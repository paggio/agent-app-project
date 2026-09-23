#!/usr/bin/env bash
# Deploy a resolved set of commits to a real environment and assert it through the origin a
# browser uses. The remote half of the verify loop, run by .github/workflows/dev-push.yml.
#
#   ./scripts/verify-remote.sh --deploy-set deploy-set.json --env dev [options]
#
#     --change C         assert the baseline AND changes/C's suite. Without it, the
#                        baseline only — the `--lock` redeploy /realign runs.
#     --previous FILE    `make -C infra outputs` from before the deploy, recorded as what
#                        this run replaced
#     --allow-destroy    proceed when `make -C infra plan` reports a destroy or replace
#     --run-dir DIR      where to write logs and json (default: runs/remote-<ts>)
#     --dry-run          preflight only, then print the stages; touches no cloud
#
# The same stages docs/adr/0004 put in the local loop, moved to CI by docs/adr/0018: publish,
# plan (exit 3 refused), deploy, outputs vs contract, cross-check, readiness, the suites with
# `--exclude-tag local`. `verified` is minted here and nowhere else; a set with a carried
# image reports `deployed-partial`, because the commits it asserts are not all the PR's.
#
# Exit 1 = the thing under test failed. Exit 2 = refused before the trap: bad arguments.
# Later refusals exit 1 with `fault: "harness"` in verify-remote.json. docs/adr/0003.
#
# CREDENTIALS. A role assumed from a role session lasts at most an hour, and a first apply
# plus the suite can take longer. With BASE_AWS_ACCESS_KEY_ID/_SECRET_ACCESS_KEY/
# _SESSION_TOKEN and DEPLOYER_ROLE_ARN set (the workflow sets them), each stage that reaches
# AWS re-assumes the deployer first, so every segment starts with a fresh hour. Without them
# the ambient credentials are used as they are — a hand run with with-aws.sh.
#
# No lock here: one run at a time is `concurrency: env-dev` in the workflow. A local run is
# for debugging a deploy by hand, and nothing stops it racing CI — say so if you start one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

. "$ROOT/scripts/dev-env.sh"

SET=""; ENV_NAME=""; CHANGE=""; PREVIOUS=""; ALLOW_DESTROY=0; RUN_DIR=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --deploy-set) SET="$2"; shift ;;
    --env) ENV_NAME="$2"; shift ;;
    --change) CHANGE="$2"; shift ;;
    --previous) PREVIOUS="$2"; shift ;;
    --allow-destroy) ALLOW_DESTROY=1 ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "verify-remote: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
{ [ -f "$SET" ] && [ -n "$ENV_NAME" ]; } || {
  echo "usage: verify-remote.sh --deploy-set <deploy-set.json> --env <environment>" >&2; exit 2; }

# The allowlist is manifest.py's, read rather than copied so there is one list to review.
ALLOWED="$(python3 -c "
import re
m = re.search(r'^ENVIRONMENTS = \((.*?)\)', open('scripts/manifest.py').read(), re.M)
print(' '.join(re.findall(r'\"([a-z0-9-]+)\"', m.group(1) if m else '')))")"
case " $ALLOWED " in *" $ENV_NAME "*) ;; *)
  echo "verify-remote: '$ENV_NAME' is not a deployable environment (allowed: $ALLOWED)." >&2
  echo "verify-remote: adding one is a reviewed commit to scripts/manifest.py — docs/adr/0018." >&2
  exit 2 ;;
esac

TS="$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$RUN_DIR" ] || RUN_DIR="runs/remote-$TS"
mkdir -p "$RUN_DIR"
SMOKE_RUN_ID="$(printf 'r%s' "$TS" | tr '[:upper:]' '[:lower:]')"
export SMOKE_RUN_ID

CHANGE_SUITE=""; CHANGE_SMOKE_TIMEOUT=120
if [ -n "$CHANGE" ]; then
  [ -d "changes/$CHANGE" ] || { echo "verify-remote: no such change: changes/$CHANGE" >&2; exit 2; }
  eval "$(./scripts/manifest.py "changes/$CHANGE" --shell)"
  [ "${MANIFEST_OK:-0}" = "1" ] || {
    echo "verify-remote: change.yaml has problems (above) — fix them first" >&2; exit 2; }
  CHANGE_SUITE="changes/$CHANGE/$CHANGE_SMOKE_FILE"
fi
PARTIAL="$(python3 -c "import json,sys;print('1' if json.load(open(sys.argv[1])).get('partial') else '0')" "$SET")"

REQUIRED_INFRA_OUTPUTS="app_base_url api_path_prefix deployed_backend_image deployed_frontend_image"

STATUS="incomplete"; OUTCOME=""; FAILED_STAGE=""; OWNERS=""; FAULT=""; CURRENT_STAGE="startup"
ASSERT_PASSED=0; ASSERT_FAILED=0; ASSERT_FROM_CHANGE=0; REMOTE_ASSERTED=0
BASE=""; STAGE_LOG=""

note()  { echo "verify-remote: $*"; }

# The commit checked out in a submodule, or `none`. `git -C` on an EMPTY submodule
# directory — a clone without submodules, which is what CI starts from — answers with the
# PARENT repo's HEAD, so a bare rev-parse compares the control repo's commit and can pass.
head_of() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$1" && pwd -P)" ]; then
    git -C "$1" rev-parse HEAD
  else
    echo none
  fi
}
stage() { CURRENT_STAGE="$1"; echo; echo "-- $* --------------------------------------------------"; }

refresh_aws() {
  [ -n "${DEPLOYER_ROLE_ARN:-}" ] && [ -n "${BASE_AWS_ACCESS_KEY_ID:-}" ] || return 0
  local creds
  creds="$(AWS_ACCESS_KEY_ID="$BASE_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$BASE_AWS_SECRET_ACCESS_KEY" \
           AWS_SESSION_TOKEN="$BASE_AWS_SESSION_TOKEN" \
           aws sts assume-role --role-arn "$DEPLOYER_ROLE_ARN" --duration-seconds 3600 \
             --role-session-name "verify-remote-$SMOKE_RUN_ID" \
             --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null)" \
    || fail_stage "$CURRENT_STAGE: could not re-assume the deployer role — the pushed session has likely expired; make login && make push-gh-creds" "" harness
  # shellcheck disable=SC2086
  set -- $creds
  [ "${GITHUB_ACTIONS:-}" = "true" ] && { echo "::add-mask::$2"; echo "::add-mask::$3"; }
  export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3"
}
record_stage() { STAGE_LOG="$STAGE_LOG
$1=$2"; }

count_assertions() {
  [ -f "$1" ] || return 0
  local counts
  counts="$(python3 - "$1" "$CHANGE_SUITE" <<'PY' 2>/dev/null || echo "0 0 0"
import json, sys
steps = json.load(open(sys.argv[1])).get("steps") or []
print(sum(1 for s in steps if s.get("ok")), sum(1 for s in steps if not s.get("ok")),
      sum(1 for s in steps if sys.argv[2] and s.get("suite") == sys.argv[2]))
PY
)"
  set -- $counts
  ASSERT_PASSED=$((ASSERT_PASSED + ${1:-0}))
  ASSERT_FAILED=$((ASSERT_FAILED + ${2:-0}))
  ASSERT_FROM_CHANGE=$((ASSERT_FROM_CHANGE + ${3:-0}))
}

finish() {
  local code=$?
  if [ "$STATUS" = "incomplete" ]; then
    STATUS="fail"; FAULT="harness"; OWNERS=""
    FAILED_STAGE="harness: verify-remote.sh died in stage '$CURRENT_STAGE'"
  fi
  if [ "$code" = "0" ] && [ "$STATUS" != "pass" ]; then
    STATUS="fail"; FAULT="harness"
    [ -n "$FAILED_STAGE" ] || FAILED_STAGE="harness: exited 0 without reaching the pass marker"
  fi
  [ "$STATUS" = "pass" ] || OUTCOME="failed"
  python3 - "$RUN_DIR/verify-remote.json" "$STATUS" "$OUTCOME" "$FAILED_STAGE" "$OWNERS" \
           "$CHANGE" "$BASE" "$FAULT" "$ASSERT_PASSED" "$ASSERT_FAILED" "$ASSERT_FROM_CHANGE" \
           "$CHANGE_SUITE" "$STAGE_LOG" "$ENV_NAME" "$REMOTE_ASSERTED" "$SET" \
           "$RUN_DIR/published.json" "$PREVIOUS" <<'PY'
import json, sys
(out, status, outcome, stage, owners, change, base, fault, passed, failed, from_change,
 change_suite, stage_log, environment, remote_asserted, ds, published, previous) = sys.argv[1:19]

def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return None

prev = load(previous) if previous else None
json.dump({
    "change": change or None, "status": status, "outcome": outcome,
    "failed_stage": stage or None,
    "owners_failing": [o for o in owners.split() if o], "base": base or None,
    "fault": fault or None,
    "assertions": {"passed": int(passed), "failed": int(failed),
                   "from_change_suite": int(from_change), "change_suite": change_suite or None},
    "stages": dict(p.split("=", 1) for p in stage_log.split("\n") if "=" in p),
    "infra": {"environment": environment, "remote_asserted": remote_asserted == "1"},
    "deploy_set": load(ds),
    "images": (load(published) or {}).get("images"),
    # What this deploy overwrote. dev is shared and last-writer-wins (docs/adr/0018), so a
    # reviewer of another PR needs to know their deploy is gone.
    "replaced": {k: v for k, v in (prev or {}).items() if k.startswith("deployed_")} or None,
}, open(out, "w"), indent=2)
PY
  echo
  if [ "$STATUS" = "pass" ]; then
    note "$OUTCOME — deployed to $ENV_NAME and asserted through $BASE"
    note "$ASSERT_PASSED assertion(s) passed${CHANGE:+, $ASSERT_FROM_CHANGE of them from $CHANGE_SUITE}"
  else
    note "FAIL at: $FAILED_STAGE"
    [ -n "$OWNERS" ] && note "answerable repo(s): $OWNERS"
    [ "$FAULT" = "harness" ] && note "fault: harness — fix this in the control repo, not in a product repo"
    note "evidence: $RUN_DIR"
  fi
  exit $code
}
trap finish EXIT

fail_stage() {
  STATUS="fail"; FAILED_STAGE="$1"; OWNERS="${2:-}"; FAULT="${3:-slice}"
  record_stage "$CURRENT_STAGE" "fail"
  exit 1
}

# ------------------------------------------------------------------- preflight
stage "preflight"

# Check the CONTRACT before spending an apply to discover it still promises nothing.
./scripts/infra-outputs.py --contract-only --contract contracts/infra-outputs.yaml \
    $(for r in $REQUIRED_INFRA_OUTPUTS; do printf ' --require %s' "$r"; done) \
  || fail_stage "preflight: contracts/infra-outputs.yaml does not promise what a remote pass needs" "" harness

# The suites register accounts. A committed placeholder password would be registered in a
# real environment; the workflow generates one per run. SIGNUP_CODE is resolved after the
# deploy, from the secret the environment itself reads — see "infra: outputs vs contract".
case " ${DEV_ENV_DEFAULTED:-} " in
  *" SMOKE_PASSWORD "*) fail_stage "preflight: SMOKE_PASSWORD is the committed local default in stack/dev.env — supply a real one" "" harness ;;
esac

# Every identity a suite creates is confined to a reserved domain (RFC 2606).
stray="$(grep -hoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' smoke/baseline.yaml ${CHANGE_SUITE:+"$CHANGE_SUITE"} 2>/dev/null \
         | grep -vE '^smoke-[^@]*@auth\.test$' | sort -u | tr '\n' ' ' || true)"
[ -z "${stray// /}" ] || fail_stage "preflight: suite uses an address outside smoke-*@auth.test: $stray" "" harness

# What is checked out must be what the set names, or the images and the apply describe
# commits other than the ones the PR comment will claim.
while read -r repo want; do
  [ -n "$want" ] || continue
  have="$(head_of "$repo")"
  [ "$have" = "$want" ] || fail_stage "preflight: $repo is checked out at ${have:0:12}, the deploy set says ${want:0:12}" "" harness
done < <(python3 -c "
import json, sys
for r, e in json.load(open(sys.argv[1]))['repos'].items():
    if e.get('source') == 'built' and (e.get('images') or r == 'infra'):
        print(r, e['sha'])" "$SET")

for t in plan deploy outputs; do
  make -C infra -n "$t" ENV="$ENV_NAME" >/dev/null 2>&1 \
    || fail_stage "preflight: infra declares no '$t' target — see docs/infra-interface.md" "infra"
done
record_stage preflight pass

if [ "$DRY" = "1" ]; then
  note "[dry-run] preflight passed; would publish, plan, deploy, check outputs, cross-check,"
  note "[dry-run] and assert smoke/baseline.yaml${CHANGE_SUITE:+ + $CHANGE_SUITE} against $ENV_NAME"
  STATUS="pass"; OUTCOME="dry-run"; CURRENT_STAGE="done"
  exit 0
fi

# --------------------------------------------------------------------- publish
stage "publish: application images"
refresh_aws
./scripts/publish.sh --deploy-set "$SET" --env "$ENV_NAME" --json "$RUN_DIR/published.json" \
    2>&1 | tee "$RUN_DIR/publish.log" \
  || fail_stage "publish: could not build and push the images the deploy set names" "" harness
img() { python3 -c "import json,sys;print((json.load(open(sys.argv[1]))['images']).get(sys.argv[2],''))" "$RUN_DIR/published.json" "$1"; }
BACKEND_IMAGE="$(img backend)"; FRONTEND_IMAGE="$(img frontend)"; PROXY_IMAGE="$(img proxy)"
IMAGE_ARGS=(BACKEND_IMAGE="$BACKEND_IMAGE" FRONTEND_IMAGE="$FRONTEND_IMAGE" PROXY_IMAGE="$PROXY_IMAGE")
record_stage publish pass

# ------------------------------------------------------------------------ plan
stage "infra: plan"
refresh_aws
set +e
make -C infra plan ENV="$ENV_NAME" "${IMAGE_ARGS[@]}" 2>&1 | tee "$RUN_DIR/infra-plan.txt"
PLAN_RC=${PIPESTATUS[0]}
set -e
case "$PLAN_RC" in
  0) note "plan is additive" ;;
  3) if [ "$ALLOW_DESTROY" = "1" ]; then
       note "plan contains a destroy or replace — proceeding under --allow-destroy"
     else
       note "the plan would destroy or replace a resource. Read $RUN_DIR/infra-plan.txt."
       note "Re-run as \`/dev-push --allow-destroy\` if that is genuinely intended."
       fail_stage "infra: plan would destroy or replace a resource" "infra"
     fi ;;
  *) fail_stage "infra: plan failed (exit $PLAN_RC)" "infra" ;;
esac
record_stage plan pass

# ---------------------------------------------------------------------- deploy
stage "infra: deploy"
refresh_aws
# The interface promises this returns only once the new revision is serving, or the suite
# races the rollout and the failure lands on whichever step ran first.
make -C infra deploy ENV="$ENV_NAME" "${IMAGE_ARGS[@]}" 2>&1 | tee "$RUN_DIR/infra-deploy.log" \
  || fail_stage "infra: deploy failed" "infra"
record_stage deploy pass

refresh_aws
make -s -C infra outputs ENV="$ENV_NAME" > "$RUN_DIR/infra-outputs.json" 2>"$RUN_DIR/infra-outputs.err" || {
  note "$(head -5 "$RUN_DIR/infra-outputs.err" 2>/dev/null || true)"
  fail_stage "infra: outputs target failed" "infra"; }

stage "infra: outputs vs contract"
# --env-out writes the promised kind: value outputs as INFRA_* exports only after the check
# passes, so a suite can interpolate exactly the checked set.
./scripts/infra-outputs.py --actual "$RUN_DIR/infra-outputs.json" \
    --contract contracts/infra-outputs.yaml --env-out "$RUN_DIR/infra-outputs.env" \
    $(for r in $REQUIRED_INFRA_OUTPUTS; do printf ' --require %s' "$r"; done) \
    --json "$RUN_DIR/infra-outputs-check.json" \
  || fail_stage "infra: outputs do not match contracts/infra-outputs.yaml" "infra"
# shellcheck disable=SC1090
. "$RUN_DIR/infra-outputs.env"
BASE="$INFRA_APP_BASE_URL"

# The committed dev.env code is a local placeholder. Either the register steps would 403 and
# route a nonexistent bug to the backend, or the placeholder really is deployed and
# registration is open with a committed code. So the code comes from where the backend reads
# it: the promised `signup_code_secret_ref`, a Secrets Manager ARN or an SSM parameter name.
case " ${DEV_ENV_DEFAULTED:-} " in *" SIGNUP_CODE "*)
  SREF="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('signup_code_secret_ref',''))" "$RUN_DIR/infra-outputs.json")"
  [ -n "$SREF" ] || fail_stage "infra: no signup_code_secret_ref, so the remote suite cannot register" "infra"
  case "$SREF" in
    arn:aws:secretsmanager:*) SIGNUP_CODE="$(aws secretsmanager get-secret-value --secret-id "$SREF" --query SecretString --output text 2>/dev/null || true)" ;;
    *) SIGNUP_CODE="$(aws ssm get-parameter --name "$SREF" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)" ;;
  esac
  [ -n "$SIGNUP_CODE" ] || fail_stage "infra: $SREF could not be read, so the remote suite cannot register" "infra"
  [ "${GITHUB_ACTIONS:-}" = "true" ] && echo "::add-mask::$SIGNUP_CODE"
  export SIGNUP_CODE
  note "SIGNUP_CODE read from $SREF" ;;
esac

stage "infra: cross-checks"
./scripts/infra-crosscheck.py --outputs "$RUN_DIR/infra-outputs.json" \
    --contract contracts/openapi.yaml --strip-prefix "$INFRA_API_PATH_PREFIX" \
    --deploy-set "$SET" \
  || fail_stage "infra: the deployed environment disagrees with the contract or the deploy set" "infra"
record_stage crosscheck pass

stage "remote: readiness at $BASE"
ready=0
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null --max-time 10 "${BASE%/}${INFRA_API_PATH_PREFIX%/}/healthz"; then
    ready=1; break
  fi
  sleep 6
done
[ "$ready" = "1" ] || fail_stage "remote: $BASE never became ready" "infra"

# ----------------------------------------------------------------------- smoke
stage "smoke: remote pass against $BASE"
# `local` steps are excluded — a container port with no remote analogue, the per-process
# throttle. Everything else is asserted against both origins, which is the point.
set +e
SMOKE_ORIGIN="$BASE" SMOKE_RUN_ID="$SMOKE_RUN_ID" \
  ./scripts/smoke.py smoke/baseline.yaml ${CHANGE_SUITE:+"$CHANGE_SUITE"} \
    --base "$BASE" \
    --contract contracts/openapi.yaml \
    --strip-prefix "$INFRA_API_PATH_PREFIX" \
    --timeout "$CHANGE_SMOKE_TIMEOUT" \
    --exclude-tag local \
    --keep-going \
    --json "$RUN_DIR/smoke-remote.json"
SMOKE_RC=$?
set -e
count_assertions "$RUN_DIR/smoke-remote.json"
case "$SMOKE_RC" in
  0) record_stage smoke_remote pass; REMOTE_ASSERTED=1 ;;
  1) REMOTE_ASSERTED=1
     owners="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['owners_failing']))" \
               "$RUN_DIR/smoke-remote.json" 2>/dev/null || true)"
     fail_stage "smoke: remote assertions failed" "${owners:-infra}" slice ;;
  *) fail_stage "smoke: the remote suite is invalid — fix it here, not in a product repo" "" harness ;;
esac

# dev is shared. A run from another repo is in another concurrency group, so something may
# have redeployed while the suite ran — and then the assertions above were about commits
# this run did not deploy. Re-read what runs and cross-check it again.
stage "remote: still running the deploy set"
refresh_aws
make -s -C infra outputs ENV="$ENV_NAME" > "$RUN_DIR/infra-outputs-after.json" 2>/dev/null \
  && ./scripts/infra-crosscheck.py --outputs "$RUN_DIR/infra-outputs-after.json" \
       --contract contracts/openapi.yaml --strip-prefix "$INFRA_API_PATH_PREFIX" \
       --deploy-set "$SET" >/dev/null \
  || fail_stage "remote: dev was redeployed while the suite ran — its result is about other commits; re-run" "" harness
record_stage still_deployed pass

# ------------------------------------------------------- the counted-evidence gate
stage "verdict"
if [ -n "$CHANGE" ] && [ "$ASSERT_FROM_CHANGE" -lt 1 ]; then
  note "no assertion from $CHANGE_SUITE was evaluated remotely — every step may be tagged local."
  fail_stage "verdict: no assertion from the change's own suite ran against $ENV_NAME" "" harness
fi
[ "$ASSERT_PASSED" -ge 1 ] || fail_stage "verdict: nothing was asserted against $ENV_NAME" "" harness

if [ "$PARTIAL" = "1" ]; then OUTCOME="deployed-partial"; else OUTCOME="verified"; fi
STATUS="pass"
CURRENT_STAGE="done"
exit 0

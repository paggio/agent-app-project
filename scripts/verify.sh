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
#     --strict-branch  fail, not warn, if a slice repo is not on feat/<change>
#     --run-dir DIR    where to write logs and json (default: changes/<change>/runs/<ts>)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHANGE=""; KEEP_UP=0; E2E=0; STRICT_BRANCH=0; RUN_DIR=""; BUILD_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-up) KEEP_UP=1 ;;
    --no-build) BUILD_FLAG="--no-build" ;;
    --e2e) E2E=1 ;;
    --strict-branch) STRICT_BRANCH=1 ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

eval "$(./scripts/manifest.py "$CHANGE_DIR" --shell)"
[ "${MANIFEST_OK:-0}" = "1" ] || {
  echo "verify: change.yaml has problems (above) — fix them first" >&2; exit 2; }

BASE="$CHANGE_SMOKE_BASE"
DIRECT_BASE="${BACKEND_DIRECT_BASE:-http://localhost:8000}"
STATUS="pass"
FAILED_STAGE=""
OWNERS=""

note()  { echo "verify: $*"; }
stage() { echo; echo "-- $* --------------------------------------------------"; }

finish() {
  local code=$?
  if [ "$STATUS" != "pass" ]; then
    note "capturing container logs into $RUN_DIR"
    ./scripts/stack.sh dump "$RUN_DIR" || true
  fi
  if [ "$KEEP_UP" = "1" ]; then
    note "stack left running (--keep-up) at $BASE — tear down with ./scripts/stack.sh down"
  else
    ./scripts/stack.sh down >/dev/null 2>&1 || true
  fi
  python3 - "$RUN_DIR/verify.json" "$STATUS" "$FAILED_STAGE" "$OWNERS" "$CHANGE" "$BASE" <<'PY'
import json, sys
out, status, stage, owners, change, base = sys.argv[1:7]
json.dump({
    "change": change, "status": status, "failed_stage": stage or None,
    "owners_failing": [o for o in owners.split() if o], "base": base,
}, open(out, "w"), indent=2)
PY
  echo
  if [ "$STATUS" = "pass" ]; then
    note "PASS — $CHANGE verified against $BASE"
  else
    note "FAIL — $CHANGE failed at: $FAILED_STAGE"
    [ -n "$OWNERS" ] && note "answerable repo(s): $OWNERS"
    note "evidence: $RUN_DIR"
  fi
  exit $code
}
trap finish EXIT

fail_stage() { STATUS="fail"; FAILED_STAGE="$1"; OWNERS="${2:-}"; exit 1; }

# ------------------------------------------------------------------- preflight
stage "preflight"

docker info >/dev/null 2>&1 || {
  STATUS="fail"; FAILED_STAGE="preflight: docker daemon unreachable"; exit 1; }

for repo in $CHANGE_SLICES; do
  [ "$repo" = "infra" ] && continue
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  want="feat/$CHANGE"
  if [ "$branch" != "$want" ]; then
    if [ "$STRICT_BRANCH" = "1" ]; then
      STATUS="fail"
      FAILED_STAGE="preflight: $repo is on '$branch', expected '$want'"
      exit 1
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
      STATUS="fail"; FAILED_STAGE="preflight: port $port already in use"; exit 1
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
note "preflight ok"

# ---------------------------------------------------------------- local deploy
if [ "$CHANGE_DEPLOY_LOCAL" = "1" ]; then
  stage "deploy: joined local stack"
  if ! ./scripts/stack.sh up ${BUILD_FLAG:+$BUILD_FLAG}; then
    # Which service failed to come up IS the attribution here — no smoke step ran, so
    # nothing named an owner.
    bad="$(docker compose -f stack/compose.yml ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
           | awk '$2!="healthy" && $2!="" {print $1}' | tr '\n' ' ')"
    case " $bad " in
      *" backend "*|*" postgres "*|*" redis "*) owners="chatbot-backend" ;;
      *" frontend "*|*" proxy "*)               owners="frontend" ;;
      *)                                        owners="" ;;
    esac
    note "unhealthy service(s): ${bad:-unknown}"
    fail_stage "deploy: stack did not come up healthy (${bad:-unknown})" "$owners"
  fi
  note "stack healthy at $BASE"
else
  note "deploy.local is false in change.yaml — skipping the local stack"
fi

# ----------------------------------------------------------------------- smoke
if [ "$CHANGE_DEPLOY_LOCAL" = "1" ]; then
  stage "smoke: baseline + $CHANGE_SMOKE_FILE"
  SUITES=(smoke/baseline.yaml)
  if [ -f "$CHANGE_DIR/$CHANGE_SMOKE_FILE" ]; then
    SUITES+=("$CHANGE_DIR/$CHANGE_SMOKE_FILE")
  else
    note "note — $CHANGE_DIR/$CHANGE_SMOKE_FILE not found; running baseline only"
  fi

  # A change that declares no steps of its own is verified only against the baseline —
  # i.e. against nothing it introduced. Said loudly, because a green run here would
  # otherwise read as "the change works".
  if [ -f "$CHANGE_DIR/$CHANGE_SMOKE_FILE" ] \
     && ! grep -qE '^\s*-\s+name:' "$CHANGE_DIR/$CHANGE_SMOKE_FILE"; then
    note "WARNING — $CHANGE_SMOKE_FILE declares no steps. This run proves the stack still"
    note "WARNING   works, not that $CHANGE does. Write the acceptance criteria as steps."
  fi

  if ! BACKEND_DIRECT_BASE="$DIRECT_BASE" ./scripts/smoke.py "${SUITES[@]}" \
        --base "$BASE" \
        --contract contracts/openapi.yaml \
        --timeout "$CHANGE_SMOKE_TIMEOUT" \
        --keep-going \
        --json "$RUN_DIR/smoke.json"; then
    owners="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['owners_failing']))" \
              "$RUN_DIR/smoke.json" 2>/dev/null || true)"
    fail_stage "smoke: assertions failed" "$owners"
  fi
fi

# ----------------------------------------------------------------------- infra
if [ "$CHANGE_DEPLOY_INFRA" = "1" ]; then
  stage "deploy: infra"
  # The interface infra must satisfy, stated in one place: `make deploy` applies, and
  # `make outputs` prints a flat JSON object of the outputs promised in
  # contracts/infra-outputs.yaml. Absent targets fail loudly rather than skipping —
  # a silently skipped deploy reported as a pass is the failure mode worth preventing.
  if ! make -C infra -n deploy >/dev/null 2>&1 || ! make -C infra -n outputs >/dev/null 2>&1; then
    note "change.yaml sets deploy.infra: true, but the infra repo does not declare the"
    note "deploy interface: \`make deploy\` to apply, \`make outputs\` to print a flat JSON"
    note "object of the outputs promised in contracts/infra-outputs.yaml."
    fail_stage "infra: deploy requested but infra declares no deploy target" "infra"
  fi

  if ! make -C infra deploy 2>&1 | tee "$RUN_DIR/infra-deploy.log"; then
    fail_stage "infra: deploy failed" "infra"
  fi
  if ! make -C infra outputs > "$RUN_DIR/infra-outputs.json" 2>"$RUN_DIR/infra-outputs.err"; then
    note "$(head -5 "$RUN_DIR/infra-outputs.err" 2>/dev/null || true)"
    fail_stage "infra: outputs target failed" "infra"
  fi

  stage "smoke: infra outputs vs contract"
  if ! ./scripts/infra-outputs.py --actual "$RUN_DIR/infra-outputs.json" \
        --contract contracts/infra-outputs.yaml \
        --json "$RUN_DIR/infra-outputs-check.json"; then
    fail_stage "infra: outputs do not match contracts/infra-outputs.yaml" "infra"
  fi

  # Steps tagged `infra` assert against the deployed environment rather than the local
  # origin; they reach it via ${...} variables resolved from the environment, which the
  # outputs above are exported into.
  if [ -f "$CHANGE_DIR/$CHANGE_SMOKE_FILE" ]; then
    stage "smoke: infra-tagged steps"
    if ! ./scripts/smoke.py "$CHANGE_DIR/$CHANGE_SMOKE_FILE" --tag infra --base "$BASE" \
          --keep-going --json "$RUN_DIR/smoke-infra.json"; then
      owners="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['owners_failing']))" \
                "$RUN_DIR/smoke-infra.json" 2>/dev/null || echo infra)"
      fail_stage "smoke: infra-tagged assertions failed" "${owners:-infra}"
    fi
  fi
else
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
fi

exit 0

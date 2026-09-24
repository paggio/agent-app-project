#!/usr/bin/env bash
# Run chatbot-eval against what `dev` runs, and file the experiment in dev's Phoenix. Run by
# .github/workflows/dev-eval.yml; deploys nothing. docs/adr/0018 §13.
#
#   ./scripts/eval-remote.sh --eval-dir DIR --eval-sha SHA [options]
#
#     --eval-dir DIR     a checkout of chatbot-eval at --eval-sha
#     --eval-sha SHA     recorded as EVAL_IMAGE_TAG (12 chars) — the evaluator code is a factor
#     --set FILE         this PR's resolved deploy set, compared with what dev runs
#     --deployed FILE    deployed-set.json from the state bucket: what dev runs
#     --deployed-uri URI where that came from; re-read after the eval, refused if it moved
#     --judge J          bedrock (default) or heuristic
#     --run-dir DIR      where eval-remote.json and the logs go (default: runs/eval-<ts>)
#
# Needs infra/ checked out at the commit that deployed dev, and deployer credentials in the
# environment. Secrets (the Phoenix key, the signup code) are read here, masked, passed by
# environment, and never written.
#
# Exit 0 every threshold met · 1 a threshold breached or an example errored · 2 refused:
# dev is down, an output is missing, a secret is unreadable, the eval refused. docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EVAL_DIR=""; EVAL_SHA=""; SET=""; DEPLOYED=""; DEPLOYED_URI=""; JUDGE=bedrock; RUN_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --eval-dir) EVAL_DIR="$2"; shift ;;
    --eval-sha) EVAL_SHA="$2"; shift ;;
    --set) SET="$2"; shift ;;
    --deployed) DEPLOYED="$2"; shift ;;
    --deployed-uri) DEPLOYED_URI="$2"; shift ;;
    --judge) JUDGE="$2"; shift ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "eval-remote: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
RUN_DIR="${RUN_DIR:-runs/eval-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
OUT="$RUN_DIR/eval-remote.json"

# One verdict file for every exit path, so the PR comment always has something to say.
OUTCOME=refused; REASON=""; RC=2
write_verdict() {
  python3 - "$OUT" "$OUTCOME" "$RC" "$REASON" "$EVAL_SHA" "$JUDGE" "$RUN_DIR" "${SET:-}" "${DEPLOYED:-}" <<'PY'
import json, os, re, sys
out, outcome, rc, reason, sha, judge, run_dir, set_path, dep_path = sys.argv[1:10]
def load(p):
    try:
        return json.load(open(p)) if p else None
    except Exception:
        return None
outputs = load(os.path.join(run_dir, "infra-outputs.json")) or {}
report = ""
try:
    report = open(os.path.join(run_dir, "eval.out")).read()
except OSError:
    pass
m = re.search(r"^\s*experiment\s+(\S+)", report, re.M)
pr_set, deployed = load(set_path), load(dep_path)
def shas(s):
    return {r: e.get("sha") for r, e in ((s or {}).get("repos") or {}).items()}
matches = None
if pr_set and deployed:
    want, have = shas(pr_set), shas(deployed)
    # An empty sha is a repo an --only deploy carried: unknown, so not compared.
    matches = all(want.get(r) == have.get(r) for r in ("chatbot-backend", "frontend", "infra")
                  if want.get(r) and have.get(r))
json.dump({
    "outcome": outcome, "exit": int(rc), "reason": reason or None,
    "eval_sha": sha or None, "judge": judge,
    "backend_base_url": (outputs.get("app_base_url") or "") + (outputs.get("api_path_prefix") or "") or None,
    "phoenix_base_url": outputs.get("phoenix_base_url"),
    "experiment_url": m.group(1) if m else None,
    "deployed": shas(deployed) or None,
    "deployed_is_this_pr": matches,
}, open(out, "w"), indent=2)
PY
}
# Anything that stops the script before the eval reported is a refusal, exit 2 — including
# an unexpected failure under set -e, which would otherwise exit 1 and read as a breach.
on_exit() { local c=$?; [ "$OUTCOME" = refused ] && c=2; RC=$c; write_verdict || true; exit "$c"; }
trap on_exit EXIT
refuse() { REASON="$*"; echo "eval-remote: REFUSED: $*" >&2; exit 2; }
mask() { [ "${GITHUB_ACTIONS:-}" = "true" ] && echo "::add-mask::$1"; return 0; }

case "$JUDGE" in bedrock|heuristic) ;; *) refuse "--judge takes bedrock or heuristic, got $JUDGE" ;; esac
[ -d "$EVAL_DIR" ] && [ -f "$EVAL_DIR/pyproject.toml" ] || refuse "--eval-dir $EVAL_DIR is not a chatbot-eval checkout"
[[ "$EVAL_SHA" =~ ^[0-9a-f]{40}$ ]] || refuse "--eval-sha wants a 40-char sha, got '$EVAL_SHA'"

# What dev runs. Exit 1 from the interface is "no state": dev is down, nothing to evaluate.
set +e
./scripts/infra.sh outputs ENV=dev > "$RUN_DIR/infra-outputs.json" 2> "$RUN_DIR/infra-outputs.err"
orc=$?
set -e
case "$orc" in
  0) ;;
  1) refuse "dev has no state — it is down. Comment /dev-push first." ;;
  *) refuse "infra outputs exited $orc: $(head -3 "$RUN_DIR/infra-outputs.err")" ;;
esac

out() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" "$RUN_DIR/infra-outputs.json" "$1"; }
APP="$(out app_base_url)"; PREFIX="$(out api_path_prefix)"; PHX="$(out phoenix_base_url)"
PHX_REF="$(out phoenix_api_key_secret_ref)"; SIGNUP_REF="$(out signup_code_secret_ref)"
missing=""
for pair in "app_base_url:$APP" "phoenix_base_url:$PHX" "phoenix_api_key_secret_ref:$PHX_REF" "signup_code_secret_ref:$SIGNUP_REF"; do
  [ -n "${pair#*:}" ] || missing="$missing ${pair%%:*}"
done
[ -z "$missing" ] || refuse "dev's outputs lack:$missing. They arrive with change 0007's infra; /dev-push a set that has them."

# A Secrets Manager ARN or name, else an SSM parameter. A JSON secret with one string value
# is unwrapped. Nothing here echoes a value.
read_secret() {
  local ref="$1" v
  case "$ref" in
    arn:aws:ssm:*|/*) v="$(aws ssm get-parameter --name "$ref" --with-decryption --query Parameter.Value --output text 2>/dev/null)" || return 1 ;;
    *) v="$(aws secretsmanager get-secret-value --secret-id "$ref" --query SecretString --output text 2>/dev/null)" || return 1 ;;
  esac
  python3 -c '
import json, sys
v = sys.stdin.read().rstrip("\n")
try:
    d = json.loads(v)
except ValueError:
    d = None
if isinstance(d, dict):
    vals = [x for x in d.values() if isinstance(x, str)]
    if len(vals) != 1:
        sys.exit(1)
    v = vals[0]
print(v)' <<< "$v"
}
PHOENIX_API_KEY="$(read_secret "$PHX_REF")" && [ -n "$PHOENIX_API_KEY" ] || refuse "could not read $PHX_REF"
mask "$PHOENIX_API_KEY"
SIGNUP_CODE="$(read_secret "$SIGNUP_REF")" && [ -n "$SIGNUP_CODE" ] || refuse "could not read $SIGNUP_REF"
mask "$SIGNUP_CODE"

# The rest of the configuration, from the committed defaults. stack/dev.env is config, not
# secrets; only these keys are taken.
devenv() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' stack/dev.env; }
KEYS="EVAL_PHOENIX_PROJECT_NAME EVAL_DATASET_NAME EVAL_DOCUMENT_PREFIX EVAL_THREAD_PREFIX
EVAL_JUDGE_MODEL_ID EVAL_JUDGE_PROMPT_VERSION EVAL_THRESHOLD_ROUTING_ACCURACY
EVAL_THRESHOLD_RETRIEVAL_RECALL EVAL_THRESHOLD_GROUNDEDNESS EVAL_THRESHOLD_ANSWER_CORRECTNESS"
for k in $KEYS; do
  v="$(devenv "$k")"; [ -n "$v" ] || refuse "stack/dev.env declares no $k"
  export "$k=$v"
done

# A fresh account per run: dev is shared, and a committed password would be one registered
# in a real environment. dev forgets its data on down (ADR 0011).
NONCE="${GITHUB_RUN_ID:-local}-$(openssl rand -hex 4)"
EVAL_ACCOUNT_PASSWORD="eval-$(openssl rand -hex 12)"; mask "$EVAL_ACCOUNT_PASSWORD"
export EVAL_BACKEND_BASE_URL="$APP$PREFIX" EVAL_PHOENIX_BASE_URL="$PHX" \
  EVAL_ACCOUNT_EMAIL="eval-$NONCE@auth.test" EVAL_ACCOUNT_PASSWORD \
  EVAL_IMAGE_TAG="${EVAL_SHA:0:12}" EVAL_JUDGE="$JUDGE" PHOENIX_API_KEY SIGNUP_CODE

echo "eval-remote: chatbot-eval ${EVAL_SHA:0:12} against $EVAL_BACKEND_BASE_URL, judge $JUDGE, Phoenix $PHX" >&2
set +e
( cd "$EVAL_DIR" && uv sync --frozen --quiet && uv run --frozen python -m eval ) \
  > "$RUN_DIR/eval.out" 2> "$RUN_DIR/eval.err"
RC=$?
set -e

# The eval's own output can echo a rejected request body (a 422 carries its input), and
# ::add-mask:: covers only the job log — not the artifact, not the PR comment.
python3 - "$RUN_DIR/eval.out" "$RUN_DIR/eval.err" <<'PY'
import os, sys
secrets = [os.environ[k] for k in ("PHOENIX_API_KEY", "SIGNUP_CODE", "EVAL_ACCOUNT_PASSWORD") if os.environ.get(k)]
for path in sys.argv[1:]:
    text = open(path, errors="replace").read()
    for s in secrets:
        text = text.replace(s, "***")
    open(path, "w").write(text)
PY
cat "$RUN_DIR/eval.out"

# Exit 1 is a breach only when the eval reached its verdict. An uncaught exception also
# exits 1 — that is the eval failing to judge, not the backend scoring badly.
if [ "$RC" = 1 ] && ! grep -q '^  exit 1 ' "$RUN_DIR/eval.out"; then RC=3; fi
case "$RC" in
  0) OUTCOME=passed ;;
  1) OUTCOME=breached ;;
  *) RC=2; OUTCOME=refused
     REASON="$(grep -m1 'REFUSED' "$RUN_DIR/eval.err" || grep -m1 -E '^[A-Za-z.]+(Error|Exception):' "$RUN_DIR/eval.err" || tail -1 "$RUN_DIR/eval.err")" ;;
esac

# A deploy is not serialised with an eval. A verdict about a set dev no longer runs is none.
if [ -n "$DEPLOYED_URI" ] && [ -n "$DEPLOYED" ]; then
  now="$(aws s3 cp --quiet "$DEPLOYED_URI" - 2>/dev/null)" || now=""
  if [ "$(printf '%s' "$now" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))' 2>/dev/null)" \
       != "$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$DEPLOYED")" ]; then
    OUTCOME=refused; REASON="dev was redeployed during the eval (or $DEPLOYED_URI became unreadable); re-run /dev-eval"
    exit 2
  fi
fi
exit "$RC"

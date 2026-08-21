#!/usr/bin/env bash
# Build the application images and push them, tagged with the submodule SHA.
#
#   ./scripts/publish.sh --env staging [--json out.json] [--dry-run]
#
# WHY THIS LIVES HERE. `make -C infra deploy` cannot build the app: that repo has no
# access to application source and must not have any. But without a publish step the
# remote pass asserts whatever image is already deployed, while the local pass asserts the
# code under test — so a repair attempt's fix would be invisible remotely and the loop
# could report `verified` for an environment running last week's backend. The control repo
# is the only place that can see both submodules at once, so it is the only place that can
# tag an image with the SHA that was verified locally.
#
# The registry is not configured here. It is an infra OUTPUT — `backend_image_repository`
# and `frontend_image_repository`, produced by a one-time `make -C infra bootstrap` and
# promised in contracts/infra-outputs.yaml. That keeps "where images live" a fact about
# the environment rather than a constant in a script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_NAME=""; JSON_OUT=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift ;;
    --json) JSON_OUT="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "publish: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$ENV_NAME" ] || { echo "usage: publish.sh --env <environment>" >&2; exit 2; }

say() { echo "publish: $*"; }

# The registries come from infra, which must already have been bootstrapped. Reading them
# here rather than applying first is deliberate: an image must exist before the apply that
# references it, so bootstrap -> outputs -> push -> plan -> apply is the only order that
# terminates.
REG_JSON="$(make -C infra outputs ENV="$ENV_NAME" 2>/dev/null || true)"
if [ -z "${REG_JSON// /}" ]; then
  say "\`make -C infra outputs ENV=$ENV_NAME\` produced nothing."
  say "The environment must be bootstrapped before anything can be published to it:"
  say "  make -C infra bootstrap ENV=$ENV_NAME"
  exit 1
fi

read_out() {
  python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
v=d.get(sys.argv[1])
print(v if v else '')" "$1" <<< "$REG_JSON"
}

BACKEND_REPO="$(read_out backend_image_repository)"
FRONTEND_REPO="$(read_out frontend_image_repository)"
for pair in "backend_image_repository:$BACKEND_REPO" "frontend_image_repository:$FRONTEND_REPO"; do
  if [ -z "${pair#*:}" ]; then
    say "infra does not promise ${pair%%:*} for '$ENV_NAME' — nothing to push to."
    exit 1
  fi
done

BACKEND_SHA="$(git -C chatbot-backend rev-parse HEAD)"
FRONTEND_SHA="$(git -C frontend rev-parse HEAD)"
BACKEND_IMAGE="$BACKEND_REPO:${BACKEND_SHA:0:12}"
FRONTEND_IMAGE="$FRONTEND_REPO:${FRONTEND_SHA:0:12}"

# Refuse to publish a dirty tree: the tag would name a commit that does not describe what
# is in the image, and the cross-check downstream would pass while being wrong.
for repo in chatbot-backend frontend; do
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    say "$repo has uncommitted changes. The image tag is a commit SHA, so publishing now"
    say "would ship something no commit describes. Commit or stash first."
    exit 1
  fi
done

say "backend  -> $BACKEND_IMAGE"
say "frontend -> $FRONTEND_IMAGE"

if [ "$DRY" = "0" ]; then
  docker build -t "$BACKEND_IMAGE" chatbot-backend
  docker build -t "$FRONTEND_IMAGE" frontend
  docker push "$BACKEND_IMAGE"
  docker push "$FRONTEND_IMAGE"
else
  say "[dry-run] not building or pushing"
fi

if [ -n "$JSON_OUT" ]; then
  python3 - "$JSON_OUT" "$BACKEND_IMAGE" "$FRONTEND_IMAGE" "$BACKEND_SHA" "$FRONTEND_SHA" <<'PY'
import json, sys
out, bi, fi, bs, fs = sys.argv[1:6]
json.dump({"backend_image": bi, "frontend_image": fi,
           "backend_sha": bs, "frontend_sha": fs}, open(out, "w"), indent=2)
PY
fi

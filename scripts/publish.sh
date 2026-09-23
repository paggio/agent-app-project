#!/usr/bin/env bash
# Build and push the images a deploy set names, tagged with the commit that built them.
#
#   ./scripts/publish.sh --deploy-set deploy-set.json --env dev \
#       [--outputs infra-outputs.json] [--json published.json] [--dry-run]
#
# WHY THIS LIVES HERE. `make -C infra deploy` cannot build the app: that repo has no
# access to application source and must not have any. The control repo is the only place
# that can see every repo at the SHAs scripts/deploy-set.py resolved, so it is the only
# place that can tag an image with the commit that was asserted. docs/adr/0018 §5.
#
# The registries are infra OUTPUTS (`*_image_repository`), created by a one-time
# `make -C infra bootstrap` — "where images live" is a fact about the environment, not a
# constant here. Tags are immutable in ECR, so a tag that already exists is the image
# that commit built and is not rebuilt: a re-run of /dev-push costs an apply, not a build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_NAME=""; SET=""; OUTPUTS=""; JSON_OUT=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift ;;
    --deploy-set) SET="$2"; shift ;;
    --outputs) OUTPUTS="$2"; shift ;;
    --json) JSON_OUT="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "publish: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
{ [ -n "$ENV_NAME" ] && [ -f "$SET" ]; } || {
  echo "usage: publish.sh --deploy-set <deploy-set.json> --env <environment>" >&2; exit 2; }

say() { echo "publish: $*"; }

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

# An image must exist before the apply that references it, so bootstrap -> outputs ->
# push -> plan -> apply is the only order that terminates.
if [ -z "$OUTPUTS" ]; then
  OUTPUTS="$(mktemp)"
  make -s -C infra outputs ENV="$ENV_NAME" > "$OUTPUTS" 2>/dev/null || true
fi
if [ ! -s "$OUTPUTS" ]; then
  say "\`make -C infra outputs ENV=$ENV_NAME\` produced nothing."
  say "The environment must be bootstrapped before anything can be published to it:"
  say "  make -C infra bootstrap ENV=$ENV_NAME"
  exit 1
fi

# One line per image: <image> <repo> <tag> <source> <registry> <context> <dockerfile>
PLAN="$(python3 - "$SET" "$OUTPUTS" <<'PY'
import json, sys
ds = json.load(open(sys.argv[1]))
out = json.load(open(sys.argv[2]))
BUILD = {"backend": ("chatbot-backend", "Dockerfile"),
         "frontend": ("frontend", "Dockerfile"),
         "proxy": ("frontend", "Dockerfile.proxy")}
for repo, e in ds["repos"].items():
    for image, tag in (e.get("images") or {}).items():
        ctx, dockerfile = BUILD[image]
        registry = out.get(f"{image}_image_repository") or "-"
        print(image, repo, tag, e["source"], registry, ctx, dockerfile)
PY
)"

LOGGED_IN=""
RESULTS=""
while read -r image repo tag source registry ctx dockerfile; do
  [ -n "$image" ] || continue
  if [ "$registry" = "-" ]; then
    say "infra does not promise ${image}_image_repository for '$ENV_NAME' — nowhere to push $image."
    exit 1
  fi
  ref="$registry:$tag"
  host="${registry%%/*}"; name="${registry#*/}"

  if [ "$DRY" = "1" ]; then
    say "[dry-run] $image -> $ref ($source)"
    RESULTS="$RESULTS $image=$ref"
    continue
  fi

  if [ -z "$LOGGED_IN" ]; then
    aws ecr get-login-password | docker login --username AWS --password-stdin "$host" >/dev/null
    LOGGED_IN=1
  fi

  exists=0
  # `< /dev/null` on everything in this loop: it reads its plan from stdin, and a child
  # that drains stdin ends it after one image — verify.sh's jobs stage shipped that bug.
  aws ecr describe-images --repository-name "$name" --image-ids imageTag="$tag" \
    < /dev/null >/dev/null 2>&1 && exists=1

  if [ "$source" = "carried" ]; then
    # A carried image is what dev already runs. If the registry no longer has it, the
    # apply would roll a pod onto an image that cannot be pulled.
    [ "$exists" = "1" ] || { say "$image is carried at $tag, and $registry has no such tag."; exit 1; }
    say "$image carried at $ref"
  elif [ "$exists" = "1" ]; then
    say "$image already built at $ref — not rebuilding"
  else
    [ -f "$ctx/$dockerfile" ] || { say "$ctx/$dockerfile does not exist; $repo cannot build $image."; exit 1; }
    want="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['repos'][sys.argv[2]]['sha'])" "$SET" "$repo")"
    have="$(head_of "$repo")"
    # The tag names a commit. Building anything else would put a true-looking tag on an
    # image no commit describes, and the cross-check downstream would pass while wrong.
    [ "$have" = "$want" ] || { say "$repo is at ${have:0:12}, the deploy set says ${want:0:12}."; exit 1; }
    [ -z "$(git -C "$repo" status --porcelain)" ] || { say "$repo has uncommitted changes."; exit 1; }
    say "$image -> $ref (building $repo@${want:0:12})"
    docker buildx build --platform linux/amd64 -f "$ctx/$dockerfile" -t "$ref" --push "$ctx" < /dev/null
  fi
  RESULTS="$RESULTS $image=$ref"
done <<< "$PLAN"

if [ -n "$JSON_OUT" ]; then
  python3 - "$JSON_OUT" $RESULTS <<'PY'
import json, sys
json.dump({"images": dict(p.split("=", 1) for p in sys.argv[2:])},
          open(sys.argv[1], "w"), indent=2)
PY
fi

#!/usr/bin/env bash
# Does the deployed environment agree with the frozen contract about the API prefix, and
# is it running the code this run just verified locally?
#
#   ./scripts/infra-crosscheck.sh --outputs <infra-outputs.json> \
#       --contract contracts/openapi.yaml --strip-prefix /api
#
# Two checks, both cheap, both closing a silent pass.
#
# 1. THE PREFIX. Locally the proxy's `handle_path /api/*` STRIPS /api before forwarding,
#    and contracts/openapi.yaml declares `servers: [{url: /api}]` with paths written as
#    the backend serves them. An ALB path rule does NOT strip a prefix without an explicit
#    rewrite. Worse, the frontend serves the SPA shell with a 200 for any unmatched path,
#    so a rule that never matches /api/* answers API calls with 200 text/html rather than
#    a 404. Three things must name the same prefix: what infra says it configured, what
#    the contract declares, and what smoke strips before matching. Two of the three legs
#    need no deploy at all.
#
# 2. THE IMAGES. `make -C infra deploy` cannot build the app, so without this the remote
#    pass would assert whatever image happened to be deployed while the local pass
#    asserted the code under test. Comparing the deployed image tags against the submodule
#    SHAs turns "the remote pass tested this change" from an assumption into a fact.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUTS=""; CONTRACT="contracts/openapi.yaml"; STRIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --outputs) OUTPUTS="$2"; shift ;;
    --contract) CONTRACT="$2"; shift ;;
    --strip-prefix) STRIP="$2"; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "infra-crosscheck: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$OUTPUTS" ] || { echo "usage: infra-crosscheck.sh --outputs FILE [...]" >&2; exit 2; }

BACKEND_SHA="$(git -C chatbot-backend rev-parse HEAD 2>/dev/null || echo unknown)"
FRONTEND_SHA="$(git -C frontend rev-parse HEAD 2>/dev/null || echo unknown)"

python3 - "$OUTPUTS" "$CONTRACT" "$STRIP" "$BACKEND_SHA" "$FRONTEND_SHA" <<'PY'
import json, sys, yaml

outputs_path, contract_path, strip, backend_sha, frontend_sha = sys.argv[1:6]
out = json.load(open(outputs_path))
spec = yaml.safe_load(open(contract_path)) or {}

problems = []

# ---- 1. the prefix, three ways ------------------------------------------------------
declared = ""
servers = spec.get("servers") or []
if servers:
    declared = (servers[0] or {}).get("url") or ""
promised = out.get("api_path_prefix") or ""


def norm(p):
    return "/" + p.strip("/") if p.strip("/") else "/"


if norm(promised) != norm(declared):
    problems.append(
        f"api_path_prefix: infra deployed {promised!r} but {contract_path} declares "
        f"servers[0].url = {declared!r}. The proxy strips this prefix; if the deployed "
        f"edge strips a different one, every API path is wrong."
    )
if norm(promised) != norm(strip):
    problems.append(
        f"api_path_prefix: infra deployed {promised!r} but smoke will strip {strip!r} "
        f"before matching the contract, so the remote pass would assert the wrong paths."
    )

# ---- 2. the images actually running -------------------------------------------------
for name, sha, repo in (("deployed_backend_image", backend_sha, "chatbot-backend"),
                        ("deployed_frontend_image", frontend_sha, "frontend")):
    ref = out.get(name) or ""
    tag = ref.rsplit(":", 1)[-1] if ":" in ref else ""
    if not tag:
        problems.append(f"{name}: {ref!r} carries no tag, so what is running cannot be identified")
    elif not sha.startswith(tag) and not tag.startswith(sha[:12]):
        problems.append(
            f"{name}: the environment is running {tag!r} but {repo} is at {sha[:12]!r}. "
            f"The remote pass would assert code this run did not verify locally."
        )

for p in problems:
    print(f"infra-crosscheck: {p}", file=sys.stderr)
if problems:
    sys.exit(1)
print(f"infra-crosscheck: prefix {norm(promised)} agrees with the contract and with smoke; "
      f"deployed images match the submodule SHAs")
PY

#!/usr/bin/env bash
# Which repo is answerable for a stack that did not come up.
#
#   ./scripts/service-owner.sh --log <stack-up.log> --services "<names>" --slices "<repos>"
#
# Prints a space-separated list of repo names on stdout, and never prints nothing: a
# deploy that failed during a change is a slice's fault, and blaming nobody means no
# repair pass at all, which is the silent skip docs/adr/0002 rejects.
#
# Three ordered sources:
#   1. compose's own output. A BUILD failure leaves nothing "unhealthy" for `ps` to name,
#      so this is the only source that can attribute a broken Dockerfile — the case where
#      the responsible repo previously got told nothing.
#   2. the owner labels on the unhealthy services, read from the joined compose config.
#      ALL matching owners, not the first: two broken repos are two briefs.
#   3. every slice in the change.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG=""; SERVICES=""; SLICES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="$2"; shift ;;
    --services) SERVICES="$2"; shift ;;
    --slices) SLICES="$2"; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "service-owner: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

COMPOSE_FILE="${STACK_COMPOSE_FILE:-stack/compose.yml}"

# service -> owning repo, from the labels in the joined compose file. The join is the only
# file that can see both repos, so that is where ownership is declared; this reads it back
# rather than hardcoding a second copy of the mapping.
owner_of() {
  python3 - "$COMPOSE_FILE" "$1" <<'PY' 2>/dev/null || true
import subprocess, sys, json
path, service = sys.argv[1], sys.argv[2]
try:
    cfg = json.loads(subprocess.run(
        ["docker", "compose", "-f", path, "config", "--format", "json"],
        capture_output=True, text=True, timeout=60, check=True).stdout)
except Exception:
    sys.exit(0)
svc = (cfg.get("services") or {}).get(service) or {}
owner = (svc.get("labels") or {}).get("agentapp.owner")
if isinstance(owner, list):  # compose may normalise labels to a list
    owner = next((x.split("=", 1)[1] for x in owner if x.startswith("agentapp.owner=")), None)
if owner:
    print(owner)
PY
}

FOUND=""
add() { case " $FOUND " in *" $1 "*) ;; *) FOUND="$FOUND $1" ;; esac; }

# 1. compose names the failing service on a build or start failure.
if [ -n "$LOG" ] && [ -f "$LOG" ]; then
  for svc in $(grep -oE 'service "[a-zA-Z0-9_-]+"' "$LOG" 2>/dev/null \
               | sed 's/service "//; s/"//' | sort -u); do
    o="$(owner_of "$svc")"
    [ -n "$o" ] && add "$o"
  done
  # `failed to solve` / `ERROR [backend ...]` shapes from buildkit
  for svc in $(grep -oE 'ERROR \[[a-zA-Z0-9_-]+' "$LOG" 2>/dev/null \
               | sed 's/ERROR \[//' | sort -u); do
    o="$(owner_of "$svc")"
    [ -n "$o" ] && add "$o"
  done
fi

# 2. every unhealthy service's owner.
for svc in $SERVICES; do
  o="$(owner_of "$svc")"
  [ -n "$o" ] && add "$o"
done

# 3. fall back to the whole change rather than to nobody.
if [ -z "${FOUND// /}" ]; then
  FOUND="$SLICES"
fi

echo "${FOUND# }"

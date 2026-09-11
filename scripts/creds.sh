#!/usr/bin/env bash
# Which provider inputs the joined stack will actually use, and where each came from.
#
#   ./scripts/creds.sh          (or `make creds`)
#
# Exists because `make eval JUDGE=bedrock` failed with "Could not load credentials ... You
# must specify a region", and nothing could tell you that the credentials were fine and the
# REGION was missing. One command, one answer.
#
# NAMES AND PROVENANCE ONLY, NEVER VALUES. This script prints to a terminal that ends up in
# transcripts and run artifacts, which is the same argument docs/adr/0006 makes for keeping
# credentials out of every control-repo process. A masked length is the most it will say.
#
# It reads stack/secrets.env directly rather than through dev-env.sh, because dev-env.sh is
# forbidden from naming that file — check-docs.py [provider-credentials] enforces that.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SECRETS="stack/secrets.env"

# Names only. This function must never return or print a value.
_has() {
  # $1 file · $2 name → prints "set (N chars)" | "empty" | ""
  local f="$1" name="$2" line val
  [ -f "$f" ] || return 0
  line="$(grep -E "^(export[[:space:]]+)?${name}=" "$f" 2>/dev/null | head -1)" || true
  [ -n "$line" ] || return 0
  val="${line#*=}"
  if [ -z "$val" ]; then printf 'declared but EMPTY'; else printf 'set (%s chars)' "${#val}"; fi
}

echo
echo "  provider inputs for the joined stack"
echo

if [ -f "$SECRETS" ]; then
  echo "  $SECRETS                  present"
else
  echo "  $SECRETS                  MISSING"
  echo "      cp stack/secrets.env.example $SECRETS   and fill it in"
fi
echo

printf '  %-22s %-28s %s\n' NAME "stack/secrets.env" "process environment"
for name in AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  from_file="$(_has "$SECRETS" "$name")"
  from_env=""
  # Indirect expansion, so the VALUE is only ever measured and never printed.
  [ -n "${!name:-}" ] && from_env="set (${#!name} chars)"
  printf '  %-22s %-28s %s\n' "$name" "${from_file:--}" "${from_env:--}"
done
echo

# The one line that would have saved the run. A region is not optional and its absence
# surfaces as a credentials error, which sends you looking in the wrong place.
REGION_OK=0
for name in AWS_REGION AWS_DEFAULT_REGION; do
  [ -n "${!name:-}" ] && REGION_OK=1
  _f="$(_has "$SECRETS" "$name")"
  [ -n "$_f" ] && [ "$_f" != "declared but EMPTY" ] && REGION_OK=1
done
KEY_OK=0
[ -n "$(_has "$SECRETS" AWS_ACCESS_KEY_ID)" ] && [ "$(_has "$SECRETS" AWS_ACCESS_KEY_ID)" != "declared but EMPTY" ] && KEY_OK=1
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && KEY_OK=1

if [ "$REGION_OK" = "1" ] && [ "$KEY_OK" = "1" ]; then
  echo "  bedrock: ready — CHAT_MODEL=bedrock make up   ·   make eval JUDGE=bedrock"
elif [ "$KEY_OK" = "1" ]; then
  echo "  bedrock: NO REGION. boto3 refuses without one and reports it as a credentials"
  echo "           error, which is why this is the first thing to check. Set AWS_REGION in"
  echo "           $SECRETS."
else
  echo "  bedrock: not configured — the stack runs CHAT_MODEL=echo and the heuristic judge,"
  echo "           which is the credential-free default and what CI does."
fi
echo
echo "  submodule .env files still work for running a repo standalone; the joined stack"
echo "  takes its values from $SECRETS, which wins over them. docs/adr/0016."
echo

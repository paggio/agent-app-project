#!/usr/bin/env bash
# Stop hook — blocks the turn from ending until the gates pass.
# exit 0 = allow; exit 2 = block, stderr goes back to the agent.
# Budget ~10s: the full suite belongs in CI.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}" || exit 0

# Second pass after a block: let the turn end rather than loop.
INPUT="$(cat 2>/dev/null || true)"
[[ "$INPUT" == *'"stop_hook_active":true'* ]] && exit 0

fail() { printf '%s\n' "$1" >&2; exit 2; }

# `make check` is the gate. It refuses until a toolchain fills it — that is on purpose.
OUT="$(make check 2>&1)" || fail "make check failed:

$OUT"

# Docs move with the code.
BASE="$(git merge-base HEAD main 2>/dev/null || echo HEAD)"
CHANGED="$(git diff --name-only "$BASE" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
if grep -qE '^src/' <<<"$CHANGED" && ! grep -qE '^docs/' <<<"$CHANGED"; then
  fail "You changed src/ without touching docs/. Update docs/architecture.md or add an ADR in this change."
fi
exit 0

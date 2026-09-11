#!/usr/bin/env bash
# Publish contracts/ into each product repo's vendored copy.
#
#   ./scripts/vendor-contracts.sh [--from DIR] [--repos a,b] [--check] [--quiet]
#
#     --from DIR   the contracts/ tree to publish (default: this repo's working copy).
#                  fanout.sh passes the tree extracted at the freeze SHA, so a slice is
#                  handed exactly the promise it is judged against.
#     --repos a,b  only these submodules (default: every one of them)
#     --check      report what would change and exit 1 if anything would; write nothing
#
# WHY THIS EXISTS. contracts/ has one author, and the product repos are consumers: their
# own settings deny editing it and their CLAUDE.md says never to. But their CI verifies
# against that vendored copy, so a frozen contract that never reaches it leaves them green
# against the old promise. Asking the slice to copy the file made the correct engineering
# action the one that violated the stated rule — and the two repos resolved that
# contradiction in opposite directions. Publishing from the owner dissolves it: nobody
# edits the vendored copy, and it is always current. See docs/adr/0008.
#
# Only the machine-checked specs are published. contracts/README.md is deliberately NOT
# touched: each repo carries a short vendored notice pointing here, and replacing it with
# the normative copy is a separate decision with its own cost.
#
# Exit 0 = published (or nothing to do). Exit 1 = --check found drift. Exit 2 = refused.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILES="openapi.yaml infra-outputs.yaml"
REPOS="chatbot-backend chatbot-eval frontend infra"
FROM="$ROOT/contracts"
CHECK=0; QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift ;;
    --repos) REPOS="$(echo "$2" | tr ',' ' ')"; shift ;;
    --check) CHECK=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vendor-contracts: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$FROM" ] || { echo "vendor-contracts: no such contracts tree: $FROM" >&2; exit 2; }

say() { [ "$QUIET" = "1" ] || echo "$@"; }

DRIFT=0
for r in $REPOS; do
  # A submodule that is not checked out, or does not vendor contracts at all, is not a
  # failure: infra vendors only the README today.
  [ -d "$r/contracts" ] || continue
  for f in $FILES; do
    src="$FROM/$f"
    dst="$r/contracts/$f"
    [ -f "$src" ] || continue
    # Only refresh what the repo already vendors. Introducing a file it never consumed
    # would put a promise in its tree that nothing there reads.
    [ -f "$dst" ] || continue
    if cmp -s "$src" "$dst"; then continue; fi
    DRIFT=1
    if [ "$CHECK" = "1" ]; then
      say "vendor-contracts: $dst is stale"
    else
      cp "$src" "$dst"
      say "vendor-contracts: published -> $dst"
    fi
  done
done

if [ "$CHECK" = "1" ]; then
  [ "$DRIFT" = "0" ] && { say "vendor-contracts: every vendored copy matches $FROM"; exit 0; }
  exit 1
fi
[ "$DRIFT" = "0" ] && say "vendor-contracts: nothing to publish"
exit 0

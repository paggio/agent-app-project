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
#     --briefs DIR a change directory: a repo whose slice brief (DIR/<repo>.md) names
#                  contracts/<file> reads it. fanout.sh and verify.sh both pass it, so a
#                  reader the slice is about to become gets its copy at dispatch, not a
#                  refusal at verify (0009: analytics-dbt, infra-outputs.yaml).
#
# WHY THIS EXISTS. contracts/ has one author, and the product repos are consumers: their
# own settings deny editing it and their CLAUDE.md says never to. But their CI verifies
# against that vendored copy, so a frozen contract that never reaches it leaves them green
# against the old promise. Asking the slice to copy the file made the correct engineering
# action the one that violated the stated rule — and the two repos resolved that
# contradiction in opposite directions. Publishing from the owner dissolves it: nobody
# edits the vendored copy, and it is always current. See docs/adr/0008.
#
# Every JSON contract one directory down — contracts/events/*.schema.json, and any new kind
# such as contracts/mcp/<server>.json — goes to exactly the submodules its
# top-level "x-consumers" names, plus its "x-producer" when it declares one — a first-time file has no reader yet for the rule below to
# find, so the schema says who it binds. Missing or empty x-consumers, unparseable JSON, or a
# consumer that is not a submodule is a refusal naming the file.
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
REPOS="$("$ROOT"/scripts/repos.py names)"
FROM="$ROOT/contracts"
BRIEFS=""
CHECK=0; QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift ;;
    --repos) REPOS="$(echo "$2" | tr ',' ' ')"; shift ;;
    --check) CHECK=1 ;;
    --briefs) BRIEFS="$2"; shift ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "vendor-contracts: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$FROM" ] || { echo "vendor-contracts: no such contracts tree: $FROM" >&2; exit 2; }

say() { [ "$QUIET" = "1" ] || echo "$@"; }

# "<repo> <kind>/<file>" per consumer, for every JSON contract under $FROM/<kind>/. Exit 2 on
# any that does not say, validly, who consumes it.
EVENTS="$(python3 - "$FROM" "$(git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}' | tr '\n' ' ')" <<'PY'
import glob, json, os, sys
src, subs = sys.argv[1], set(sys.argv[2].split())
bad = []
for path in sorted(glob.glob(os.path.join(src, "*", "*.json"))):
    name = os.path.relpath(path, src)
    try:
        doc = json.load(open(path))
    except (OSError, ValueError) as exc:
        bad.append(f"contracts/{name} is not valid JSON: {exc}"); continue
    cons = doc.get("x-consumers") if isinstance(doc, dict) else None
    # The producer verifies what it serves against the same copy its consumers hold.
    prod = doc.get("x-producer") if isinstance(doc, dict) else None
    if not isinstance(cons, list) or not cons or not all(isinstance(c, str) for c in cons):
        bad.append(f"contracts/{name} has no x-consumers list naming the submodules it binds"); continue
    unknown = [c for c in cons if c not in subs]
    if unknown:
        bad.append(f"contracts/{name} x-consumers names {', '.join(unknown)}, not a submodule"); continue
    if prod is not None and prod not in subs:
        bad.append(f"contracts/{name} x-producer names {prod}, not a submodule"); continue
    for c in dict.fromkeys(cons + ([prod] if prod else [])):
        print(c, name)
for b in bad:
    print(f"vendor-contracts: {b}", file=sys.stderr)
sys.exit(2 if bad else 0)
PY
)" || exit 2

DRIFT=0
for r in $REPOS; do
  # A submodule that is not checked out, or does not vendor contracts at all, is not a
  # failure.
  [ -d "$r/contracts" ] || continue
  for f in $FILES; do
    src="$FROM/$f"
    dst="$r/contracts/$f"
    [ -f "$src" ] || continue
    # Publish what the repo vendors, or reads: a file nothing there names would be a promise
    # nobody checks. "Already vendors" alone never reached infra, whose tests/contract.sh
    # reads contracts/infra-outputs.yaml and SKIPPED, green, for want of it (0007).
    if [ ! -f "$dst" ] && ! git -C "$r" grep -qF "contracts/$f" -- . ':(exclude)contracts' 2>/dev/null \
       && ! { [ -n "$BRIEFS" ] && grep -qF "contracts/$f" "$BRIEFS/$r.md" 2>/dev/null; }; then
      continue
    fi
    if cmp -s "$src" "$dst" 2>/dev/null; then continue; fi
    DRIFT=1
    if [ "$CHECK" = "1" ]; then
      if [ -f "$dst" ]; then say "vendor-contracts: $dst is stale"
      else say "vendor-contracts: $dst is missing, and $r reads it"; fi
    else
      cp "$src" "$dst"
      say "vendor-contracts: published -> $dst"
    fi
  done
done

# JSON contracts: the consumer list is the reader, so a missing copy is drift, and the directory is
# created. A consumer outside --repos, or not checked out, is skipped like the YAML above.
while read -r r f; do
  [ -n "$r" ] || continue
  case " $REPOS " in *" $r "*) ;; *) continue ;; esac
  [ -e "$r/.git" ] || continue
  src="$FROM/$f"; dst="$r/contracts/$f"
  if cmp -s "$src" "$dst" 2>/dev/null; then continue; fi
  DRIFT=1
  if [ "$CHECK" = "1" ]; then
    if [ -f "$dst" ]; then say "vendor-contracts: $dst is stale"
    else say "vendor-contracts: $dst is missing, and x-consumers or x-producer names $r"; fi
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    say "vendor-contracts: published -> $dst"
  fi
done <<< "$EVENTS"

if [ "$CHECK" = "1" ]; then
  [ "$DRIFT" = "0" ] && { say "vendor-contracts: every vendored copy matches $FROM"; exit 0; }
  exit 1
fi
[ "$DRIFT" = "0" ] && say "vendor-contracts: nothing to publish"
exit 0

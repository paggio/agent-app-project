#!/usr/bin/env bash
# Refresh repos.lock from the current submodule SHAs.
#
# This duplicates what git already stores in the submodule pointers, on purpose: it is
# human- and agent-readable without git plumbing, and it is what CI reads to verify a
# product repo's vendored contracts match the control repo.
#
# Collect first, write second. `printf '%s' "$(git -C "$r" rev-parse HEAD)"` does NOT trip
# `set -e` when the substitution fails — it is an argument, not a command — and the
# `> repos.lock` redirect had already truncated the file by then. An un-checked-out
# submodule therefore wrote an empty SHA field into the one artifact product-repo CI and
# `make repos` read as truth. A lie in a committed file outlives the run that wrote it.
set -euo pipefail

REPOS=(chatbot-backend frontend infra)

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "# Submodule SHAs known to work together"
  echo "# Regenerate with ./scripts/lock.sh"
  echo "# Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TMP"

for r in "${REPOS[@]}"; do
  sha="$(git -C "$r" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$sha" ]; then
    echo "lock: $r has no HEAD (submodule not checked out?) — run \`make init\`, then re-run." >&2
    echo "lock: repos.lock left unchanged." >&2
    exit 1
  fi
  printf '%-16s %s\n' "$r" "$sha" >> "$TMP"
done

cat "$TMP" > repos.lock
cat repos.lock

#!/usr/bin/env bash
# Refresh repos.lock from the current submodule SHAs.
#
# This duplicates what git already stores in the submodule pointers, on purpose: it is
# human- and agent-readable without git plumbing, and it is what CI reads to verify a
# product repo's vendored contracts match the control repo.
set -euo pipefail

REPOS=(chatbot-backend frontend infra)

{
  echo "# Submodule SHAs known to work together"
  echo "# Regenerate with ./scripts/lock.sh"
  echo "# Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for r in "${REPOS[@]}"; do
    printf '%-16s %s\n' "$r" "$(git -C "$r" rev-parse HEAD)"
  done
} > repos.lock

cat repos.lock

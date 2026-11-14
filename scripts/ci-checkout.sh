#!/usr/bin/env bash
# CI only: check out, at its resolved SHA, every repo the deploy set BUILDS — the ones with
# images in .gitmodules whose source is `built`. publish.sh builds from these directories.
# Needs the host aliases ci-deploy-keys.sh wrote.
#
#   ./scripts/ci-checkout.sh <deploy-set.json>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SET="${1:?usage: ci-checkout.sh <deploy-set.json>}"
for repo in $(./scripts/repos.py names); do
  [ -n "$(./scripts/repos.py images "$repo")" ] || continue
  [ "$(jq -r --arg r "$repo" '.repos[$r].source // empty' "$SET")" = built ] || continue
  sha="$(jq -r --arg r "$repo" '.repos[$r].sha' "$SET")"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" fetch -q --depth 1 "git@github.com-$repo:$OWNER/$repo.git" "$sha"
  git -C "$repo" checkout -q FETCH_HEAD
  echo "ci-checkout: $repo at ${sha:0:12}"
done

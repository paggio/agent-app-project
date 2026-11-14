#!/usr/bin/env bash
# CI only: one SSH host alias per repo, so each is reached with its own read-only deploy key.
# With every key in one agent, GitHub authenticates the first and refuses the rest.
# Shared by dev-push.yml and dev-eval.yml. Reads OWNER and SECRETS (`toJSON(secrets)`), so a
# repo attached by new-repo.sh needs no workflow edit: its DEPLOY_KEY_<REPO> is found by name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
for repo in $("$ROOT"/scripts/repos.py names); do
  name="DEPLOY_KEY_$(echo "$repo" | tr 'a-z-' 'A-Z_')"
  key="$(jq -r --arg n "$name" '.[$n] // empty' <<< "$SECRETS")"
  [ -n "$key" ] || { echo "::error::secret $name is not set — run \`make gh-setup\`"; exit 2; }
  printf '%s\n' "$key" > ~/.ssh/"$repo"; chmod 600 ~/.ssh/"$repo"
  printf 'Host github.com-%s\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/%s\n  IdentitiesOnly yes\n' \
    "$repo" "$repo" >> ~/.ssh/config
done
echo "DEPLOY_SET_URL_TEMPLATE=git@github.com-{repo}:$OWNER/{repo}.git" >> "$GITHUB_ENV"
echo "DEPLOY_SET_KEY_TEMPLATE=$HOME/.ssh/{repo}" >> "$GITHUB_ENV"

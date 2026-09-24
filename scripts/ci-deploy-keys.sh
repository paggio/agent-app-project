#!/usr/bin/env bash
# CI only: one SSH host alias per repo, so each is reached with its own read-only deploy key.
# With every key in one agent, GitHub authenticates the first and refuses the rest.
# Shared by dev-push.yml and dev-eval.yml. Reads OWNER and K_BACKEND K_EVAL K_FRONTEND K_INFRA.
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
for pair in chatbot-backend:K_BACKEND chatbot-eval:K_EVAL frontend:K_FRONTEND infra:K_INFRA; do
  repo="${pair%%:*}"; var="${pair#*:}"
  printf '%s\n' "${!var}" > ~/.ssh/"$repo"; chmod 600 ~/.ssh/"$repo"
  printf 'Host github.com-%s\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/%s\n  IdentitiesOnly yes\n' \
    "$repo" "$repo" >> ~/.ssh/config
done
echo "DEPLOY_SET_URL_TEMPLATE=git@github.com-{repo}:$OWNER/{repo}.git" >> "$GITHUB_ENV"
echo "DEPLOY_SET_KEY_TEMPLATE=$HOME/.ssh/{repo}" >> "$GITHUB_ENV"

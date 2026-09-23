#!/usr/bin/env bash
# `make gh-setup`: the one-time GitHub wiring /dev-push needs. Idempotent.
#
#   ./scripts/gh-setup.sh [--role-arn <arn>] [--dry-run]
#
#   1. a READ-ONLY deploy key per repo (title agentapp-dev-push), its private half stored
#      as DEPLOY_KEY_<REPO> in every repo that runs the workflow. The control workflow has
#      to read four other private repos at the resolved SHAs, and GITHUB_TOKEN reads only
#      its own. One key per repo because GitHub refuses one deploy key on two repos.
#   2. the control repo's Actions access level set to `user`, so a product repo's workflow
#      may call the reusable dev-push.yml. Without it the caller fails to resolve the file.
#   3. DEV_AWS_DEPLOYER_ROLE_ARN, the role every job assumes (bootstrap creates it, so pass
#      --role-arn once `make -C infra bootstrap` has printed it).
#
# A re-run replaces the key rather than adding a second: an unused key with read access is
# exactly the credential nobody remembers to revoke. docs/adr/0018 §7.
set -euo pipefail

OWNER="Paggio"
REPOS="agent-app-project chatbot-backend chatbot-eval frontend infra"
TITLE="agentapp-dev-push"
ROLE_ARN=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role-arn) ROLE_ARN="$2"; shift ;;
    --dry-run) DRY=1 ;;
    *) echo "usage: gh-setup.sh [--role-arn <arn>] [--dry-run]" >&2; exit 2 ;;
  esac
  shift
done

say() { echo "gh-setup: $*"; }
run() { if [ "$DRY" = "1" ]; then say "[dry-run] $*"; else "$@"; fi; }
secret_name() { echo "DEPLOY_KEY_$(echo "$1" | tr 'a-z-' 'A-Z_')"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for repo in $REPOS; do
  full="$OWNER/$repo"
  for id in $(gh api "repos/$full/keys" --jq ".[] | select(.title==\"$TITLE\") | .id" 2>/dev/null || true); do
    run gh api -X DELETE "repos/$full/keys/$id" --silent
    say "$full: removed the previous $TITLE key"
  done
  ssh-keygen -q -t ed25519 -N "" -C "$TITLE@$repo" -f "$TMP/$repo"
  run gh api -X POST "repos/$full/keys" -f title="$TITLE" -f key="$(cat "$TMP/$repo.pub")" \
    -F read_only=true --silent
  say "$full: read-only deploy key added"
  name="$(secret_name "$repo")"
  for holder in $REPOS; do
    if [ "$DRY" = "1" ]; then say "[dry-run] gh secret set $name -R $OWNER/$holder < <private key>"
    else gh secret set "$name" -R "$OWNER/$holder" < "$TMP/$repo" >/dev/null; fi
  done
  say "$name stored in: $REPOS"
done

run gh api -X PUT "repos/$OWNER/agent-app-project/actions/permissions/access" \
  -f access_level=user --silent
say "agent-app-project: reusable workflows callable from $OWNER's repos"

if [ -n "$ROLE_ARN" ]; then
  for holder in $REPOS; do
    run gh variable set DEV_AWS_DEPLOYER_ROLE_ARN -R "$OWNER/$holder" --body "$ROLE_ARN"
  done
  say "DEV_AWS_DEPLOYER_ROLE_ARN set in: $REPOS"
else
  say "no --role-arn: DEV_AWS_DEPLOYER_ROLE_ARN not set. Re-run with the ARN bootstrap printed."
fi

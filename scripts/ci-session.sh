#!/usr/bin/env bash
# CI only: refuse (exit 2) unless the pushed AWS session has >= 30 minutes left and the
# deployer role is known. An expired session is the harness refusing, never a failed deploy.
# Shared by dev-push.yml and dev-eval.yml. Reads EXPIRES and ROLE. docs/adr/0018 §6.
set -euo pipefail
[ -n "${EXPIRES:-}" ] || { echo "::error::no DEV_AWS_CREDENTIALS_EXPIRE_AT — run \`make login && make push-gh-creds\`"; exit 2; }
[ -n "${ROLE:-}" ] || { echo "::error::no DEV_AWS_DEPLOYER_ROLE_ARN — run \`make gh-setup --role-arn <bootstrap's deployer role>\`"; exit 2; }
left=$(( ( $(date -d "$EXPIRES" +%s) - $(date +%s) ) / 60 ))
echo "session expires $EXPIRES ($left min)"
[ "$left" -ge 30 ] || { echo "::error::the pushed AWS session expires in $left min — run \`make login && make push-gh-creds\`"; exit 2; }

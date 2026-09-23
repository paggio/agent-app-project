#!/usr/bin/env bash
# Run ONE command with the AWS session from stack/secrets.env, and nothing else with it.
#
#   ./scripts/with-aws.sh make -C infra bootstrap ENV=dev
#   ./scripts/with-aws.sh kubectl get pods -A
#
# docs/adr/0006 keeps credentials out of every control-repo process, because this repo
# writes run artifacts. The exceptions are hand tools that write none — bootstrap,
# teardown, a look at the cluster — and this is how they get a session: exported into the
# environment of the command named, never into the shell that called it. `make login`
# refreshes the file; an expired or nearly expired session is refused (exit 2) rather than
# handed to a destroy that would die halfway.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$ROOT/stack/secrets.env"
MIN_MINUTES="${WITH_AWS_MIN_MINUTES:-15}"

[ $# -gt 0 ] || { echo "usage: with-aws.sh <command> [args...]" >&2; exit 2; }
[ -f "$SECRETS" ] || { echo "with-aws: $SECRETS is missing — run \`make login\`." >&2; exit 2; }

NAMES="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION AWS_REGION AWS_DEFAULT_REGION"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#export }"
  key="${line%%=*}"
  case " $NAMES " in *" $key "*) export "$key=${line#*=}" ;; esac
done < <(grep -E '^(export[[:space:]]+)?AWS_[A-Z_]+=' "$SECRETS")

[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "with-aws: no AWS_ACCESS_KEY_ID in $SECRETS — run \`make login\`." >&2; exit 2; }

if [ -n "${AWS_CREDENTIAL_EXPIRATION:-}" ]; then
  left="$(python3 - "$AWS_CREDENTIAL_EXPIRATION" <<'PY'
import sys, datetime
t = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
print(int((t - datetime.datetime.now(datetime.timezone.utc)).total_seconds() // 60))
PY
)"
  if [ "$left" -lt "$MIN_MINUTES" ]; then
    echo "with-aws: the session in $SECRETS expires in ${left} min (< ${MIN_MINUTES}) — run \`make login\`." >&2
    exit 2
  fi
fi

exec "$@"

#!/usr/bin/env bash
# Put the CURRENT short-lived AWS credentials into this repo's Actions secrets, so
# the deploy workflow can deploy as you without a long-lived key ever existing.
#
#   ./scripts/push-gh-creds.sh            (or `make push-gh-creds`)
#   ./scripts/push-gh-creds.sh --status   what is on GitHub now, and when it expires
#
# WHY THIS EXISTS. The AWS account is a company account, and a long-lived access key for it
# must not sit in a private repo's secrets. So nothing long-lived is ever created: you log
# in through Identity Center (`make login`), and this pushes the resulting SESSION
# credentials — which expire — into GitHub. The cost is that they expire, and that cost is
# paid in three places on purpose: this script refuses to push an expired session, it
# publishes the expiry as a VARIABLE so a workflow can say "these are stale" instead of
# dying halfway through a terraform apply, and `make login` prints the window you have.
#
# THE CREDENTIAL NEVER LANDS ANYWHERE. It is read from the SSO cache and written to GitHub
# through a pipe, and that is the whole of its life in this process:
#
#   - never in a file. Not a temp file, not a dotenv, not `gh secret set --env-file`.
#   - never in argv, which is world-readable through `ps`. `gh secret set` reads stdin
#     when `--body` is absent, and that is why it is absent.
#   - never in a shell variable that outlives one pipeline, and never printed. The only
#     thing this script will ever say about a credential is its name.
#   - never from stack/secrets.env. That file belongs to the Docker daemon (docs/adr/0016)
#     and this reads the SSO profile instead, so 0016's rule stands untouched.
#
# docs/adr/0018 is the amendment that permits this one script to hold a credential at all,
# and scripts/check-docs.py [credential-handling] is what keeps the list above true.
#
# Exit codes (docs/adr/0003):
#   0  the secrets on GitHub are now the credentials you are logged in with
#   1  the thing under test failed — no session, an expired one, or gh refused
#   2  this script refused to judge — bad arguments, missing tool, no remote
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${AWS_PROFILE:-sample-agent-dev}"
STATUS_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift ;;
    --status)  STATUS_ONLY=1 ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "push-gh-creds: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { echo "push-gh-creds: $*"; }
die2() { say "$*" >&2; exit 2; }
die1() { say "$*" >&2; exit 1; }

for t in aws gh jq git; do
  command -v "$t" >/dev/null 2>&1 || die2 "$t is not installed, and this cannot run without it."
done

# The repo these secrets belong to is the one you are standing in. Derived rather than
# configured, so a second clone or a fork cannot push a company credential to the wrong
# place by inheriting a constant.
ORIGIN="$(git remote get-url origin 2>/dev/null)" || die2 "no 'origin' remote — nothing to push to."
REPO="$(printf '%s' "$ORIGIN" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
case "$REPO" in
  */*) : ;;
  *) die2 "could not read OWNER/REPO out of '$ORIGIN'." ;;
esac

# ── what is on GitHub now ────────────────────────────────────────────────────────────────
# Names and timestamps only. A secret's value cannot be read back out of GitHub, which is
# the point, so this reports the expiry VARIABLE instead — that is why it is a variable and
# not a secret: a workflow has to be able to print it in a failure message.
show_status() {
  local expiry now
  echo
  echo "  GitHub Actions secrets on $REPO"
  echo
  gh secret list --repo "$REPO" 2>/dev/null \
    | awk 'BEGIN{n=0} $1 ~ /^AWS_/ {printf "    %-24s updated %s\n", $1, $2; n++} END{if(n==0) print "    (none — run make push-gh-creds)"}'
  echo
  expiry="$(gh variable get AWS_CREDS_EXPIRY --repo "$REPO" 2>/dev/null || true)"
  if [ -z "$expiry" ]; then
    echo "    expiry           unknown — nothing has been pushed by this script yet"
  else
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$expiry" \< "$now" ]; then
      echo "    expiry           $expiry  — EXPIRED. the deploy workflow will refuse."
      echo "                     make login && make push-gh-creds"
    else
      echo "    expiry           $expiry  (now $now)"
    fi
  fi
  echo
}

if [ "$STATUS_ONLY" = "1" ]; then show_status; exit 0; fi

# ── the session has to be live before anything is pushed ─────────────────────────────────
# Pushing an already-expired credential is worse than pushing nothing: the deploy workflow would take
# the secrets at face value, start, and fail somewhere in the middle of an apply.
if ! aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
  say "the SSO session for profile '$PROFILE' is expired or absent." >&2
  say "  make login" >&2
  exit 1
fi

ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null)"
REGION="$(aws configure get region --profile "$PROFILE" 2>/dev/null)"
[ -n "$REGION" ] || die1 "profile '$PROFILE' names no region. boto3 and terraform both refuse without one, and the failure reads as a credentials error."

# Read ONE field, straight into the pipe that consumes it. `jq -j` so no trailing newline
# is stored as part of the secret — gh takes stdin verbatim.
_field() {
  aws configure export-credentials --profile "$PROFILE" --format process 2>/dev/null \
    | jq -j --arg f "$1" '.[$f] // empty'
}

EXPIRY="$(_field Expiration)"
[ -n "$EXPIRY" ] || die1 "profile '$PROFILE' exports no Expiration — these look like static credentials, and this script is for short-lived ones only."

say "profile $PROFILE · account $ACCOUNT · region $REGION"
say "pushing to $REPO, expiring $EXPIRY"

# Three secrets, three pipes. The `|| exit 1` is per-secret: a partial push must be loud,
# because a half-updated triple is credentials that cannot work and cannot be diagnosed.
push_secret() {
  # $1 = secret name · $2 = field in the exported credential
  _field "$2" | gh secret set "$1" --repo "$REPO" >/dev/null 2>&1 \
    || die1 "gh refused to set $1. Check: gh auth status"
  say "  $1  set"
}

push_secret AWS_ACCESS_KEY_ID     AccessKeyId
push_secret AWS_SECRET_ACCESS_KEY SecretAccessKey
push_secret AWS_SESSION_TOKEN     SessionToken

# NOT secrets. The region is public, and the expiry has to be readable by a workflow so it
# can refuse with a date in the message rather than an opaque AWS error.
gh variable set AWS_REGION        --repo "$REPO" --body "$REGION" >/dev/null 2>&1 || die1 "gh refused to set the AWS_REGION variable."
gh variable set AWS_CREDS_EXPIRY  --repo "$REPO" --body "$EXPIRY" >/dev/null 2>&1 || die1 "gh refused to set the AWS_CREDS_EXPIRY variable."
say "  AWS_REGION, AWS_CREDS_EXPIRY  set (variables, not secrets)"

show_status
say "these expire. Re-run after every 'make login'."

#!/usr/bin/env bash
# Refresh the AWS credentials in stack/secrets.env from the SSO profile, leaving everything
# else in that file exactly as it was.
#
#   ./scripts/secrets-refresh.sh          (or `make secrets-refresh`)
#
# WHY. stack/secrets.env is how the joined stack gets Bedrock credentials — compose hands it
# to the Docker daemon through `env_file:` (docs/adr/0016). Filling it by pasting from the
# Identity Center console is how it was done, and the paste rots: the credentials in it were
# already expired the first time anyone checked. This rewrites the five AWS lines from the
# profile you are logged into, so `make login` is the only thing you have to remember.
#
# WHAT IT WILL NOT TOUCH. Everything that is not one of the five AWS names is copied through
# byte for byte — the comments, and CHAT_MODEL and EVAL_JUDGE. Those two are MODE selectors
# and they live in this file on purpose (docs/adr/0017): credentials alone switch nothing, so
# a refresh that reset the mode would silently put the stack back on `echo` and the next eval
# run would measure the wrong thing.
#
# This writes a credential to disk, which push-gh-creds.sh deliberately never does — but the
# file is the one place in this repo whose whole job is to hold one, it is gitignored, and it
# is written 0600 through a temp file rather than a truncating redirect. docs/adr/0018.
#
# Exit codes (docs/adr/0003): 0 written · 1 no live session · 2 refused (missing tool/file)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${AWS_PROFILE:-sample-agent-dev}"
SECRETS="stack/secrets.env"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift ;;
    -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "secrets-refresh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { echo "secrets-refresh: $*"; }
die2() { say "$*" >&2; exit 2; }
die1() { say "$*" >&2; exit 1; }

for t in aws jq; do
  command -v "$t" >/dev/null 2>&1 || die2 "$t is not installed."
done

if [ ! -f "$SECRETS" ]; then
  [ -f "$SECRETS.example" ] || die2 "neither $SECRETS nor $SECRETS.example exists."
  say "$SECRETS did not exist — starting from the template."
  install -m 600 "$SECRETS.example" "$SECRETS"
fi

if ! aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
  say "the SSO session for profile '$PROFILE' is expired or absent." >&2
  say "  make login" >&2
  exit 1
fi

REGION="$(aws configure get region --profile "$PROFILE" 2>/dev/null)"
[ -n "$REGION" ] || die1 "profile '$PROFILE' names no region. Its absence surfaces as a credentials error, which is why stack/secrets.env carries it at all."

# The credential passes from aws to jq to awk through pipes and into a temp file. It is
# never interpolated into a command line and never echoed.
TMP="$(mktemp "${TMPDIR:-/tmp}/secrets-refresh.XXXXXX")" || die2 "could not create a temp file."
chmod 600 "$TMP"
trap 'rm -f "$TMP" "$TMP.new"' EXIT

aws configure export-credentials --profile "$PROFILE" --format process 2>/dev/null \
  | jq -j --arg region "$REGION" '
  "AWS_REGION=" + $region + "\n" +
  "AWS_DEFAULT_REGION=" + $region + "\n" +
  "AWS_ACCESS_KEY_ID=" + .AccessKeyId + "\n" +
  "AWS_SECRET_ACCESS_KEY=" + .SecretAccessKey + "\n" +
  "AWS_SESSION_TOKEN=" + (.SessionToken // "") + "\n" +
  "#EXPIRES " + (.Expiration // "unknown") + "\n"
' > "$TMP.new" || die1 "could not export credentials from profile '$PROFILE'."
chmod 600 "$TMP.new"
[ -s "$TMP.new" ] || die1 "profile '$PROFILE' exported nothing. Is the session live? make login"

EXPIRY="$(sed -n 's/^#EXPIRES //p' "$TMP.new")"

# Copy the old file through, swapping the value of any of the five names, and remember which
# ones were actually there. Anything unrecognised — comments included — passes untouched.
awk -v newfile="$TMP.new" '
  BEGIN {
    while ((getline line < newfile) > 0) {
      if (line ~ /^#/) continue
      eq = index(line, "=")
      repl[substr(line, 1, eq - 1)] = line
    }
  }
  {
    line = $0
    stripped = line
    sub(/^[[:space:]]*export[[:space:]]+/, "", stripped)
    eq = index(stripped, "=")
    if (eq > 0) {
      key = substr(stripped, 1, eq - 1)
      if (key in repl) { print repl[key]; seen[key] = 1; next }
    }
    print line
  }
  END {
    for (k in repl) if (!(k in seen)) print repl[k]
  }
' "$SECRETS" > "$TMP" || die2 "could not rewrite $SECRETS."

# Mode first, then content: the file must never exist, even briefly, holding a fresh
# credential under permissions wider than the owner.
chmod 600 "$SECRETS"
cat "$TMP" > "$SECRETS"

say "profile $PROFILE · region $REGION"
say "wrote the five AWS names into $SECRETS, expiring $EXPIRY"
say "CHAT_MODEL and EVAL_JUDGE were left as they were — credentials do not switch the mode."
say "check it with: make creds"

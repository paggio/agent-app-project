#!/usr/bin/env bash
# `make login`: an SSO session, written into the joined stack's credentials file.
#
#   ./scripts/login.sh            AWS_SSO_PROFILE overrides the profile
#
# Pasting keys by hand into stack/secrets.env produced a session that expired an hour later
# with nothing saying when. This logs in through IAM Identity Center and rewrites exactly
# four lines — the three credentials and AWS_CREDENTIAL_EXPIRATION — leaving every other
# line, the region and the mode included, as it was. The expiry is what with-aws.sh and
# push-gh-creds.sh refuse on. docs/adr/0018 §6.
#
# It prints the identity and the expiry, never a value. The credentials travel from the
# AWS CLI to the file over a pipe, not through argv or this shell's environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$ROOT/stack/secrets.env"
PROFILE="${AWS_SSO_PROFILE:-sample-agent-dev}"

aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE" || {
  echo "login: no AWS profile named '$PROFILE' in ~/.aws/config." >&2
  echo "login: configure one with \`aws configure sso\`, or set AWS_SSO_PROFILE." >&2
  exit 2; }

aws sso login --profile "$PROFILE"

[ -f "$SECRETS" ] || { cp "$ROOT/stack/secrets.env.example" "$SECRETS"; echo "login: created $SECRETS from the template"; }
chmod 600 "$SECRETS"

# The script is read into a variable first: a heredoc on `python3 -` would BE its stdin,
# and the credentials arrive on stdin.
REWRITE="$(cat <<'PY'
import os, re, sys
path = sys.argv[1]
WANT = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_CREDENTIAL_EXPIRATION")
new = {}
for line in sys.stdin.read().splitlines():
    k, _, v = line.partition("=")
    if k in WANT:
        new[k] = v
missing = [k for k in WANT[:3] if not new.get(k)]
if missing:
    sys.exit(f"login: the CLI exported no {', '.join(missing)}")

out, placed = [], set()
for line in open(path).read().splitlines():
    m = re.match(r"^(?:export\s+)?([A-Z_]+)=", line)
    key = m.group(1) if m else None
    if key in WANT:
        if key not in placed and key in new:
            out.append(f"{key}={new[key]}")
            placed.add(key)
        continue  # a second copy, or an `export ` form, is dropped: one line per name
    out.append(line)
for k in WANT:
    if k in new and k not in placed:
        out.append(f"{k}={new[k]}")
tmp = path + ".tmp"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
    fh.write("\n".join(out) + "\n")
os.replace(tmp, path)
print(f"login: wrote {len(new)} line(s) to stack/secrets.env; expires "
      f"{new.get('AWS_CREDENTIAL_EXPIRATION', 'at an unknown time')}")
PY
)"
aws configure export-credentials --profile "$PROFILE" --format env-no-export \
  | python3 -c "$REWRITE" "$SECRETS"

echo "login: identity $(aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text)"
echo "login: next, if CI should deploy with it: make push-gh-creds"

#!/usr/bin/env bash
# `make push-gh-creds`: hand the current SSO session to the repos that can deploy to dev.
#
#   ./scripts/push-gh-creds.sh [--dry-run]
#
# The user's choice over OIDC (docs/adr/0018 §6): no long-lived AWS key ever sits in
# GitHub, and what does sit there dies when the session does. GitHub Free has no
# Environments for private repos, so these are REPOSITORY secrets, and the DEV_ prefix is
# where the environment dimension lives instead.
#
# Refuses (exit 2) a session with under 30 minutes left: dev-push.yml refuses the same
# threshold, and pushing a session CI will reject only moves the failure somewhere slower.
# Prints repo names and the expiry — never a value. Values go to `gh` on stdin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY=0
case "${1:-}" in --dry-run) DRY=1 ;; "") ;; *) echo "usage: push-gh-creds.sh [--dry-run]" >&2; exit 2 ;; esac

# Every repo whose PRs can trigger /dev-push: the control repo, and each product repo's
# thin caller of the reusable workflow. check-docs.py [workflow-secrets] holds the names
# below to what the workflows read.
OWNER="$("$ROOT"/scripts/repos.py owner)"
REPOS="agent-app-project $("$ROOT"/scripts/repos.py names)"

python3 - "$ROOT/stack/secrets.env" "$OWNER" "$REPOS" "$DRY" <<'PY'
import datetime, re, subprocess, sys
path, owner, repos, dry = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4] == "1"

vals = {}
try:
    for line in open(path):
        m = re.match(r"^(?:export\s+)?(AWS_[A-Z_]+)=(.*)$", line.rstrip("\n"))
        if m:
            vals.setdefault(m.group(1), m.group(2))
except OSError:
    sys.exit(print("push-gh-creds: stack/secrets.env is missing — run `make login`.",
                   file=sys.stderr) or 2)

need = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_CREDENTIAL_EXPIRATION")
missing = [k for k in need if not vals.get(k)]
if missing:
    print(f"push-gh-creds: stack/secrets.env has no {', '.join(missing)} — run `make login`. "
          f"A session without an expiry cannot be gated, so it is not pushed.", file=sys.stderr)
    sys.exit(2)

exp = datetime.datetime.fromisoformat(vals["AWS_CREDENTIAL_EXPIRATION"].replace("Z", "+00:00"))
left = (exp - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 60
if left < 30:
    print(f"push-gh-creds: the session expires in {int(left)} min — run `make login` first.",
          file=sys.stderr)
    sys.exit(2)

secrets = {"DEV_AWS_ACCESS_KEY_ID": vals["AWS_ACCESS_KEY_ID"],
           "DEV_AWS_SECRET_ACCESS_KEY": vals["AWS_SECRET_ACCESS_KEY"],
           "DEV_AWS_SESSION_TOKEN": vals["AWS_SESSION_TOKEN"],
           "DEV_AWS_CREDENTIALS_EXPIRE_AT": exp.isoformat()}
variables = {"DEV_AWS_REGION": vals.get("AWS_REGION") or "eu-west-1"}

for repo in repos:
    full = f"{owner}/{repo}"
    if dry:
        print(f"push-gh-creds: [dry-run] {full}: secrets {', '.join(secrets)}; "
              f"variables {', '.join(variables)}")
        continue
    for name, value in secrets.items():
        subprocess.run(["gh", "secret", "set", name, "-R", full], input=value, text=True,
                       check=True, capture_output=True)
    for name, value in variables.items():
        subprocess.run(["gh", "variable", "set", name, "-R", full, "--body", value],
                       check=True, capture_output=True)
    print(f"push-gh-creds: {full} — session pushed")
print(f"push-gh-creds: expires {exp.isoformat()} ({int(left)} min from now)")
PY

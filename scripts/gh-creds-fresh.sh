#!/usr/bin/env bash
# Before a lane comments /dev-push or /dev-eval: is the session CI will read still alive?
#
#   ./scripts/gh-creds-fresh.sh [--record <iso expiry>]
#
# GitHub secrets are write-only, so push-gh-creds.sh records the expiry it pushed with
# --record, in this clone's git dir (never committable). Without it, a stale session is
# learned from a refused CI run and a PR comment (0009 ship-iterate R1, 0009 realign F1).
#
# Exit 0 fresh, or nothing recorded (pushed before this existed — warns) · 2 under the
# 30 minutes ci-session.sh requires. docs/adr/0003.
set -euo pipefail

F="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --path-format=absolute --git-common-dir)/gh-creds-expire-at"
if [ "${1:-}" = "--record" ]; then printf '%s\n' "$2" > "$F"; exit 0; fi
[ -s "$F" ] || { echo "gh-creds: no pushed-session expiry recorded here — CI will say if it is stale" >&2; exit 0; }

python3 - "$(cat "$F")" <<'PY'
import datetime, sys
exp = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
left = int((exp - datetime.datetime.now(datetime.timezone.utc)).total_seconds() // 60)
if left < 30:
    sys.exit(print(f"gh-creds: the session pushed to GitHub expires in {left} min — "
                   "`make login && make push-gh-creds` first; CI would refuse it.",
                   file=sys.stderr) or 2)
PY

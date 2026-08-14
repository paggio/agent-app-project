#!/usr/bin/env bash
# PreToolUse hook on Bash — closes the gap the Edit deny rules cannot.
#
# `Edit(./chatbot-backend/**)` stops the editing tools. It does not stop a shell command that
# writes into a submodule: `sed -i`, `tee`, `>` redirects, `cp`, `mv`, `rm`.
#
# exit 0 = allow, exit 2 = block and tell the agent why.
#
# Deliberately a heuristic: it is a guardrail against absent-mindedness, not a
# security boundary. Widen the patterns when a real miss shows up.
set -uo pipefail

PAYLOAD="$(cat)"   # JSON on stdin; grepped raw to stay dependency-free

SUBREPOS='(chatbot-backend|frontend|infra)'

# a path inside a submodule: chatbot-backend/... or ./chatbot-backend/... ,
# not "-C chatbot-backend"
SUBPATH="(^|[^[:alnum:]_./-])(\./)?$SUBREPOS/"

# a redirect landing inside a submodule
REDIRECT=">>?[[:space:]]*(\./)?$SUBREPOS/"

# commands that write, as whole tokens
WRITERS='(^|[^[:alnum:]_./-])(sed[[:space:]]+-i|tee|cp|mv|rm|mkdir|rmdir|touch|chmod|chown|truncate|dd|ln|install|patch|git[[:space:]]+apply)([[:space:]]|$)'

if grep -Eq "$REDIRECT" <<< "$PAYLOAD" \
  || { grep -Eq "$WRITERS" <<< "$PAYLOAD" && grep -Eq "$SUBPATH" <<< "$PAYLOAD"; }; then
  cat >&2 <<'MSG'
Blocked: this command appears to write inside a submodule (chatbot-backend/, frontend/, infra/).

Implementation never happens from the control session. Either:
  - start a session inside that repo, so it picks up its own CLAUDE.md, settings,
    skills and hooks; or
  - write the slice under changes/<change>/<repo>.md and run ./scripts/fanout.sh.

Read-only inspection (git -C, cat, grep, ls) is fine.
MSG
  exit 2
fi

exit 0

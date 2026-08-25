#!/usr/bin/env bash
# PreToolUse hook on Bash — closes the gap the Edit/Write deny rules cannot.
#
# `Edit(./chatbot-backend/**)` stops the editing tools. It does not stop a shell command
# that writes into a submodule: `sed -i`, `tee`, a `>` redirect, `cp`, `mv`, `rm`.
#
# exit 0 = allow, exit 2 = block and tell the agent why.
#
# Adjacency, not co-occurrence. The first version asked whether a writer token appeared
# ANYWHERE in the payload and a submodule path appeared ANYWHERE in the payload, so it
# blocked `echo "never write into chatbot-backend/"`, and it blocked this file's own
# documentation. A guard that fires on the control repo's ordinary work teaches the agent
# that the guard is noise. Now a writer has to be writing INTO a submodule: the check runs
# per shell segment, so the target must sit in the same command as the verb.
#
# Still a heuristic, and still a guardrail against absent-mindedness rather than a security
# boundary. Widen it when a real miss shows up, never to catch a hypothetical one.
set -uo pipefail

PAYLOAD="$(cat)"   # JSON on stdin

VERDICT="$(HOOK_PAYLOAD="$PAYLOAD" python3 - <<'PY'
import json, os, re

raw = os.environ.get("HOOK_PAYLOAD", "")
try:
    cmd = (json.loads(raw).get("tool_input") or {}).get("command") or ""
except Exception:
    cmd = raw   # unparseable payload: scan it whole rather than waving it through

SUB = r"(chatbot-backend|frontend|infra)"
# A path inside a submodule — `chatbot-backend/x`, `./frontend/x`, `"infra/x` — but not
# `-C chatbot-backend`, which is how a legitimate read or branch switch is spelled.
SUBPATH = re.compile(rf"(^|[^\w./-]){SUB}/")
WRITERS = re.compile(
    r"(^|[^\w./-])"
    r"(sed\s+-i|tee|cp|mv|rm|mkdir|rmdir|touch|chmod|chown|truncate|dd|ln|install"
    r"|patch|rsync|git\s+apply|git\s+checkout\s+--)"
    r"(\s|$)"
)
# `> chatbot-backend/x` — a redirect names its own target, so this needs no segmenting.
REDIRECT = re.compile(rf">>?\s*['\"]?(\./)?{SUB}/")

verdict = "allow"
if REDIRECT.search(cmd):
    verdict = "redirect"
else:
    # One shell command per segment. A heredoc body mentioning a submodule therefore cannot
    # implicate the `cat >` that opened it, and a writer in one command cannot be
    # implicated by a path named in the next.
    for segment in re.split(r"[;\n]|&&|\|\||\|", cmd):
        if WRITERS.search(segment) and SUBPATH.search(segment):
            verdict = "writer"
            break
print(verdict)
PY
)"

if [ "$VERDICT" != "allow" ]; then
  cat >&2 <<'MSG'
Blocked: this command writes inside a submodule (chatbot-backend/, frontend/, infra/).

Implementation never happens from the control session. Either:
  - start a session inside that repo, so it picks up its own CLAUDE.md, settings,
    skills and hooks; or
  - write the slice under changes/<change>/<repo>.md and let /ship dispatch it.

Read-only inspection (git -C, cat, grep, ls) is fine, and so is `git -C <repo> switch`.
MSG
  exit 2
fi

exit 0

#!/usr/bin/env bash
# Dispatch a planned change to every product repo that has a slice file.
#
# Each invocation starts with its working directory INSIDE the real product repo, so
# it picks up that repo's CLAUDE.md chain, .claude/settings.json, skills, hooks and
# git remote. That is why this is separate processes rather than subagents spawned
# from the control session.
set -euo pipefail

REPOS=(chatbot-backend frontend infra)

CHANGE="${1:?usage: fanout.sh <change-dir-name>}"
CONTROL="$(pwd)"
[ -d "changes/$CHANGE" ] || { echo "no such change: $CHANGE" >&2; exit 1; }

grep -q '[0-9a-f]\{7,\}' "changes/$CHANGE/BRIEF.md" || {
  echo "warning: no freeze SHA found in changes/$CHANGE/BRIEF.md — freeze the contract first" >&2
}

for r in "${REPOS[@]}"; do
  [ -f "changes/$CHANGE/$r.md" ] || continue

  git -C "$r" switch -c "feat/$CHANGE" 2>/dev/null || git -C "$r" switch "feat/$CHANGE"

  (
    cd "$r"
    claude -p "Implement your slice of this change: $CONTROL/changes/$CHANGE/$r.md
Read $CONTROL/changes/$CHANGE/BRIEF.md for full context and acceptance criteria.
The contracts under $CONTROL/contracts/ are FROZEN. If your slice appears to require
a contract change, STOP and report it rather than working around it.
Finish with your repo's gates passing, then open a pull request.
Return exactly OK or FAIL:<one-line reason>." \
      --permission-mode auto \
      --add-dir "$CONTROL/changes/$CHANGE" \
      --add-dir "$CONTROL/contracts"
    # --add-dir rather than the additionalDirectories setting: the setting grants file
    # access only, while the flag also loads skills from the added directory.
  ) &
done

wait
echo "fanout complete — review the PRs before merging anything"

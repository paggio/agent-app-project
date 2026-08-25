#!/usr/bin/env bash
# The pull requests for a change: list them, or open the ones that are missing.
#
#   ./scripts/prs.sh --list
#   ./scripts/prs.sh --create <change> [--run-dir DIR] [--dry-run]
#
# Why this exists: "then open a pull request" was a sentence in the prompt sent to each
# dispatched agent, and the URL it printed back was recorded verbatim and never fetched.
# So the one artifact a human acts on was the only part of the loop with no evidence behind
# it. This pushes and opens what is missing, and writes prs.json — a fact rather than a
# claim. It never merges.
#
# Idempotent on purpose: a slice that opened its own PR keeps it, and re-running produces
# the same URLs rather than duplicates.
#
# Exit 0 = every slice has a pull request. Exit 1 = at least one could not be opened.
# Exit 2 = refused (bad arguments, unparseable manifest, no gh). See docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPOS="chatbot-backend frontend infra"
MODE=""; CHANGE=""; RUN_DIR=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list ;;
    --create) MODE=create ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "prs: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "usage: prs.sh --list | --create <change>" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "prs: gh is not installed" >&2; exit 2; }

if [ "$MODE" = "list" ]; then
  for r in $REPOS; do
    echo "── $r"
    (cd "$r" && gh pr list --limit 10 2>/dev/null) || echo "  (no remote access)"
  done
  exit 0
fi

[ -n "$CHANGE" ] || { echo "usage: prs.sh --create <change>" >&2; exit 2; }
CHANGE_DIR="changes/$CHANGE"
[ -d "$CHANGE_DIR" ] || { echo "prs: no such change: $CHANGE_DIR" >&2; exit 2; }

eval "$(./scripts/manifest.py "$CHANGE_DIR" --shell)"
[ "${MANIFEST_OK:-0}" = "1" ] || { echo "prs: change.yaml has problems (above)" >&2; exit 2; }

BRANCH="feat/$CHANGE"
# The brief's first heading is the PR title, so the title and the acceptance criteria
# cannot disagree about what this change is.
TITLE="$(sed -n 's/^# *//p' "$CHANGE_DIR/BRIEF.md" | head -1)"
[ -n "$TITLE" ] || TITLE="$CHANGE"

: "${RUN_DIR:=$CHANGE_DIR/runs/manual}"
mkdir -p "$RUN_DIR"
OUT="$RUN_DIR/prs.json"
: > "$RUN_DIR/.prs.tsv"

RC=0
for r in $CHANGE_SLICES; do
  head_branch="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [ "$head_branch" != "$BRANCH" ]; then
    echo "prs: $r is on $head_branch, not $BRANCH — refusing to open a PR for it" >&2
    printf '%s\t%s\t%s\n' "$r" "wrong-branch:$head_branch" "" >> "$RUN_DIR/.prs.tsv"
    RC=1
    continue
  fi

  existing="$(cd "$r" && gh pr list --head "$BRANCH" --state open \
                --json url --jq '.[0].url' 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "prs: $r already has $existing"
    printf '%s\t%s\t%s\n' "$r" "existing" "$existing" >> "$RUN_DIR/.prs.tsv"
    continue
  fi

  if [ "$DRY" = "1" ]; then
    echo "prs: [dry-run] $r -> would push $BRANCH and open a PR titled: $TITLE"
    printf '%s\t%s\t%s\n' "$r" "dry-run" "" >> "$RUN_DIR/.prs.tsv"
    continue
  fi

  # A commitless branch means the slice changed nothing. Saying so is more useful than an
  # empty PR, and it is the shape of failure a repair pass can act on.
  if [ -z "$(git -C "$r" log --oneline "origin/main..$BRANCH" 2>/dev/null)" ]; then
    echo "prs: $r has no commits on $BRANCH — nothing to open a PR for" >&2
    printf '%s\t%s\t%s\n' "$r" "no-commits" "" >> "$RUN_DIR/.prs.tsv"
    RC=1
    continue
  fi

  if ! git -C "$r" push -u origin "$BRANCH" >/dev/null 2>&1; then
    echo "prs: $r could not push $BRANCH" >&2
    printf '%s\t%s\t%s\n' "$r" "push-failed" "" >> "$RUN_DIR/.prs.tsv"
    RC=1
    continue
  fi

  body="Slice of \`$CHANGE\` — see the control repo's \`$CHANGE_DIR/\` for the brief, the
acceptance criteria as smoke steps, and this slice's instructions in \`$r.md\`.

Verified as part of the joined stack: the repos are brought up together behind one origin
and \`$CHANGE_DIR/$CHANGE_SMOKE_FILE\` is asserted through it. Merging this alone does not
make the change shipped — see the control repo's \`docs/adr/0002\`.

Opened by \`scripts/prs.sh\`."

  url="$(cd "$r" && gh pr create --base main --head "$BRANCH" \
           --title "$TITLE" --body "$body" 2>&1 | tail -1)"
  case "$url" in
    https://*)
      echo "prs: $r -> $url"
      printf '%s\t%s\t%s\n' "$r" "created" "$url" >> "$RUN_DIR/.prs.tsv" ;;
    *)
      echo "prs: $r could not open a PR: $url" >&2
      printf '%s\t%s\t%s\n' "$r" "create-failed" "" >> "$RUN_DIR/.prs.tsv"
      RC=1 ;;
  esac
done

python3 - "$RUN_DIR/.prs.tsv" "$OUT" "$CHANGE" "$BRANCH" <<'PY'
import json, sys
tsv, out, change, branch = sys.argv[1:5]
repos = {}
for line in open(tsv):
    if not line.strip():
        continue
    repo, state, url = (line.rstrip("\n").split("\t") + ["", "", ""])[:3]
    repos[repo] = {"state": state, "url": url or None}
json.dump({
    "change": change,
    "branch": branch,
    "ok": all(r["state"] in ("created", "existing") for r in repos.values()) and bool(repos),
    "repos": repos,
}, open(out, "w"), indent=2)
PY
rm -f "$RUN_DIR/.prs.tsv"

echo "prs: results -> $OUT"
exit $RC

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
  # The control repo is listed alongside the products because a change has a half here too
  # — the freeze, the plan, the smoke criteria — and omitting it is how change 0002's half
  # sat merged into a dead-end branch for four days while this command reported nothing to
  # do. BASE is printed for the same reason: the failure was not a missing merge but a
  # merge into the wrong base, which is invisible in a list of titles.
  for r in . $REPOS; do
    [ "$r" = "." ] && echo "── agent-app-project (this repo)" || echo "── $r"
    out="$(cd "$r" && gh pr list --limit 10 \
             --json number,title,headRefName,baseRefName \
             --template '{{range .}}  #{{.number}}  {{.headRefName}} -> {{.baseRefName}}{{if ne .baseRefName "main"}}  <- NOT main{{end}}  {{.title}}{{"\n"}}{{end}}' \
           2>/dev/null)" || { echo "  (no remote access)"; continue; }
    [ -n "$out" ] && printf '%s\n' "$out" || echo "  (none open)"
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

# The control repo is a target like any slice, for the reason --list already gives above:
# a change has a half HERE — the freeze, the brief, the criteria — and leaving it out is
# how 0002's half sat merged into a dead-end branch for four days. It is added only when
# this repo is already on feat/<change>, because nothing in the harness creates that branch;
# when it is not, the loop behaves exactly as it did before and reports on the slices alone.
TARGETS="$CHANGE_SLICES"
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" = "$BRANCH" ]; then
  TARGETS=". $TARGETS"
fi

RC=0
for r in $TARGETS; do
  [ "$r" = "." ] && label="agent-app-project (this repo)" || label="$r"
  head_branch="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [ "$head_branch" != "$BRANCH" ]; then
    echo "prs: $label is on $head_branch, not $BRANCH — refusing to open a PR for it" >&2
    printf '%s\t%s\t%s\n' "$r" "wrong-branch:$head_branch" "" >> "$RUN_DIR/.prs.tsv"
    RC=1
    continue
  fi

  existing="$(cd "$r" && gh pr list --head "$BRANCH" --state open \
                --json url --jq '.[0].url' 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "prs: $label already has $existing"
    printf '%s\t%s\t%s\n' "$r" "existing" "$existing" >> "$RUN_DIR/.prs.tsv"
    continue
  fi

  if [ "$DRY" = "1" ]; then
    echo "prs: [dry-run] $label -> would push $BRANCH and open a PR titled: $TITLE"
    printf '%s\t%s\t%s\n' "$r" "dry-run" "" >> "$RUN_DIR/.prs.tsv"
    continue
  fi

  # A commitless branch means the slice changed nothing. Saying so is more useful than an
  # empty PR, and it is the shape of failure a repair pass can act on.
  if [ -z "$(git -C "$r" log --oneline "origin/main..$BRANCH" 2>/dev/null)" ]; then
    echo "prs: $label has no commits on $BRANCH — nothing to open a PR for" >&2
    printf '%s\t%s\t%s\n' "$r" "no-commits" "" >> "$RUN_DIR/.prs.tsv"
    RC=1
    continue
  fi

  if ! git -C "$r" push -u origin "$BRANCH" >/dev/null 2>&1; then
    echo "prs: $label could not push $BRANCH" >&2
    printf '%s\t%s\t%s\n' "$r" "push-failed" "" >> "$RUN_DIR/.prs.tsv"
    RC=1
    continue
  fi

  if [ "$r" = "." ]; then
    body="The control-repo half of \`$CHANGE\` — the contract freeze, the brief, the
acceptance criteria as \`$CHANGE_DIR/$CHANGE_SMOKE_FILE\`, and the stack that joins the repos.

Merge order is in \`$CHANGE_DIR/STATUS.md\`: this PR carries the suite that asserts the
slices, so merging it first leaves \`main\` asserting a backend that has not landed.

Opened by \`scripts/prs.sh\`."
  else
    body="Slice of \`$CHANGE\` — see the control repo's \`$CHANGE_DIR/\` for the brief, the
acceptance criteria as smoke steps, and this slice's instructions in \`$r.md\`.

Verified as part of the joined stack: the repos are brought up together behind one origin
and \`$CHANGE_DIR/$CHANGE_SMOKE_FILE\` is asserted through it. Merging this alone does not
make the change shipped — see the control repo's \`docs/adr/0002\`.

Opened by \`scripts/prs.sh\`."
  fi

  url="$(cd "$r" && gh pr create --base main --head "$BRANCH" \
           --title "$TITLE" --body "$body" 2>&1 | tail -1)"
  case "$url" in
    https://*)
      echo "prs: $label -> $url"
      printf '%s\t%s\t%s\n' "$r" "created" "$url" >> "$RUN_DIR/.prs.tsv" ;;
    *)
      echo "prs: $label could not open a PR: $url" >&2
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
    # "." is the control repo; name it, so a reader of prs.json sees a repo list.
    repos["agent-app-project" if repo == "." else repo] = {"state": state, "url": url or None}
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

#!/usr/bin/env bash
# Create, scaffold and attach a product repo that a change records in `new_repos:`.
#
#   ./scripts/new-repo.sh <change> <name> [--remote <url>] [--dry-run]
#
#     --remote <url>  attach this existing remote instead of creating <owner>/<name> on
#                     GitHub, and skip the GitHub wiring — how the script is probed with a
#                     local bare repo
#     --dry-run       say what would happen; touch nothing
#
# /ship phase 1 runs it, and only for a repo the change records — a repo is created when
# the request asks for one, never as a side effect of planning. docs/adr/0020.
#
#   1. <owner>/<name>, private, unless it exists
#   2. templates/product-repo/ rendered and pushed as its `main`, unless main exists
#   3. `git submodule add`, its images in .gitmodules, the Edit deny rule, the README row,
#      repos.lock — and one commit on feat/<change>: `attach <name>`
#   4. make gh-setup again: every holder needs the new repo's deploy key, and the new
#      repo needs everyone's
#
# Idempotent: a re-run skips what exists. Exit 0 done · 2 refused.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHANGE=""; NAME=""; REMOTE=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "new-repo: unknown option $1" >&2; exit 2 ;;
    *) if [ -z "$CHANGE" ]; then CHANGE="$1"; else NAME="$1"; fi ;;
  esac
  shift
done

say() { echo "new-repo: $*"; }
refuse() { say "$*" >&2; exit 2; }
run() { if [ "$DRY" = "1" ]; then say "[dry-run] $*"; else "$@"; fi; }

[ -n "$CHANGE" ] && [ -n "$NAME" ] || refuse "usage: new-repo.sh <change> <name> [--remote <url>] [--dry-run]"
DIR="changes/$CHANGE"
[ -d "$DIR" ] || refuse "no such change: $DIR"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "feat/$CHANGE" ] || refuse "on $BRANCH — the attach commit belongs on feat/$CHANGE"

ENTRY="$(./scripts/manifest.py "$DIR" --new-repo "$NAME")" || exit 2
PURPOSE="${ENTRY%%$'\t'*}"; IMAGES="${ENTRY#*$'\t'}"

case " $(./scripts/repos.py names) " in
  *" $NAME "*) say "$NAME is already a submodule — nothing to attach"; exit 0 ;;
esac
[ ! -e "$NAME" ] || refuse "$NAME/ exists and is not a submodule — move it aside first"

OWNER="$(./scripts/repos.py owner)"
URL="${REMOTE:-https://github.com/$OWNER/$NAME.git}"

# --- 1. the remote -------------------------------------------------------------------
if [ -z "$REMOTE" ]; then
  if gh repo view "$OWNER/$NAME" >/dev/null 2>&1; then
    say "$OWNER/$NAME exists"
  else
    run gh repo create "$OWNER/$NAME" --private --description "$PURPOSE"
    say "created $OWNER/$NAME (private)"
  fi
fi

# --- 2. the scaffold, as its main ----------------------------------------------------
# Rendered outside this tree: the write guard and the deny rules key on submodule paths,
# and a half-written repo at its final path is unattachable anyway.
if [ -n "$(git ls-remote --heads "$URL" main 2>/dev/null)" ]; then
  say "$URL already has main — not scaffolding"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cp -R templates/product-repo/. "$TMP/"
  python3 - "$TMP" "$NAME" "$PURPOSE" "$OWNER" <<'PY'
import os, sys
root, name, purpose, owner = sys.argv[1:]
for d, _, files in os.walk(root):
    for f in files:
        p = os.path.join(d, f)
        s = open(p).read()
        t = s.replace("__NAME__", name).replace("__PURPOSE__", purpose).replace("__OWNER__", owner)
        if t != s:
            open(p, "w").write(t)
PY
  if [ "$DRY" = "1" ]; then
    say "[dry-run] would push this scaffold to $URL main:"
    (cd "$TMP" && find . -type f | sort | sed 's/^/  /')
  else
    git -C "$TMP" init -q -b main
    git -C "$TMP" add -A
    git -C "$TMP" commit -q -m "chore: scaffold $NAME from agent-app-project/templates/product-repo"
    git -C "$TMP" push -q "$URL" main
    say "pushed the scaffold to $URL main"
  fi
fi

# --- 3. attach, register, commit ------------------------------------------------------
run git submodule add -q "$URL" "$NAME"
[ -z "$IMAGES" ] || run git config -f .gitmodules "submodule.$NAME.images" "$IMAGES"
if [ "$DRY" = "1" ]; then
  say "[dry-run] add Edit(./$NAME/**) to .claude/settings.json, a README row, lock, commit"
  exit 0
fi
python3 - "$NAME" "$PURPOSE" "https://github.com/$OWNER/$NAME" <<'PY'
import json, re, sys
name, purpose, url = sys.argv[1:]
p = ".claude/settings.json"
d = json.load(open(p))
deny = d.setdefault("permissions", {}).setdefault("deny", [])
rule = f"Edit(./{name}/**)"
if rule not in deny:
    deny.append(rule)
    open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
p = "README.md"
s = open(p).read()
rows = list(re.finditer(r"^\| \[`[\w.-]+`\]\(.*\n", s, re.M))
if rows and f"[`{name}`]" not in s:
    end = rows[-1].end()
    s = s[:end] + f"| [`{name}`]({url}) | {purpose} |\n" + s[end:]
    open(p, "w").write(s)
PY
./scripts/lock.sh >/dev/null
git add .gitmodules "$NAME" .claude/settings.json README.md repos.lock
git commit -q -m "attach $NAME: $PURPOSE"
say "attached $NAME at $(git rev-parse --short HEAD) on $BRANCH"

# --- 4. GitHub wiring -----------------------------------------------------------------
if [ -z "$REMOTE" ]; then
  ROLE="$(gh variable get DEV_AWS_DEPLOYER_ROLE_ARN -R "$OWNER/agent-app-project" 2>/dev/null || true)"
  ./scripts/gh-setup.sh ${ROLE:+--role-arn "$ROLE"}
  say "run \`make push-gh-creds\` before the next deploy, so $NAME holds the session too"
fi

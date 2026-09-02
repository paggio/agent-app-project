#!/usr/bin/env bash
# Everything the harness-retro agent must not have to take on trust, collected in one pass.
#
#   ./scripts/retro-evidence.sh --lane <lane> [--change NNNN-slug] [--run-dir DIR]
#     --lane  ship | ship-correct | ship-iterate | realign
#
# Why this exists: the retrospective's first job is to say whether the system is coherent
# right now — locally and in whatever environment the lane claimed to touch. An agent asked
# that question with no fixed evidence answers it from the session it just read, which is
# the one source guaranteed to share the session's blind spots. So the state is gathered
# mechanically, in the same order every time, and the agent's judgement starts after the
# facts rather than instead of them.
#
# Read-only by construction: it reads git, reads the run artifacts, and re-runs the three
# gates that need neither Docker nor the network. It never writes, never fetches, never
# brings the stack up or down.
#
# An artifact it cannot parse is reported as unreadable, in the bundle, where the agent
# reads it. Never as an empty section: a half-written verify.json belongs to exactly the
# run whose evidence matters most, and a silence there reads as a clean bill.
#
# Exit 0 = a bundle was produced. Exit 2 = refused (bad arguments, not a checkout).
# A gate failing is CONTENT, not an exit code — the bundle reports it and the agent judges
# it. See docs/adr/0003.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

LANE=""; CHANGE=""; RUN_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lane)    LANE="${2:-}"; shift ;;
    --change)  CHANGE="${2:-}"; shift ;;
    --run-dir) RUN_DIR="${2:-}"; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "retro-evidence: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

# Every lane's name is accepted, because the name is what the retro's frontmatter records
# and a lane whose own name the bundle refuses is an exit 2 for a correct invocation. The
# three dispatching lanes produce a run directory; /realign does not.
case "$LANE" in
  ship|ship-correct|ship-iterate|realign) ;;
  *) echo "retro-evidence: --lane must be one of: ship, ship-correct, ship-iterate," >&2
     echo "retro-evidence: realign — the lane names retros/README.md's frontmatter uses" >&2
     exit 2 ;;
esac

CHANGE="${CHANGE#changes/}"; CHANGE="${CHANGE%/}"
if [ -n "$CHANGE" ] && [ ! -d "changes/$CHANGE" ]; then
  echo "retro-evidence: changes/$CHANGE does not exist" >&2; exit 2
fi
RUN_DIR="${RUN_DIR%/}"
if [ -n "$RUN_DIR" ] && [ ! -d "$RUN_DIR" ]; then
  echo "retro-evidence: $RUN_DIR does not exist" >&2; exit 2
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPOS="chatbot-backend frontend infra"

say() { printf '%s\n' "$*"; }

# Bounded on purpose: this bundle is read whole by one agent, and an unbounded log tail
# would push the parts it has to reason about out of reach. It says when it clipped —
# a brief that stops mid-token reads as malformed evidence rather than as a long one.
cap() {
  local n="${1:-4000}" data
  data="$(cat)"
  printf '%s\n' "${data:0:$n}"
  [ "${#data}" -gt "$n" ] && printf '… (truncated at %s of %s bytes)\n' "$n" "${#data}"
  return 0
}

# Every JSON read goes through this. python3 writes a traceback to stderr, and stderr is
# not part of the bundle, so a corrupt artifact would otherwise render as an empty fenced
# block — the one shape the agent is told to treat as a pass it cannot infer.
run_py() {
  local file="$1" out
  if out="$(python3 - "$file" 2>&1)"; then
    printf '%s\n' "$out"
  else
    say "  (UNREADABLE — $file did not parse. Anything derived from it is NOT VERIFIED.)"
    printf '%s\n' "$out" | tail -1 | sed 's/^/  reason: /'
  fi
}

say "# retro evidence — $LANE${CHANGE:+ / $CHANGE} @ $TS"
say ""
say "Collected by scripts/retro-evidence.sh. Every line below is observed, not claimed."

# ── 1. this repo ─────────────────────────────────────────────────────────────────────
say ""
say "## 1. Control repo, right now"
say ""
say '```'
say "branch:   $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
say "head:     $(git log -1 --format='%h %s' 2>/dev/null)"
say "upstream: $(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo 'none')"
say ""
say "working tree (submodule pointers included):"
git status --porcelain | sed 's/^/  /' | head -40
[ -z "$(git status --porcelain)" ] && say "  clean"
say ""
say "contracts/ against HEAD: $(git status --porcelain -- contracts/ | grep -c . ) changed file(s)"
say "last commit touching contracts/: $(git log -1 --format='%h %ad %s' --date=short -- contracts/ 2>/dev/null)"
say '```'

# ── 2. the submodules ────────────────────────────────────────────────────────────────
say ""
say "## 2. Submodules, against repos.lock"
say ""
say '```'
printf '  %-16s %-24s %-9s %-14s %s\n' REPO BRANCH SHA "vs repos.lock" "uncommitted"
for r in $REPOS; do
  br="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  sha="$(git -C "$r" rev-parse --short HEAD 2>/dev/null || echo '-')"
  pinned="$(awk -v r="$r" '$1==r{print substr($2,1,7)}' repos.lock 2>/dev/null)"
  if [ "$sha" = "$pinned" ]; then state="matches"
  elif [ -z "$pinned" ]; then state="not pinned"
  else state="differs ($pinned)"; fi
  dirty="$(git -C "$r" status --porcelain 2>/dev/null | grep -c .)"
  printf '  %-16s %-24s %-9s %-14s %s\n' "$r" "$br" "$sha" "$state" "$dirty file(s)"
done
say ""
say "A detached HEAD or a feature branch here is not automatically wrong — /ship leaves"
say "branches behind and /realign leaves main. Judge it against the lane that just ran."
say '```'

# ── 3. the run ───────────────────────────────────────────────────────────────────────
say ""
say "## 3. The run"
if [ -z "$RUN_DIR" ] && [ -n "$CHANGE" ]; then
  RUN_DIR="$(ls -d "changes/$CHANGE/runs/"*/ 2>/dev/null | sort | tail -1)"
  RUN_DIR="${RUN_DIR%/}"
fi

if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  say ""
  say "No run directory. For /realign that is expected — the evidence is sections 2, 4 and 5."
  say "For /ship, /ship-correct and /ship-iterate it is a finding: each ends in the loop and"
  say "the loop produces one, so its absence means the loop did not finish, or the change was"
  say "shipped by hand."
else
  say ""
  say "\`$RUN_DIR\`"
  say ""
  say "### report.md"
  say '```'
  if [ -f "$RUN_DIR/report.md" ]; then sed -n '1,40p' "$RUN_DIR/report.md"; else say "(missing — the loop did not reach the reporting step)"; fi
  say '```'

  say ""
  say "### attempts"
  say '```'
  for a in "$RUN_DIR"/attempt-*; do
    [ -d "$a" ] || continue
    say "$(basename "$a"): $(ls "$a" 2>/dev/null | tr '\n' ' ')"
  done
  say '```'

  say ""
  say "### verify.json (last attempt)"
  say '```'
  last_verify="$(ls "$RUN_DIR"/attempt-*/verify.json 2>/dev/null | sort | tail -1)"
  if [ -s "${last_verify:-}" ]; then
    run_py "$last_verify" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("steps", None)
print(json.dumps(d, indent=1))
PY
  else
    say "(no verify.json — nothing was asserted, whatever the report says)"
  fi
  say '```'

  say ""
  say "### assertions, by name and result (last attempt)"
  say '```'
  last_smoke="$(ls "$RUN_DIR"/attempt-*/smoke.json 2>/dev/null | sort | tail -1)"
  if [ -s "${last_smoke:-}" ]; then
    run_py "$last_smoke" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
steps = d.get("steps") or d.get("results") or []
if not steps:
    print(json.dumps(d, indent=1)[:2000]); raise SystemExit
for s in steps:
    name = s.get("name", "?")
    ok = s.get("ok", s.get("status", "?"))
    suite = s.get("suite", "")
    print(f"  {str(ok):6} {name}  {('['+suite+']') if suite else ''}")
print(f"\n  {len(steps)} step(s)")
PY
  else
    say "(no smoke.json)"
  fi
  say '```'

  say ""
  say "### failure briefs — exactly what the repair agents were given"
  say '```'
  briefs="$(ls "$RUN_DIR"/attempt-*/failure-*.md 2>/dev/null)"
  if [ -n "$briefs" ]; then
    for f in $briefs; do say "── $f"; cap 1500 < "$f"; say ""; done
  else
    say "(none — either nothing failed, or nothing was routed)"
  fi
  say '```'

  say ""
  say "### the contract against what was served, as this run recorded it"
  say '```'
  last_harvest="$(ls "$RUN_DIR"/attempt-*/harvest.log 2>/dev/null | sort | tail -1)"
  if [ -s "${last_harvest:-}" ]; then
    say "── $last_harvest (tail)"
    tail -40 "$last_harvest"
  else
    say "(no harvest.log — nothing compared the served surface to contracts/ in this run)"
  fi
  say '```'

  say ""
  say "### what each dispatched slice claimed, and what prs.json records"
  say '```'
  for f in "$RUN_DIR"/attempt-*/fanout.json; do
    [ -f "$f" ] || continue
    say "── $f"
    run_py "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  attempt={d.get('attempt')} ok={d.get('ok')} failed={d.get('failed')} "
      f"contract_gaps={d.get('contract_gaps')}")
repos = d.get("repos") or {}
if not isinstance(repos, dict):
    print("  " + json.dumps(repos)[:500]); raise SystemExit
for name, s in repos.items():
    if not isinstance(s, dict):
        print(f"  {name}: {s}"); continue
    row = {"repo": name}
    row.update({k: s.get(k) for k in
                ("status", "exit", "branch", "pr", "reason", "contract_gap") if k in s})
    print("  " + json.dumps(row))
print("  ('pr' here is the slice's own CLAIM. prs.json below is what was checked.)")
PY
  done
  [ -f "$RUN_DIR/prs.json" ] && { say "── $RUN_DIR/prs.json"; cap 1200 < "$RUN_DIR/prs.json"; } || say "(no prs.json — no pull request is a checked fact)"
  say '```'
fi

# ── 4. deploy reality ────────────────────────────────────────────────────────────────
say ""
say "## 4. What was actually deployed, and where"
say ""
say '```'
if [ -n "$CHANGE" ] && [ -f "changes/$CHANGE/change.yaml" ]; then
  say "change.yaml deploy block:"
  awk '/^deploy:/{f=1} f && /^[a-z_]/ && !/^deploy:/{exit} f{print "  " $0}' "changes/$CHANGE/change.yaml"
fi
if [ -s "${last_verify:-}" ]; then
  run_py "$last_verify" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
infra = d.get("infra") or {}
print(f"  environment:     {infra.get('environment')}")
print(f"  remote_asserted: {infra.get('remote_asserted')}")
print(f"  stages:          {json.dumps(d.get('stages') or {})}")
if not infra.get("remote_asserted"):
    print("  → nothing was proved about a remote environment in this run.")
PY
else
  say "  no verify.json in scope — nothing here is evidence about a deployed environment."
fi
say ""
say "contract against what is served:"
if [ -s "${last_harvest:-}" ]; then
  say "  last recorded answer is $last_harvest — read it above, and note it is from that"
  say "  run, not from now."
else
  say "  NOT VERIFIED from here. harvest-contract.py --diff needs the stack up and this"
  say "  script never brings it up. If the lane did not run it, nobody checked."
fi
say ""
say "This section is the only claim about the cloud that is grounded. There is no live"
say "AWS read here on purpose: it would need credentials, and an unasserted environment"
say "is a finding whether or not something is running in it."
say '```'

# ── 5. gates, re-run now ─────────────────────────────────────────────────────────────
say ""
say "## 5. Gates, re-run against the tree as it stands"
say ""
say '```'
out="$(./scripts/check-docs.py 2>&1)"; rc=$?
say "check-docs.py → exit $rc"
printf '%s\n' "$out" | sed 's/^/  /' | head -30
if [ -n "$CHANGE" ]; then
  out="$(./scripts/manifest.py "changes/$CHANGE" --validate 2>&1)"; rc=$?
  say ""
  say "manifest.py changes/$CHANGE --validate → exit $rc"
  printf '%s\n' "$out" | sed 's/^/  /' | head -30
fi
out="$(./scripts/test-hooks.py 2>&1)"; rc=$?
say ""
say "test-hooks.py → exit $rc"
printf '%s\n' "$out" | sed 's/^/  /' | head -20
say '```'

# ── 6. the stack ─────────────────────────────────────────────────────────────────────
say ""
say "## 6. The joined stack, right now"
say ""
say '```'
out="$(./scripts/stack.sh ps 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then printf '%s\n' "$out" | head -20; else say "not reachable (exit $rc) — Docker is down, or nothing is up"; fi
say ""
say "Down is normal after a finished lane. Up with a change's stack still running is worth"
say "a line in the report, not a fix."
say '```'

# ── 7. what has been said before ─────────────────────────────────────────────────────
say ""
say "## 7. What the harness has already been told"
say ""
say '```'
say "previous retros — the LEDGER, not the retros. Frontmatter and finding headings only."
say "The bodies are history: a lane's worth of them is over a thousand lines and none of it"
say "is evidence about this run. Open one whole ONLY to cite a specific finding, which is"
say "what the second-occurrence rule needs — and then just that one."
say ""
# A retro lands by pull request, so a retro whose pull request was never opened exists only
# on a branch — and that is the one the next retrospective most needs, because the
# second-occurrence rule is written against it. Listing the working tree alone printed
# "(none)" while retros/20260826T163132Z-ship-0004-rag-knowledge-base.md sat on a pushed
# branch, and the friction it recorded was met again the next day.
RETRO_LIST="$( { ls -1 retros/*.md 2>/dev/null | grep -v '/README\.md$' | sed 's/$/\t/'
  git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null |
    while read -r ref; do
      git ls-tree -r --name-only "$ref" -- retros/ 2>/dev/null | grep -v 'README\.md$' |
        while read -r f; do
          [ -e "$f" ] || printf '%s\t%s\n' "$f" "$ref"
        done
    done | sort -u
} | awk -F'\t' '!seen[$1]++' )"
# The program comes from the heredoc, so the list arrives in the environment: a pipe into
# `python3 -` would be swallowed by the heredoc and the section would silently list nothing.
RETRO_LIST="$RETRO_LIST" LEDGER_MAX=8 python3 - <<'LEDGERPY'
"""One line of identity and one line per finding, per retro.

retros/ is the harness's memory and it grows by one 250-line file per lane. The agent that
reads it is told to apply the second-occurrence rule, and until this existed the bundle gave
it filenames — so complying meant opening every file, which is how a directory of history
became a per-run context cost that grows forever. The headings ARE the mechanism; the prose
under them is for the human reading the pull request.

An unparseable retro is reported as unparseable, in the bundle. A silence here reads as
"nothing was ever recorded", which is the one answer that switches the rule off.
"""
import os, re, subprocess

MAX = int(os.environ.get("LEDGER_MAX", "8"))
rows = []
for line in os.environ.get("RETRO_LIST", "").splitlines():
    path, _, ref = line.rstrip("\n").partition("\t")
    if path:
        rows.append((path, ref))
if not rows:
    print("  (none — nothing has been recorded, so the second-occurrence rule has nothing")
    print("  to stand on. On a repo with lanes behind it, suspect this section rather than")
    print("  trusting it.)")
    raise SystemExit

omitted = max(0, len(rows) - MAX)
if omitted:
    print(f"  {omitted} older retro(s) not listed; {len(rows)} exist. Newest {MAX} follow.")
    print("")

HEAD = re.compile(r"^#{2,3}\s+(.*)$")
KEEP = ("lane", "change", "date", "verdict", "findings", "pr")

for path, ref in rows[-MAX:]:
    where = f"  {path}" + (f"  — NOT in this tree, on {ref}" if ref else "")
    print(where)
    try:
        if ref:
            text = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True,
                                  text=True, check=True).stdout
        else:
            text = open(path, errors="replace").read()
    except Exception as exc:
        print(f"    (UNREADABLE: {exc!r} — treat this retro as NOT read)")
        continue

    fm = {}
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            for fl in text[3:end].splitlines():
                k, _, v = fl.partition(":")
                if k.strip() in KEEP:
                    fm[k.strip()] = v.strip()
    if fm:
        print("    " + "  ".join(f"{k}={fm[k]}" for k in KEEP if k in fm))
    else:
        print("    (no parseable frontmatter — retros/README.md specifies it)")

    section, n = "", 0
    for fl in text.splitlines():
        m = HEAD.match(fl)
        if not m:
            continue
        title = m.group(1).strip()
        if fl.startswith("## "):
            section = title
            continue
        if section.lower().startswith(("state audit", "not verified")):
            continue
        # Announced, like cap() does: a heading that stops mid-token reads as a malformed
        # retro rather than a long one.
        shown = title if len(title) <= 110 else title[:110] + " …"
        print(f"    [{section or '?'}] {shown}")
        n += 1
    if not n:
        print("    (no finding headings — either a clean bill, or a shape README.md forbids)")
LEDGERPY
say ""
say "open pull requests in this repo:"
open_prs="$(gh pr list --state open --json number,title,headRefName --jq '.[] | "  #\(.number) \(.headRefName)  \(.title)"' 2>/dev/null)"
printf '%s\n' "${open_prs:-  (none, or gh unavailable)}"
say ""
say "harness branches with no pull request — a fix nobody can merge:"
# The other half of the same defect: the three fixes the 20260826 retro committed were
# pushed and never opened, and the next lane paid for two of them again believing they
# were in an open pull request. A branch with no PR is invisible to `gh pr list`.
heads="$(gh pr list --state all --limit 100 --json headRefName --jq '.[].headRefName' 2>/dev/null)"
stranded="$(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/harness/*' 2>/dev/null |
  sed 's|^origin/||' |
  while read -r b; do
    printf '%s\n' "$heads" | grep -qx "$b" || echo "  $b — pushed, no pull request"
  done)"
printf '%s\n' "${stranded:-  (none, or gh unavailable)}"

say ""
say "retro proposals already decided — do not re-propose a closed one without new evidence:"
decided="$(gh pr list --state closed --search "head:harness/" --limit 100 \
  --json number,title,headRefName,mergedAt \
  --jq '.[] | select(.headRefName | startswith("harness/")) | "  #\(.number) \(if .mergedAt then "merged" else "CLOSED UNMERGED" end)  \(.title)"' 2>/dev/null)"
printf '%s\n' "${decided:-  (none, or gh unavailable)}"
say ""
say "recent harness commits:"
git log -12 --format='  %h %ad %s' --date=short -- scripts/ .claude/ smoke/ docs/adr/ 2>/dev/null
say '```'

say ""
say "_end of evidence_"

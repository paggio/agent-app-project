#!/usr/bin/env bash
# Dispatch a planned change to every product repo that has a slice.
#
# Each invocation starts with its working directory INSIDE the real product repo, so
# it picks up that repo's CLAUDE.md chain, .claude/settings.json, skills, hooks and
# git remote. That is why this is separate processes rather than subagents spawned
# from the control session.
#
# What this does beyond dispatching: it CAPTURES. The earlier version put three agents
# into background subshells and called `wait`, which discards their exit codes, and asked
# each one for a trailing OK / FAIL:<reason> line that nothing ever read. A dispatcher
# whose result cannot fail cannot be iterated on — so every run now writes a log per repo
# and a fanout.json the repair loop reads, and exits non-zero when any slice failed.
#
#   ./scripts/fanout.sh <change> [options]
#
#     --repos a,b          dispatch only these repos (the repair pass uses this)
#     --prompt-extra FILE  append this file's contents to every dispatched prompt
#     --prompt-extra-dir D per-repo failure context: D/failure-<repo>.md if it exists,
#                          so a repair pass gives each agent ITS OWN evidence and the
#                          repos still go out in parallel
#     --run-dir DIR        where logs and fanout.json land
#     --attempt N          label for the run directory and the prompt
#     --dry-run            print what would be dispatched, launch nothing
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONTROL="$ROOT"

CHANGE=""; ONLY=""; PROMPT_EXTRA=""; PROMPT_EXTRA_DIR=""; RUN_DIR=""; DRY=0; ATTEMPT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) ONLY="$(echo "$2" | tr ',' ' ')"; shift ;;
    --prompt-extra) PROMPT_EXTRA="$2"; shift ;;
    --prompt-extra-dir) PROMPT_EXTRA_DIR="$2"; shift ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    --attempt) ATTEMPT="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "fanout: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
[ -n "$CHANGE" ] || { echo "usage: fanout.sh <change> [options]" >&2; exit 2; }

CHANGE_DIR="changes/$CHANGE"
[ -d "$CHANGE_DIR" ] || { echo "fanout: no such change: $CHANGE_DIR" >&2; exit 1; }

eval "$(./scripts/manifest.py "$CHANGE_DIR" --shell)"
[ "${MANIFEST_OK:-0}" = "1" ] || {
  echo "fanout: change.yaml has problems (above) — fix them before dispatching" >&2
  exit 2
}

# The freeze SHA is a precondition, not a warning. The old check was
# `grep -q '[0-9a-f]\{7,\}' BRIEF.md`, which any stray hex in prose satisfied — so a
# change could fan out against an unfrozen contract and three agents would each invent
# their own interface, which is the exact failure docs/adr/0001 exists to prevent.
if [ -z "$CHANGE_FREEZE_SHA" ]; then
  echo "fanout: change.yaml has no freeze_sha — freeze the contract first (see the" >&2
  echo "fanout: freeze-contract skill), then record the commit in change.yaml." >&2
  exit 1
fi
if ! git cat-file -e "${CHANGE_FREEZE_SHA}^{commit}" 2>/dev/null; then
  echo "fanout: freeze_sha ${CHANGE_FREEZE_SHA} is not a commit in this repo" >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$CHANGE_FREEZE_SHA" HEAD 2>/dev/null; then
  echo "fanout: warning — freeze_sha ${CHANGE_FREEZE_SHA} is not an ancestor of HEAD;" >&2
  echo "fanout: the slices would be built against a contract this branch does not have." >&2
fi

TARGETS="$CHANGE_SLICES"
if [ -n "$ONLY" ]; then
  TARGETS=""
  for r in $ONLY; do
    case " $CHANGE_SLICES " in
      *" $r "*) TARGETS="$TARGETS $r" ;;
      *) echo "fanout: $r is not a slice of $CHANGE (slices: $CHANGE_SLICES)" >&2; exit 2 ;;
    esac
  done
fi
[ -n "${TARGETS// /}" ] || { echo "fanout: nothing to dispatch" >&2; exit 2; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$RUN_DIR" ] || RUN_DIR="$CHANGE_DIR/runs/$TS"
mkdir -p "$RUN_DIR"

SHARED_EXTRA=""
if [ -n "$PROMPT_EXTRA" ]; then
  [ -f "$PROMPT_EXTRA" ] || { echo "fanout: no such file: $PROMPT_EXTRA" >&2; exit 2; }
  SHARED_EXTRA="$(cat "$PROMPT_EXTRA")"
fi

echo "fanout: change=$CHANGE attempt=$ATTEMPT repos=[${TARGETS# }] run=$RUN_DIR"

PIDS=()
LAUNCHED=()
for r in $TARGETS; do
  SLICE="$CHANGE_DIR/$r.md"
  [ -f "$SLICE" ] || { echo "fanout: missing slice file $SLICE" >&2; exit 1; }

  PROMPT="Implement your slice of this change: $CONTROL/$SLICE
Read $CONTROL/$CHANGE_DIR/BRIEF.md for full context and acceptance criteria.
The contracts under $CONTROL/contracts/ are FROZEN at ${CHANGE_FREEZE_SHA}. If your slice
appears to require a contract change, STOP and report it rather than working around it.

After every slice lands, the control repo brings up all of these repos together as one
stack and runs $CONTROL/$CHANGE_DIR/$CHANGE_SMOKE_FILE against a single origin
($CHANGE_SMOKE_BASE — the app at /, this API under /api/). Read that file: the steps
whose owner is '$r' are what your slice will actually be judged on, and they run against
your code through a reverse proxy, not against your test doubles.

Finish with your repo's gates passing, then open a pull request.
Return exactly OK or FAIL:<one-line reason> as the last line of your output."

  EXTRA="$SHARED_EXTRA"
  if [ -n "$PROMPT_EXTRA_DIR" ] && [ -f "$PROMPT_EXTRA_DIR/failure-$r.md" ]; then
    EXTRA="$(cat "$PROMPT_EXTRA_DIR/failure-$r.md")"
  fi

  if [ -n "$EXTRA" ]; then
    PROMPT="$PROMPT

--- This is attempt $ATTEMPT. A previous attempt was deployed and failed as follows.
--- Fix the cause. Do not weaken or delete the assertion to make it pass.
$EXTRA"
  fi

  if [ "$DRY" = "1" ]; then
    echo "fanout: [dry-run] $r -> would switch to feat/$CHANGE and dispatch"
    printf '%s\n' "$PROMPT" > "$RUN_DIR/$r.prompt.txt"
    continue
  fi

  # Submodules land in detached HEAD; committing there loses the work. Branch first.
  git -C "$r" switch -c "feat/$CHANGE" 2>/dev/null || git -C "$r" switch "feat/$CHANGE"

  (
    cd "$r"
    claude -p "$PROMPT" \
      --permission-mode auto \
      --add-dir "$CONTROL/$CHANGE_DIR" \
      --add-dir "$CONTROL/contracts" \
      --add-dir "$CONTROL/smoke" \
      --add-dir "$CONTROL/stack"
    # --add-dir rather than the additionalDirectories setting: the setting grants file
    # access only, while the flag also loads skills from the added directory.
    # smoke/ and stack/ are added so the agent can read what will be asserted against it
    # and how it will be deployed. Both are read-only to it by the control repo's hooks.
  ) > "$RUN_DIR/$r.log" 2>&1 &

  PIDS+=($!)
  LAUNCHED+=("$r")
  echo "fanout: dispatched $r (pid ${PIDS[${#PIDS[@]}-1]}) -> $RUN_DIR/$r.log"
done

if [ "$DRY" = "1" ]; then
  echo "fanout: [dry-run] prompts written to $RUN_DIR"
  exit 0
fi

# Collect. Every slice is waited on individually so its exit code survives — this is the
# whole difference between a dispatcher and a loop you can iterate on.
FAILED=""
RESULTS="$RUN_DIR/fanout.json"
: > "$RUN_DIR/.results.tsv"
for i in "${!PIDS[@]}"; do
  r="${LAUNCHED[$i]}"
  if wait "${PIDS[$i]}"; then code=0; else code=$?; fi
  last="$(grep -v '^[[:space:]]*$' "$RUN_DIR/$r.log" 2>/dev/null | tail -1 || true)"
  case "$last" in
    OK|OK.*)      status="ok";     reason="" ;;
    FAIL:*)       status="failed"; reason="${last#FAIL:}" ;;
    *)            if [ "$code" = "0" ]; then
                    status="unclear"; reason="agent exited 0 without an OK/FAIL line"
                  else
                    status="failed";  reason="agent exited $code"
                  fi ;;
  esac
  [ "$status" = "ok" ] || FAILED="$FAILED $r"
  branch="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$status" "$code" "$branch" "$reason" \
    >> "$RUN_DIR/.results.tsv"
  echo "fanout: $r -> $status${reason:+ ($reason)}"
done

python3 - "$RUN_DIR/.results.tsv" "$RESULTS" "$CHANGE" "$ATTEMPT" "$RUN_DIR" <<'PY'
import json, os, sys
tsv, out, change, attempt, run_dir = sys.argv[1:6]
repos = {}
for line in open(tsv):
    if not line.strip():
        continue
    repo, status, code, branch, reason = (line.rstrip("\n").split("\t") + [""] * 5)[:5]
    repos[repo] = {
        "status": status,
        "exit": int(code) if code.isdigit() else code,
        "branch": branch,
        "reason": reason or None,
        "log": os.path.join(run_dir, f"{repo}.log"),
    }
json.dump({
    "change": change,
    "attempt": int(attempt) if str(attempt).isdigit() else attempt,
    "ok": all(r["status"] == "ok" for r in repos.values()),
    "failed": sorted(k for k, v in repos.items() if v["status"] != "ok"),
    "repos": repos,
}, open(out, "w"), indent=2)
PY
rm -f "$RUN_DIR/.results.tsv"

echo "fanout: results -> $RESULTS"
if [ -n "$FAILED" ]; then
  echo "fanout: FAILED:${FAILED}" >&2
  exit 1
fi
echo "fanout: all slices reported OK — nothing is verified until ./scripts/verify.sh runs"
exit 0

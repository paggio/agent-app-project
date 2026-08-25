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
#     --prompt-extra-dir D per-repo failure context: D/failure-<repo>.md if it exists,
#                          so a repair pass gives each agent ITS OWN evidence and the
#                          repos still go out in parallel
#     --run-dir DIR        where logs and fanout.json land
#     --attempt N          label for the run directory and the prompt
#     --require-brief      refuse to dispatch a repo with no failure-<repo>.md. iterate.sh
#                          passes this on every repair pass: re-running an agent over code
#                          it just wrote, with no evidence, is a blind retry.
#     --timeout-s N        kill a slice that has not finished in N seconds (default 3600)
#     --dry-run            print what would be dispatched, launch nothing
#
# Exit 0 = every slice reported ok. Exit 1 = slices ran, some failed. Exit 2 = refused to
# dispatch anything (bad manifest, missing brief, nothing to do). The caller MUST treat 2
# as fatal — see docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONTROL="$ROOT"

CHANGE=""; ONLY=""; PROMPT_EXTRA_DIR=""; RUN_DIR=""; DRY=0; ATTEMPT=1
REQUIRE_BRIEF=0; TIMEOUT_S="${FANOUT_TIMEOUT_S:-3600}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) ONLY="$(echo "$2" | tr ',' ' ')"; shift ;;
    --prompt-extra-dir) PROMPT_EXTRA_DIR="$2"; shift ;;
    --run-dir) RUN_DIR="$2"; shift ;;
    --attempt) ATTEMPT="$2"; shift ;;
    --require-brief) REQUIRE_BRIEF=1 ;;
    --timeout-s) TIMEOUT_S="$2"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "fanout: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
[ -n "$CHANGE" ] || { echo "usage: fanout.sh <change> [options]" >&2; exit 2; }

CHANGE_DIR="changes/$CHANGE"
[ -d "$CHANGE_DIR" ] || { echo "fanout: no such change: $CHANGE_DIR" >&2; exit 2; }

eval "$(./scripts/manifest.py "$CHANGE_DIR" --shell)"
[ "${MANIFEST_OK:-0}" = "1" ] || {
  echo "fanout: change.yaml has problems (above) — fix them before dispatching" >&2
  exit 2
}

# The freeze SHA is checked by manifest.py --validate, which ran above: it must be a real
# commit and an ancestor of HEAD, and contracts/ must be clean. Those three checks used to
# live here, which meant they only ran on the dispatch path — and iterate.sh swallowed this
# script's exit code, so a change with no freeze SHA was deployed and smoked anyway and
# reported `verified`. One gate, three callers.

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

echo "fanout: change=$CHANGE attempt=$ATTEMPT repos=[${TARGETS# }] run=$RUN_DIR"

# The contracts the slices build against, extracted from the freeze commit rather than
# handed over as the working tree. The prompt used to SAY "FROZEN at <sha>" while granting
# --add-dir on contracts/, i.e. on whatever that directory happened to contain — so the
# freeze was prose the agent was trusted to honour. Now it is the only tree it can read.
FROZEN_CONTRACTS="$RUN_DIR/contracts"
if [ ! -d "$FROZEN_CONTRACTS" ]; then
  _staging="$(mktemp -d "$RUN_DIR/.contracts.XXXXXX")"
  if ! git archive "$CHANGE_FREEZE_SHA" contracts | tar -x -C "$_staging" 2>/dev/null \
     || [ ! -d "$_staging/contracts" ]; then
    rm -rf "$_staging"
    echo "fanout: could not extract contracts/ at $CHANGE_FREEZE_SHA" >&2
    exit 2
  fi
  mv "$_staging/contracts" "$FROZEN_CONTRACTS"
  rm -rf "$_staging"
fi
# The vendored copy each slice repo's own CI verifies against, published from the frozen
# tree rather than asked for. The slice cannot do it: its settings deny editing contracts/
# and its CLAUDE.md says never to, so requiring it made the correct action the one that
# violated the rule — and the two repos resolved that contradiction in opposite directions.
# See docs/adr/0008.
if ! ./scripts/vendor-contracts.sh --from "$FROZEN_CONTRACTS" \
      --repos "$(echo "${TARGETS# }" | tr ' ' ',')"; then
  echo "fanout: could not publish the frozen contracts into the slice repos" >&2
  exit 2
fi

# Absolute, resolved once. The dispatched session's cwd is the submodule, so a relative
# path would not resolve there — and naively prefixing $CONTROL breaks when --run-dir is
# already absolute, which is how iterate.sh may call this.
FROZEN_ABS="$(cd "$FROZEN_CONTRACTS" && pwd)"

PIDS=()
LAUNCHED=()
WATCHDOGS=()
for r in $TARGETS; do
  SLICE="$CHANGE_DIR/$r.md"
  [ -f "$SLICE" ] || { echo "fanout: missing slice file $SLICE" >&2; exit 2; }

  # A repair pass with no evidence is a blind re-run: the agent cannot tell attempt 2 from
  # attempt 1, and it re-reads code it just wrote with no reason to change its approach.
  if [ "$REQUIRE_BRIEF" = "1" ] \
     && { [ -z "$PROMPT_EXTRA_DIR" ] || [ ! -f "$PROMPT_EXTRA_DIR/failure-$r.md" ]; }; then
    echo "fanout: attempt $ATTEMPT for $r has no failure brief at" >&2
    echo "fanout:   ${PROMPT_EXTRA_DIR:-<none>}/failure-$r.md" >&2
    echo "fanout: a repair pass with no evidence is a blind re-run. Refusing." >&2
    exit 2
  fi

  PROMPT="Implement your slice of this change: $CONTROL/$SLICE
Read $CONTROL/$CHANGE_DIR/BRIEF.md for full context and acceptance criteria.

The contracts you build against are at $FROZEN_ABS — contracts/ exactly as of
${CHANGE_FREEZE_SHA}, extracted for this run. The control repo's working copy is not
available to you; it may have moved on. If your slice appears to require a contract
change, STOP and report it rather than working around it.

Your repo carries its OWN vendored copy of contracts/, and its CI verifies your
implementation against that copy rather than against the frozen tree above. That copy has
already been refreshed from the frozen tree for you, so it is correct as you find it: do
not edit it, and DO commit it with the rest of your slice so the promise travels with your
pull request.

After every slice lands, the control repo brings up all of these repos together as one
stack and runs $CONTROL/$CHANGE_DIR/$CHANGE_SMOKE_FILE against a single origin
($CHANGE_SMOKE_BASE — the app at /, this API under /api/). Read that file: the steps
whose owner is '$r' are what your slice will actually be judged on, and they run against
your code through a reverse proxy, not against your test doubles.

Finish with your repo's gates passing, then open a pull request.

When you are done, print this block as the LAST thing you output. Markdown around it is
fine; the three lines themselves must be exact.

<<<SLICE-RESULT
{\"status\": \"...\", \"summary\": \"...\", \"pr\": \"...\", \"contract_gap\": null}
SLICE-RESULT>>>

status is exactly one of:
  \"ok\"                   your slice is implemented, your repo's gates pass, PR opened
  \"failed\"               you could not finish. summary says what stopped you.
  \"blocked-by-contract\"  the slice CANNOT be implemented without changing the contracts
                         above. Set contract_gap to the exact entry and the change
                         required. Use this status ONLY for that. A red contract test in
                         your own repo is \"failed\", not \"blocked-by-contract\" — this
                         status stops the whole change with no retry and sends it back for
                         a re-freeze.
summary: one line, <= 200 characters.  pr: the URL, or null.
If you do not print this block, your slice is recorded as failed."

  EXTRA=""
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

  # `set -m` so the child gets its own process group and the watchdog can kill the whole
  # tree. A dispatched session spawns test runners and build tools that would otherwise
  # outlive a plain `kill`.
  set -m
  (
    cd "$r"
    "$CLAUDE_BIN" -p "$PROMPT" \
      --permission-mode auto \
      --add-dir "$CONTROL/$CHANGE_DIR" \
      --add-dir "$FROZEN_ABS" \
      --add-dir "$CONTROL/smoke" \
      --add-dir "$CONTROL/stack"
    # --add-dir rather than the additionalDirectories setting: the setting grants file
    # access only, while the flag also loads skills from the added directory.
    # smoke/ and stack/ are added so the agent can read what will be asserted against it
    # and how it will be deployed. Both are read-only to it by the control repo's hooks.
    # contracts/ is NOT granted: the frozen copy inside $CHANGE_DIR/runs/... is, and it is
    # already covered by the first --add-dir.
  ) > "$RUN_DIR/$r.log" 2>&1 &
  pid=$!
  set +m

  # No timeout existed anywhere in the harness, so one hung session blocked the loop
  # forever. `timeout(1)` is not on macOS, hence a watchdog per slice.
  ( sleep "$TIMEOUT_S"; kill -TERM -"$pid" 2>/dev/null && touch "$RUN_DIR/.timeout-$r" ) \
    >/dev/null 2>&1 &
  WATCHDOGS+=($!)

  PIDS+=("$pid")
  LAUNCHED+=("$r")
  echo "fanout: dispatched $r (pid $pid, timeout ${TIMEOUT_S}s) -> $RUN_DIR/$r.log"
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
  timed_out=0
  [ -f "$RUN_DIR/.timeout-$r" ] && timed_out=1
  branch="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  # The result is a parsed field, not a matched line. `case "$last" in OK|OK.*)` needed a
  # literal dot, so `OK — done` and `**OK**` all fell through to "unclear", which counted
  # as failed — a successful slice routinely earned a repair pass.
  ./scripts/slice-result.py --log "$RUN_DIR/$r.log" --repo "$r" --exit "$code" \
      --branch "$branch" --timed-out "$timed_out" >> "$RUN_DIR/.results.tsv"
  status="$(tail -1 "$RUN_DIR/.results.tsv" | cut -f2)"
  reason="$(tail -1 "$RUN_DIR/.results.tsv" | cut -f5)"
  [ "$status" = "ok" ] || FAILED="$FAILED $r"
  echo "fanout: $r -> $status${reason:+ ($reason)}"
done

# Watchdogs are no longer needed; leaving them would keep the script alive for the timeout.
for w in "${WATCHDOGS[@]:-}"; do kill "$w" 2>/dev/null || true; done

python3 - "$RUN_DIR/.results.tsv" "$RESULTS" "$CHANGE" "$ATTEMPT" "$RUN_DIR" <<'PY'
import json, os, sys
tsv, out, change, attempt, run_dir = sys.argv[1:6]
repos = {}
for line in open(tsv):
    if not line.strip():
        continue
    parts = (line.rstrip("\n").split("\t") + [""] * 7)[:7]
    repo, status, code, branch, reason, pr, gap = parts
    repos[repo] = {
        "status": status,
        "exit": int(code) if code.isdigit() else code,
        "branch": branch,
        "reason": reason or None,
        "pr": pr or None,
        # A field, so iterate.sh stops grepping the whole file for the word "contract".
        "contract_gap": gap or None,
        "log": os.path.join(run_dir, f"{repo}.log"),
    }
json.dump({
    "change": change,
    "attempt": int(attempt) if str(attempt).isdigit() else attempt,
    "ok": all(r["status"] == "ok" for r in repos.values()),
    "failed": sorted(k for k, v in repos.items() if v["status"] != "ok"),
    "contract_gaps": sorted(k for k, v in repos.items()
                            if v["status"] == "blocked-by-contract"),
    "repos": repos,
}, open(out, "w"), indent=2)
PY
rm -f "$RUN_DIR/.results.tsv" "$RUN_DIR"/.timeout-* 2>/dev/null || true

echo "fanout: results -> $RESULTS"
if [ -n "$FAILED" ]; then
  echo "fanout: FAILED:${FAILED}" >&2
  exit 1
fi
echo "fanout: all slices reported OK — nothing is verified until ./scripts/verify.sh runs"
exit 0

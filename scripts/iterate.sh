#!/usr/bin/env bash
# Fan out a change, deploy it, smoke it, and send failures back to the repo that caused
# them — up to a bounded number of attempts.
#
# This is the loop the harness was missing. Before it, the cycle was: dispatch three
# agents, read three PR links, and find out whether the pieces fit together by hand, later.
# Now the oracle runs immediately and its output is machine-addressable, so a failing
# assertion goes back to one agent with the evidence attached instead of to a human with
# a shrug.
#
# It is a deterministic script that DISPATCHES agents, not an agent that orchestrates
# repos — see docs/adr/0002. The control flow, the attribution and the stopping
# conditions are all fixed here, where they can be read and audited.
#
#   ./scripts/iterate.sh <change> [options]
#
#     --max-attempts N  total passes, including the first (default 2)
#     --no-repair       fan out and verify once, then stop and report
#     --verify-only     skip dispatching entirely; just deploy and check what is on disk
#     --keep-up         leave the stack running after the final attempt
#     --e2e             also run Playwright on each verify
#     --no-build        reuse existing images
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHANGE=""; MAX_ATTEMPTS=2; REPAIR=1; VERIFY_ONLY=0; KEEP_UP=0; E2E=0; NO_BUILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --max-attempts) MAX_ATTEMPTS="$2"; shift ;;
    --no-repair) REPAIR=0 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --keep-up) KEEP_UP=1 ;;
    --e2e) E2E=1 ;;
    --no-build) NO_BUILD="--no-build" ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "iterate: unknown option $1" >&2; exit 2 ;;
    *) CHANGE="$1" ;;
  esac
  shift
done
[ -n "$CHANGE" ] || { echo "usage: iterate.sh <change> [options]" >&2; exit 2; }

CHANGE_DIR="changes/$CHANGE"
[ -d "$CHANGE_DIR" ] || { echo "iterate: no such change: $CHANGE_DIR" >&2; exit 2; }

eval "$(./scripts/manifest.py "$CHANGE_DIR" --shell)"
[ "${MANIFEST_OK:-0}" = "1" ] || {
  echo "iterate: change.yaml has problems (above) — fix them first" >&2; exit 2; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ROOT="$CHANGE_DIR/runs/$TS"
mkdir -p "$RUN_ROOT"
REPORT="$RUN_ROOT/report.md"

say() { echo "iterate: $*"; }
banner() {
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "════════════════════════════════════════════════════════════════"
}

TARGETS="$CHANGE_SLICES"
ATTEMPT=1
OUTCOME="unknown"
SUMMARY=""

record() { SUMMARY="$SUMMARY$1
"; }

write_report() {
  {
    echo "# $CHANGE — iterate report"
    echo
    echo "- run: \`$RUN_ROOT\`"
    echo "- outcome: **$OUTCOME**"
    echo "- attempts used: $((ATTEMPT > MAX_ATTEMPTS ? MAX_ATTEMPTS : ATTEMPT)) of $MAX_ATTEMPTS"
    echo "- slices: $CHANGE_SLICES"
    echo "- infra deploy: $([ "$CHANGE_DEPLOY_INFRA" = "1" ] && echo yes || echo no)"
    echo
    echo "## What happened"
    echo
    printf '%s' "$SUMMARY"
    echo
    echo "## Evidence"
    echo
    for d in "$RUN_ROOT"/attempt-*; do
      [ -d "$d" ] || continue
      echo "- \`$d\`"
      [ -f "$d/fanout.json" ] && echo "  - dispatch results: \`$d/fanout.json\`"
      [ -f "$d/smoke.json" ]  && echo "  - smoke results: \`$d/smoke.json\`"
      [ -f "$d/verify.json" ] && echo "  - verify result: \`$d/verify.json\`"
    done
    echo
    echo "## Next"
    echo
    if [ "$OUTCOME" = "verified" ]; then
      echo "The change is deployed and asserted locally. Review the PRs and merge in"
      echo "dependency order — merging is a human decision. Then run \`./scripts/lock.sh\`"
      echo "and commit \`repos.lock\`, and promote the durable smoke steps into"
      echo "\`smoke/baseline.yaml\`."
    elif [ "$OUTCOME" = "contract-gap" ]; then
      echo "A slice reported that it cannot be implemented against the frozen contract."
      echo "Do not patch around it. Open a contract-freeze pass (see the freeze-contract"
      echo "skill), re-freeze, update \`freeze_sha\` in \`change.yaml\`, and re-run."
    else
      echo "Attempts exhausted with the assertions still failing. Read the failing steps"
      echo "above and the briefs at \`$RUN_ROOT/attempt-*/failure-*.md\` — those are exactly"
      echo "what the agents were given. If an assertion is wrong, fix it here in the"
      echo "control repo; if the implementation is wrong, re-run with more attempts."
    fi
  } > "$REPORT"
}

# STATUS.md is the one place that knows the state of all three PRs at once. A green CI
# column there only ever meant "each repo is internally consistent"; this line is what
# says they work together, so it belongs next to the PR table rather than buried in runs/.
update_status() {
  STATUS_FILE="$CHANGE_DIR/STATUS.md"
  [ -f "$STATUS_FILE" ] || return 0
  python3 - "$STATUS_FILE" "$OUTCOME" "$RUN_ROOT" "$TS" "$REPORT" <<'STATUSPY'
import json, os, re, sys

path, outcome, run_root, ts, report = sys.argv[1:6]
text = open(path).read()
if "<!-- iterate:begin -->" not in text:
    raise SystemExit(0)

stage = owners = ""
attempts = sorted(d for d in os.listdir(run_root) if d.startswith("attempt-"))
for d in attempts:
    try:
        v = json.load(open(os.path.join(run_root, d, "verify.json")))
    except Exception:
        continue
    stage = v.get("failed_stage") or ""
    owners = " ".join(v.get("owners_failing") or [])

lines = [f"- **{outcome}** \u2014 {ts}, {len(attempts)} attempt(s)"]
if outcome != "verified":
    if stage:
        lines.append(f"- failed at: `{stage}`")
    if owners:
        lines.append(f"- answerable: {owners}")
lines.append(f"- report: `{report}`")

block = "<!-- iterate:begin -->\n" + "\n".join(lines) + "\n<!-- iterate:end -->"
text = re.sub(r"<!-- iterate:begin -->.*?<!-- iterate:end -->", block, text, flags=re.S)
open(path, "w").write(text)
print(f"iterate: STATUS.md updated ({outcome})")
STATUSPY
}

finish() {
  write_report
  update_status
  banner "$CHANGE — $OUTCOME"
  printf '%s' "$SUMMARY"
  echo
  say "report: $REPORT"
  [ "$KEEP_UP" = "1" ] && say "stack left running — ./scripts/stack.sh down when finished"
  case "$OUTCOME" in
    verified) exit 0 ;;
    *) exit 1 ;;
  esac
}

while :; do
  ATT_DIR="$RUN_ROOT/attempt-$ATTEMPT"
  mkdir -p "$ATT_DIR"

  # ── dispatch ────────────────────────────────────────────────────────────────
  if [ "$VERIFY_ONLY" = "1" ]; then
    say "verify-only — dispatching nothing, checking what is on disk"
    record "**Attempt $ATTEMPT — dispatch:** skipped (\`--verify-only\`)"
  else
    banner "attempt $ATTEMPT/$MAX_ATTEMPTS — dispatch [${TARGETS# }]"
    PREV="$RUN_ROOT/attempt-$((ATTEMPT - 1))"
    FANOUT_ARGS=("$CHANGE" --repos "$(echo "${TARGETS# }" | tr ' ' ',')"
                 --run-dir "$ATT_DIR" --attempt "$ATTEMPT")
    # Each repo picks up its own failure-<repo>.md, so a repair pass hands every agent
    # only the evidence it is answerable for — and they still go out in parallel.
    [ "$ATTEMPT" -gt 1 ] && FANOUT_ARGS+=(--prompt-extra-dir "$PREV")

    FANOUT_FAILED=""
    ./scripts/fanout.sh "${FANOUT_ARGS[@]}" || FANOUT_FAILED="$(python3 -c "
import json
try:
    print(' '.join(json.load(open('$ATT_DIR/fanout.json')).get('failed') or []))
except Exception:
    print('${TARGETS# }')
" 2>/dev/null || echo "${TARGETS# }")"

    # A slice that stopped on a contract gap is a hard stop, always. Working around a
    # frozen contract locally is the one failure this whole structure exists to prevent,
    # so it never gets a retry.
    if [ -f "$ATT_DIR/fanout.json" ] && grep -qi 'contract' "$ATT_DIR/fanout.json"; then
      if python3 -c "
import json,sys
d=json.load(open('$ATT_DIR/fanout.json'))
gaps=[k for k,v in d['repos'].items() if (v.get('reason') or '').lower().find('contract')>=0]
print(' '.join(gaps))
sys.exit(0 if gaps else 1)" > "$ATT_DIR/.contract-gaps" 2>/dev/null; then
        OUTCOME="contract-gap"
        record "**Attempt $ATTEMPT — dispatch:** stopped. $(cat "$ATT_DIR/.contract-gaps") reported a contract gap."
        record ""
        record "A frozen contract cannot be worked around in a slice. This needs a new"
        record "contract-freeze pass in the control repo before anything else happens."
        finish
      fi
    fi

    if [ -n "$FANOUT_FAILED" ]; then
      record "**Attempt $ATTEMPT — dispatch:** failed for:${FANOUT_FAILED}"
    else
      record "**Attempt $ATTEMPT — dispatch:** all slices reported OK"
    fi
  fi

  # ── deploy + assert ─────────────────────────────────────────────────────────
  banner "attempt $ATTEMPT/$MAX_ATTEMPTS — deploy and smoke"
  VERIFY_ARGS=("$CHANGE" --run-dir "$ATT_DIR")
  [ -n "$NO_BUILD" ] && VERIFY_ARGS+=("$NO_BUILD")
  [ "$E2E" = "1" ] && VERIFY_ARGS+=(--e2e)
  # Keep the stack up between attempts: rebuilding from cold on every pass is most of the
  # wall-clock, and the repair agent may want to poke at a running system.
  if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ] || [ "$KEEP_UP" = "1" ]; then
    VERIFY_ARGS+=(--keep-up)
  fi

  if ./scripts/verify.sh "${VERIFY_ARGS[@]}"; then
    OUTCOME="verified"
    record "**Attempt $ATTEMPT — verify:** PASS. The joined stack came up and every"
    record "assertion held through \`$CHANGE_SMOKE_BASE\`."
    finish
  fi

  # ── attribute ───────────────────────────────────────────────────────────────
  OWNERS="$(python3 -c "
import json
try:
    d = json.load(open('$ATT_DIR/verify.json'))
    print(' '.join(d.get('owners_failing') or []))
except Exception:
    print('')
" 2>/dev/null || true)"
  STAGE="$(python3 -c "
import json
try:
    print(json.load(open('$ATT_DIR/verify.json')).get('failed_stage') or 'unknown')
except Exception:
    print('unknown')
" 2>/dev/null || echo unknown)"

  # Nothing named an owner (a stage that fails before any assertion runs, e.g. preflight).
  # Retrying blind would just burn an attempt, so stop and say why.
  if [ -z "${OWNERS// /}" ]; then
    OWNERS="$(echo "${FANOUT_FAILED:-}" | tr -s ' ')"
  fi
  record "**Attempt $ATTEMPT — verify:** FAIL at \`$STAGE\`"
  if [ -z "${OWNERS// /}" ]; then
    OUTCOME="unattributable"
    record ""
    record "No repo could be held answerable for this failure — it happened before any"
    record "owned assertion ran. This is a harness or environment problem, not a slice"
    record "problem. See \`$ATT_DIR\`."
    finish
  fi
  record "answerable: ${OWNERS}"

  # ── stop, or repair ─────────────────────────────────────────────────────────
  if [ "$REPAIR" = "0" ]; then
    OUTCOME="failed"
    record ""
    record "Repair disabled (\`--no-repair\`)."
    finish
  fi
  if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    OUTCOME="failed"
    record ""
    record "Attempts exhausted ($MAX_ATTEMPTS)."
    finish
  fi

  banner "attempt $ATTEMPT/$MAX_ATTEMPTS — preparing repair briefs for [${OWNERS}]"
  for r in $OWNERS; do
    case " $CHANGE_SLICES " in
      *" $r "*) ;;
      *) say "warning — $r owns a failing step but has no slice in this change; skipping"
         continue ;;
    esac
    ./scripts/failure-brief.py --run-dir "$ATT_DIR" --repo "$r" \
      --change "$CHANGE" --attempt "$ATTEMPT" -o "$ATT_DIR/failure-$r.md"
  done

  TARGETS=""
  for r in $OWNERS; do
    case " $CHANGE_SLICES " in
      *" $r "*) TARGETS="$TARGETS $r" ;;
    esac
  done
  if [ -z "${TARGETS// /}" ]; then
    OUTCOME="unattributable"
    record ""
    record "Every failing owner is outside this change's slices; nothing to repair."
    finish
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

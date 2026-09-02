#!/usr/bin/env bash
# Criterion 8 of changes/0005: a trace recorded before Phoenix restarts is still there
# afterwards. Also prints the backend log lines carrying the same trace id, which is the
# only place criterion 9's correlation is visible outside chatbot-backend's own tests.
#
# NOT A SMOKE STEP, and it cannot be one: smoke.py asserts over HTTP against a stack
# somebody else brought up, so it can neither cycle a container nor read stdout. This is the
# oracle instead. It fails for real — a Phoenix on an ephemeral database, a missing volume,
# or a header that correlates with nothing all end here rather than in a green report.
#
#   ./scripts/phoenix-durability.sh          against the running joined stack
#
# Exit 1 the property failed · exit 2 the check could not be made. See docs/adr/0003.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/dev-env.sh"

BASE="${BASE:-http://localhost:8080}"
: "${PHOENIX_BASE:?PHOENIX_BASE is not set — it is declared in stack/dev.env}"
: "${PHOENIX_PROJECT_NAME:?PHOENIX_PROJECT_NAME is not set — it is declared in stack/dev.env}"

spans_url() { echo "$PHOENIX_BASE/v1/projects/$PHOENIX_PROJECT_NAME/spans?trace_id=$1"; }

# An UNAUTHENTICATED request, on purpose. It is refused with a 401 and it is still traced,
# so this check needs no account, no signup code and no cleanup — and it asserts the thing
# that matters: instrumentation wraps the app, not the handlers that happen to succeed.
headers="$(curl -sS -D - -o /dev/null "$BASE/api/v1/threads" | tr -d '\r')" || {
  echo "phoenix-durability: cannot reach $BASE — is the stack up? (make up)" >&2; exit 2; }
trace="$(printf '%s\n' "$headers" | awk 'tolower($1)=="x-trace-id:"{print $2}')"

if [ -z "$trace" ]; then
  echo "FAIL — no X-Trace-Id on the response. Telemetry is off, or the header is missing." >&2
  exit 1
fi
echo "  trace id            $trace"

# The export is batched, which is required rather than incidental, so the span is not there
# the instant the response returns. Forty seconds, then it is a failure and not a wait.
found=""
for _ in $(seq 1 20); do
  if curl -sS "$(spans_url "$trace")" | grep -q "\"trace_id\":\"$trace\""; then found=1; break; fi
  sleep 2
done
if [ -z "$found" ]; then
  echo "FAIL — Phoenix never received $trace. The exporter is not reaching $PHOENIX_BASE." >&2
  exit 1
fi
echo "  in phoenix before   yes"

# Criterion 9, shown rather than asserted: the same id in the backend's stdout. A count of
# zero here is a finding even though this script does not fail on it — the assertion lives
# in chatbot-backend's tests, where a log record can be inspected instead of grepped.
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT
"$ROOT/scripts/stack.sh" dump "$logs" >/dev/null 2>&1 || true
echo "  log lines with it   $(grep -c "$trace" "$logs/backend.container.log" 2>/dev/null || echo 0)"

"$ROOT/scripts/stack.sh" restart phoenix >/dev/null
curl -sS --retry 40 --retry-delay 2 --retry-all-errors -o /dev/null "$PHOENIX_BASE/healthz" || {
  echo "phoenix-durability: phoenix did not come back after the restart" >&2; exit 2; }

if curl -sS "$(spans_url "$trace")" | grep -q "\"trace_id\":\"$trace\""; then
  echo "  in phoenix after    yes"
  echo "PASS — the trace survived the restart."
else
  echo "FAIL — $trace is gone after restarting phoenix. Its storage is not durable." >&2
  exit 1
fi

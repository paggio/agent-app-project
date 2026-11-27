#!/usr/bin/env bash
# Seed the joined local stack with what every suite may assume: one published, indexed
# metrics release. Without it the gateway answers `no_release`, the metrics spoke is never
# routed to, and any metrics criterion fails for a change that never touched metrics
# (0010). docs/adr/0021.
#
#   ./scripts/seed-local.sh [--log-dir DIR]
#
# Prints the owner of the first failing seed on stdout and exits 1; exit 0 when seeded.
set -euo pipefail
LOG_DIR="."
[ "${1:-}" = "--log-dir" ] && LOG_DIR="${2:?--log-dir needs a directory}"

# service  owner  budget(s) — in order: the indexer indexes the newest published release.
SEEDS="dbt-release analytics-dbt 1500
indexer metrics-gateway 900"

while read -r svc owner budget; do
  log="$LOG_DIR/seed-$svc.log"
  echo "seed: $svc (owner $owner, budget ${budget}s) -> $log" >&2
  ./scripts/stack.sh run "$svc" < /dev/null > "$log" 2>&1 &
  pid=$!
  ( sleep "$budget"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  dog=$!
  set +e; wait "$pid"; rc=$?; set -e
  kill "$dog" 2>/dev/null || true
  if [ "$rc" != 0 ]; then
    echo "seed: $svc exited $rc — see $log" >&2
    tail -20 "$log" >&2 || true
    echo "$owner"
    exit 1
  fi
done <<< "$SEEDS"
echo "seed: release published and indexed" >&2

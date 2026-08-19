#!/usr/bin/env bash
# Drive the joined local stack (stack/compose.yml).
#
# One place that knows the compose invocation, so verify.sh, iterate.sh and a human at a
# terminal cannot drift apart on flags.
#
#   ./scripts/stack.sh up [--no-build]   bring it up and BLOCK until every healthcheck passes
#   ./scripts/stack.sh down              tear down, including volumes
#   ./scripts/stack.sh logs [svc...]     follow logs
#   ./scripts/stack.sh dump <dir>        write per-service logs into <dir> (used on failure)
#   ./scripts/stack.sh rebuild <svc>     rebuild one service without touching the rest
#   ./scripts/stack.sh ps                what is running
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Local values for the stack, before any compose call: compose interpolates ${SIGNUP_CODE}
# and friends at parse time, so an unloaded variable becomes a silently empty environment
# entry rather than an error. The real environment wins — see scripts/dev-env.sh.
. "$ROOT/scripts/dev-env.sh"

COMPOSE=(docker compose -f "$ROOT/stack/compose.yml")
SERVICES=(backend postgres redis frontend proxy)

cmd="${1:-}"; shift || true

case "$cmd" in
  up)
    build=(--build)
    [ "${1:-}" = "--no-build" ] && build=()
    # --wait is what makes this safe to smoke against: it blocks on the healthchecks
    # declared in each repo's compose plus the proxy healthcheck added in stack/compose.yml.
    # ${x[@]+"${x[@]}"} rather than "${x[@]}": bash 3.2 (what macOS ships) treats an empty
    # array as unbound under `set -u`.
    "${COMPOSE[@]}" up -d ${build[@]+"${build[@]}"} --wait
    ;;
  down)
    "${COMPOSE[@]}" down -v --remove-orphans
    ;;
  logs)
    "${COMPOSE[@]}" logs -f "$@"
    ;;
  dump)
    dir="${1:?usage: stack.sh dump <dir>}"
    mkdir -p "$dir"
    for s in "${SERVICES[@]}"; do
      "${COMPOSE[@]}" logs --no-color --tail 400 "$s" > "$dir/$s.container.log" 2>&1 || true
    done
    "${COMPOSE[@]}" ps --format json > "$dir/ps.json" 2>&1 || true
    ;;
  rebuild)
    svc="${1:?usage: stack.sh rebuild <service>}"
    "${COMPOSE[@]}" up -d --build --wait "$svc"
    ;;
  ps)
    "${COMPOSE[@]}" ps
    ;;
  config)
    "${COMPOSE[@]}" config "$@"
    ;;
  *)
    sed -n '2,12p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac

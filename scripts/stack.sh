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
#   ./scripts/stack.sh run <svc> [K=V…]  run a ONE-SHOT service to completion, --rm
#   ./scripts/stack.sh rebuild <svc>     rebuild one service without touching the rest
#   ./scripts/stack.sh restart <svc>     stop and start one service, keeping its volumes
#   ./scripts/stack.sh ps                what is running
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Local values for the stack, before any compose call: compose interpolates ${SIGNUP_CODE}
# and friends at parse time, so an unloaded variable becomes a silently empty environment
# entry rather than an error. The real environment wins — see scripts/dev-env.sh.
. "$ROOT/scripts/dev-env.sh"

COMPOSE=(docker compose -f "$ROOT/stack/compose.yml")
# Every service in stack/compose.yml, and check-docs.py [stack-services] fails if this
# list falls behind it — 0004 added opensearch and minio and this line did not move, so
# every failure dump since has been missing two of the backend's datastores. 0005 added
# phoenix and phoenix-db; both are here for the same reason and the gate now holds it.
# 0006 adds `eval`, a one-shot service in a manual profile rather than something `up`
# brings up — `logs` for it is usually empty, and that is correct. It is listed because
# [stack-services] requires every service stack/compose.yml declares to be dumpable,
# and because a run that DID leave a container behind is exactly the case where a
# reader wants its log.
# ONE LINE, and it has to stay one: check-docs.py [stack-services] reads this with a
# line-anchored regex, so a wrapped array parses as almost empty and every service
# reads as missing. That is how this comment got written.
SERVICES=(backend postgres opensearch minio redis phoenix phoenix-db frontend proxy eval)

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
  run)
    # A one-shot service, run to completion, with its exit code passed straight back to the
    # caller — that code is the assertion. `--rm` so a job leaves no container behind, and
    # `-T` because there is no terminal in the loop: without it compose allocates one and
    # interleaves control characters into the log a repair agent has to read.
    #
    # Environment arrives as bare KEY=VALUE words and is translated here rather than taken
    # as raw compose flags, so a caller cannot smuggle in `--entrypoint` or `-v`. A job may
    # override a threshold; it may not redefine the service.
    svc="${1:?usage: stack.sh run <service> [KEY=VALUE ...]}"; shift
    RUN_ENV=()
    for pair in "$@"; do
      case "$pair" in
        [A-Za-z_]*=*) RUN_ENV+=(-e "$pair") ;;
        *) echo "stack.sh run: '$pair' is not KEY=VALUE" >&2; exit 2 ;;
      esac
    done
    "${COMPOSE[@]}" run --rm -T ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$svc"
    ;;
  rebuild)
    svc="${1:?usage: stack.sh rebuild <service>}"
    "${COMPOSE[@]}" up -d --build --wait "$svc"
    ;;
  restart)
    # Deliberately NOT `down && up`: that drops the volumes, which is the opposite of what
    # the one caller wants. `make phoenix-durability` restarts Phoenix and then asks whether
    # a trace recorded before the restart is still there, so the volume has to survive.
    svc="${1:?usage: stack.sh restart <service>}"
    "${COMPOSE[@]}" restart "$svc"
    ;;
  ps)
    "${COMPOSE[@]}" ps
    ;;
  config)
    # `docker compose config` INLINES env_file, so on this stack it prints the real AWS
    # credentials from chatbot-backend/.env — and it is the obvious first debugging
    # command. Redacted here so the safe spelling is the convenient one. Nothing else in
    # this repo may print raw compose config; service-owner.sh reads it in-process and
    # emits only labels.
    "${COMPOSE[@]}" config "$@" | python3 -c '
import re, sys
SECRET = re.compile(r"(SECRET|TOKEN|PASSWORD|CREDENTIAL|_KEY|KEY_ID|SIGNUP_CODE)", re.I)
for line in sys.stdin:
    m = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(:\s*)(.+?)(\s*)$", line)
    if m and SECRET.search(m.group(2)) and m.group(4) not in ("null", "{}", "[]"):
        print(f"{m.group(1)}{m.group(2)}{m.group(3)}<redacted {len(m.group(4))} chars>")
    else:
        sys.stdout.write(line)
'

    ;;
  *)
    sed -n '2,14p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac

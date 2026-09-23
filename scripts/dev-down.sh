#!/usr/bin/env bash
# `make dev-down`: take dev to zero, then prove nothing billable is left.
#
#   ./scripts/dev-down.sh             from here, with the `make login` session
#   ./scripts/dev-down.sh --via ci    the dev-down workflow, with the pushed session
#
# Both run the same two targets: `destroy ENV=dev CONFIRM=dev`, then `leftovers ENV=dev`,
# which lists anything still tagged Environment=dev that bills and exits 1 if there is.
# A destroy that exits 0 is not the claim; an empty leftovers list is. What survives by
# design is bootstrap — state bucket, registries, the deployer role, the budget, the cost
# export — which costs cents. No loop calls this. docs/adr/0018 §10.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONTROL="Paggio/agent-app-project"

case "${1:-}" in
  "")
    ./scripts/with-aws.sh ./scripts/infra.sh destroy ENV=dev CONFIRM=dev
    ./scripts/with-aws.sh ./scripts/infra.sh leftovers ENV=dev
    echo "dev-down: dev is down and nothing billable is tagged for it" ;;
  --via)
    [ "${2:-}" = "ci" ] || { echo "usage: dev-down.sh [--via ci]" >&2; exit 2; }
    SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gh workflow run dev-down.yml -R "$CONTROL" --ref main -f confirm=dev
    RUN=""
    for _ in $(seq 1 30); do
      RUN="$(gh run list -R "$CONTROL" --workflow dev-down.yml --limit 5 --json databaseId,createdAt \
              --jq "[.[] | select(.createdAt >= \"$SINCE\")] | .[0].databaseId // empty")"
      [ -n "$RUN" ] && break
      sleep 4
    done
    [ -n "$RUN" ] || { echo "dev-down: no dev-down run appeared" >&2; exit 2; }
    echo "dev-down: https://github.com/$CONTROL/actions/runs/$RUN"
    gh run watch "$RUN" -R "$CONTROL" --interval 30 --exit-status ;;
  *) echo "usage: dev-down.sh [--via ci]" >&2; exit 2 ;;
esac

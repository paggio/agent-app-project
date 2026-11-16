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
CONTROL="$("$ROOT"/scripts/repos.py owner)/agent-app-project"

case "${1:-}" in
  "")
    # Destroy with the infra that deployed dev (verify-remote.sh records it). A checkout on
    # any other commit may not know every resource that is up — refuse rather than guess.
    want="$(./scripts/with-aws.sh sh -c 'aws s3 cp --quiet "s3://agentapp-tfstate-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION:-eu-west-1}/dev/deployed-set.json" - 2>/dev/null' \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["repos"]["infra"]["sha"])' 2>/dev/null || true)"
    have="$(git -C infra rev-parse HEAD 2>/dev/null || echo none)"
    if [ -n "$want" ] && [ "$want" != "$have" ]; then
      echo "dev-down: dev was deployed by infra ${want:0:12}; infra/ is at ${have:0:12}." >&2
      echo "dev-down:   git -C infra fetch && git -C infra switch --detach $want   (or: make dev-down VIA=ci)" >&2
      exit 2
    fi
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

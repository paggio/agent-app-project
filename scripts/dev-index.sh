#!/usr/bin/env bash
# dev-index [N] — what dev's OpenSearch holds: every index with its count, distinct calls,
# and the N newest call chunks without their vectors. Read-only. Run via with-aws.sh.
set -euo pipefail
N="${1:-3}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="$ROOT/.kube/dev"
"$ROOT/scripts/infra.sh" kubeconfig ENV=dev >/dev/null 2>&1 || { echo "dev-index: no cluster — is dev up?" >&2; exit 2; }
q() { kubectl -n agentapp exec opensearch-0 -c opensearch -- \
        curl -s -H 'Content-Type: application/json' "localhost:9200/$1" ${2:+-d "$2"}; }
q '_cat/indices?v&s=index&h=index,docs.count,store.size'
echo
q 'calls-chunks/_search' '{"size":0,"aggs":{"c":{"cardinality":{"field":"call_id"}}}}' \
  | jq -r '"calls-chunks: \(.aggregations.c.value) calls in \(.hits.total.value) chunks"'
q 'calls-chunks/_search' "{\"size\":$N,\"sort\":[{\"started_at\":\"desc\"}],\"_source\":{\"excludes\":[\"embedding\"]}}" \
  | jq '.hits.hits[]._source'

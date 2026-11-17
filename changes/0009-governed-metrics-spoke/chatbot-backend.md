# 0009 — chatbot-backend slice

## What to build

A fourth spoke, `metrics`, that answers data questions only through metrics-gateway's MCP
tools, and a fourth route.

### 1. MCP client

- `METRICS_GATEWAY_URL` (e.g. `http://metrics-gateway:8080/mcp`). Unset → the spoke is off
  and `metrics` is never routed to; the app runs exactly as today.
- Client: the official `mcp` SDK over streamable HTTP (or `langchain-mcp-adapters` if it
  fits the exact langgraph/langchain pins — check, do not move the pins). Propagate
  `traceparent` so the gateway's spans join the turn's trace.
- Gateway unreachable, or `no_release`: treat as no match for routing; never a 5xx, never a
  hang (short connect/read timeouts, settings).

### 2. Routing

- `route` gains `metrics` everywhere the three routes are listed (the `Route` literal,
  `ROUTES`, the thread models, the graph's next-step map, the LLM coordinator prompt).
- Heuristic coordinator order: call id / call words → `calls`; else
  `search_semantic(question, kinds=[metric, saved_query], top_k=3)` returns hits (the
  gateway's floor decides) → `metrics`; else the documents check → `documents`; else
  `general`. The index decides, so there is no metric-word list to drift.
- LLM coordinator: knows the metrics spoke; the same search can be a tie-breaker. Your call.

### 3. The spoke

- **Deterministic first pass** (runs under `CHAT_MODEL=echo`): `search_semantic` (all
  kinds) → take the top metric or saved query → `describe_metric` for its valid group_bys →
  group_by from dimension hits that are valid group_bys → equality filters from
  `dimension_value` hits whose dimension is valid (`SP` → `customer__state = 'SP'`) → a time
  window from the question (a year → Jan 1–Dec 31; a quarter; a month) → `query_metrics` or
  `run_saved_query`. "What was GMV in SP in 2017?" must become `gmv`, filter
  `customer__state eq SP`, start `2017-01-01`, end `2017-12-31`, one row.
- The result (definition, sha, rows) goes in front of the answering model, and the model
  must quote the definition and sha next to every number.
- With a tool-capable chat model, the answering agent also gets the six gateway tools;
  every successful query it runs becomes a citation too.
- `no_match` (or a refused first pass): the answer is that no governed metric answers the
  question, `metric_citations: []`. No SQL fallback, no other spoke.

### 4. Persistence and API

- Migration `0008_metric_citations.sql`: `messages.metric_citations jsonb`, nullable.
- `Message.metric_citations` exactly per `MetricCitation`/`MetricResult`: one per query,
  markers 1-based contiguous, rows cut to 50 with `row_count` and `truncated`, `filters`
  rendered as `"<dimension> = '<value>'"` (`in` as `IN (...)`), snapshots never re-resolved.
  A `metrics` turn has empty `citations` and `call_citations` and `retrieval_consulted: false`.
- Phoenix tags as for the other routes: `route:metrics`, `metadata.route = metrics`.

### 5. Docs

`docs/architecture.md` (the spoke, the routing order, the gateway dependency and how it
fails), `docs/graph.md` regenerated (`make graph`), `README.md`/`CLAUDE.md` config tables.

## Contract entries this depends on

- `contracts/openapi.yaml` 1.8.0 → `Message.route` (`metrics`), `Message.metric_citations`,
  `MetricCitation`, `MetricResult`.
- `contracts/mcp/metrics-gateway.json` — you are its consumer: tools, errors, `x-transport`.
- `contracts/README.md` § "The coordinator and its spokes", § "The metrics spoke".
- `contracts/infra-outputs.yaml` → `metrics_gateway_url`.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and
report it rather than working around it.

## Verification

- [ ] unit: routing order with a fake gateway (hit, no_match, unreachable); the
      deterministic planner on the GMV/SP/2017 question and on a group-by question;
      citation building (markers, 50-row cut, filters rendering); migration.
- [ ] `make contract` green against the vendored 1.8.0.
- [ ] the repo's own gates pass.

## Smoke — what this slice is actually judged on

Steps with `owner: chatbot-backend`: register/login/thread;
`gmv-in-sp-in-2017-routes-to-metrics-and-cites-gmv` (route `metrics`, citation
`{marker: 1, project: olist, metric: gmv, sha: <served>, start: 2017-01-01, end:
2017-12-31, result: {row_count: 1, truncated: false}}`, filters mention SP);
`a-coding-question-does-not-route-to-metrics` (route `general`). The local stack runs
`CHAT_MODEL=echo` and `RETRIEVAL_ROUTER=heuristic`.

The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- `BACKEND_IMAGE_TAG` is bumped to `local-0.2.0` in the control repo.
- The stack passes `METRICS_GATEWAY_URL=http://metrics-gateway:8080/mcp`; on dev infra
  passes the same from `metrics_gateway_url`.

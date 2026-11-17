# 0009 — metrics-gateway slice

This repo is new: it starts from the scaffold. Choose the toolchain (Python 3.13, uv),
make `make check` real (it refuses until you do), and fill `docs/architecture.md`,
`README.md` and `CLAUDE.md` as you build.

## What to build

An MCP server that answers data questions only through MetricFlow metrics, and its indexer.
One image, two entrypoints: the server (default) and `indexer`.

### 1. The server — exactly `contracts/mcp/metrics-gateway.json`

- Official `mcp` Python SDK, streamable HTTP at `POST /mcp` on port 8080, **stateless with
  JSON responses** (`stateless_http=True, json_response=True` in FastMCP terms): a bare
  `tools/call` with no `initialize` and no session id must work. `GET /healthz` as the
  contract says — 200 with no release, `projects` filled as releases are served.
- Six tools, the input/output schemas and annotations in the contract, byte-for-byte in
  meaning. Every tool returns `structuredContent`; a refusal is `isError: true` with
  `structuredContent = {error: {code, message, candidates?}, audit_id, trace_id}`, never a
  JSON-RPC error. Arguments failing the input schema → `invalid_arguments`.
- CI diffs the live `tools/list` against the vendored contract and fails on any drift.

### 2. Engines — one MetricFlow worker process per project

- `METRICS_PROJECTS=olist,funnel`. For each, a worker **process** holding a
  `MetricFlowEngine` over the served bundle (extracted to a temp dir; `profiles.yml`
  target `serve`, which reads `OLIST_READER_*` / `TRINO_*` from env). Separate processes:
  dbt keeps adapter state per process, and each gets its own failure domain.
- Release polling every `METRICS_RELEASE_POLL_S` seconds: read
  `<project>/current.json` from `SEMANTIC_RELEASES_BUCKET`; on a new sha, download and verify
  the bundle (`release.json.files` sha256s), start a worker on it, swap it in, drain the old
  one. A query in flight never fails because of a swap. Missing bucket or object = no
  release yet, not a crash.
- Guards before anything reaches MetricFlow: metric, dimension, group_by and order_by
  names checked against the served manifest (unknown → the named error with close
  `candidates`); op allow-list `eq ne lt lte gt gte in not_in` (else
  `operator_not_allowed`); literals must be scalars and never contain `{` or `}` (else
  `literal_refused`), and are escaped when rendered into MetricFlow `where` filters;
  `limit ≤ 500`. A refusal runs no SQL.
- Time limit: `METRICS_ENGINE_TIMEOUT_S` (default 30); a call's `timeout_ms` can only
  tighten it. On expiry cancel the query (Postgres `pg_cancel_backend` / statement timeout,
  Trino query kill) and return `engine_timeout` within limit + 5 s — your own test
  asserts that bound.
- Readable definitions ("sum of item price over delivered orders", "gmv / order_count")
  are derived from the manifest, and are what `describe_metric.definition` and
  `query_result.definitions` return.

### 3. Search — hybrid, floored, pinned to the served sha

- Database `semantic_index` (pgvector). Tables as the proposal has them: `semantic_object`
  (project, sha, kind, name, parent, text, text_hash, embedding vector(384), tsv, payload,
  PK (project, sha, kind, name)), `dimension_value` (project, dimension, value, label,
  embedding, tsv, refreshed_at), `index_release` (project, sha, objects, ready_at),
  `audit.tool_call`. Migrations run by the indexer as `index_writer`; they grant
  `index_reader` SELECT on the index tables and INSERT-only on `audit.tool_call`. The
  server connects as `index_reader` (`INDEX_DATABASE_URL`).
- Embeddings: local ONNX `paraphrase-multilingual-MiniLM-L12-v2` (384-d), baked into the
  image, identical in server and indexer. No network at runtime.
- Query: top 50 by cosine + top 50 by `ts_rank` (configs `simple`, `portuguese`,
  `english`), reciprocal rank fusion, then the score floor, then `top_k`. Only rows of the
  served sha (dimension values: of dimensions that exist at the served sha). Below the
  floor → `no_match: true, hits: []`. Model/column docs are context for embedding text
  only, never a hit.
- The floor is a setting (`METRICS_SEARCH_FLOOR`), calibrated by your search eval:
  golden questions (`evals/search.yaml`: "revenue by state" → `gmv`, "health and beauty
  products" → value `health_beauty`, funnel questions → funnel metrics, ≥ 20 total) each
  find their object in the top 3, and off-topic ones ("Write a linked list in Python",
  "Tell me a joke about penguins", document/call-centre questions) are `no_match`.
  Report the score distributions in `docs/`.

### 4. The indexer — `indexer` entrypoint, the only writer of `current.json`

Per project: find the newest published `release.json` (by `published_at`) that is not
`current.json`'s sha (none → exit 0, nothing to do); embed its objects (diff: reuse an
embedding when `text_hash` exists under any earlier sha); refresh dimension values for
dimensions with `meta.index_values: true` via MetricFlow `get_dimension_values` (value plus
label, Portuguese and English); write `index_release`; **then** write `current.json`
(`indexed_at` now). Keep the last five releases' rows. `--values-only` refreshes values
for the current sha without flipping (the nightly CronJob). Connects as `index_writer`
(`INDEX_WRITER_DATABASE_URL`). Exit 0 · 1 failed · 2 refused (config).

### 5. Audit and telemetry

Every `tools/call`, refusals included, writes one `audit.tool_call` row before returning
and one span in Phoenix project `PHOENIX_PROJECT_NAME` (default `metrics-gateway`) named
`tools/call <tool>` with `mcp.tool`, `audit.id`, `audit.outcome`, `metrics.sha` — the
contract's `x-telemetry`. Honour an incoming `traceparent`. Export OTLP to
`PHOENIX_COLLECTOR_ENDPOINT`; fail open if Phoenix is down.

### 6. Compose

`docker-compose.yml` declares ONLY **`metrics-gateway`** (server; healthcheck on
`/healthz`) and **`indexer`** (same image, `profiles: ["manual"]`), by these names; it
names `postgres`, `minio`, `trino`, `phoenix` without defining them. The control repo
wires the env (below). No host bind mounts, no external volumes.

Environment: `METRICS_PROJECTS`, `SEMANTIC_RELEASES_BUCKET`, `METRICS_RELEASE_POLL_S`,
`S3_ENDPOINT_URL` (local only), `LAKE_S3_ACCESS_KEY_ID`/`LAKE_S3_SECRET_ACCESS_KEY` (S3
client only when set; else the default chain), `AWS_REGION`, `OLIST_DB_HOST/PORT/NAME`,
`OLIST_READER_USER/PASSWORD`, `TRINO_HOST/PORT/USER`, `INDEX_DATABASE_URL`,
`INDEX_WRITER_DATABASE_URL`, `PHOENIX_COLLECTOR_ENDPOINT`, `PHOENIX_PROJECT_NAME`,
`PHOENIX_API_KEY` (dev), `METRICS_ENGINE_TIMEOUT_S`, `METRICS_SEARCH_FLOOR`.

## Contract entries this depends on

- `contracts/mcp/metrics-gateway.json` — you are its producer.
- `contracts/releases/semantic-release.schema.json` — you consume releases and own `current.json`.
- `contracts/README.md` § "The metrics spoke".
- `contracts/infra-outputs.yaml` → `semantic_releases_bucket`, `metrics_gateway_url`,
  `metrics_db_secret_refs`.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and
report it rather than working around it.

## Verification

- [ ] `make check` real and green: lint, types, unit tests (guards, RRF, floor, swap with a
      query in flight, diff embedding, timeout bound), the `tools/list` contract diff, the
      search eval against a fixture manifest.
- [ ] docs describe the tools, the release swap, the indexer order, env and exit codes.

## Smoke — what this slice is actually judged on

Jobs: `the-indexer-indexes-and-flips`, `the-indexer-flips-to-fixture-metric-a` (exit 0).

Steps with `owner: metrics-gateway`, all against `POST /mcp` / `GET /healthz` on the
host port: the served sha is fixture A for both projects and B (published, never indexed)
is neither searchable nor queryable; `gmv` top-3 for "revenue by state"; `health_beauty`
found; off-topic `no_match`; `describe_metric` lists `customer__state`; `query_metrics`
returns SQL and sha; the three refusals with no SQL; the refusal's Phoenix span with
`audit.outcome = refused`; `timeout_ms: 1` → `engine_timeout`.

The assertions belong to the control repo: fix the cause, never the assertion.

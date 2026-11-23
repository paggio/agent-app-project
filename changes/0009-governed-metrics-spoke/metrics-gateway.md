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
contract's `x-telemetry`. Each span starts its OWN trace; an incoming `traceparent` becomes a span link and `caller.trace_id` (re-frozen: joining moved every chat trace into project `metrics-gateway`, because Phoenix files a trace under one project). Export OTLP to
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

## Amendment, 2026-11-23 — documentation (BRIEF criterion 15)

**Docs only. No code, behaviour, tool surface or contract changes. Nothing is removed.**

The user wants `docs/` to explain the whole mechanism to someone who has never seen
MetricFlow. Write it from the code as it stands, verify every claim against `src/`, and use
Olist/funnel examples (`gmv`, `customer__state`, `health_beauty`, `mql_to_deal_conversion`),
never invented ones. Diagrams: Mermaid (GitHub renders it) where it fits; the ASCII ones below
may stay ASCII. Keep `architecture.md` the module/config reference; put the explanation in a
new `docs/how-it-works.md`, linked from `README.md`, `CLAUDE.md` and `architecture.md`.

It must contain, explicitly:

1. **MetricFlow, as this repo uses it** — this diagram (the user's), then what our code does at
   each arrow: which files the bundle carries, `MetricFlowEngine` over `semantic_manifest.json`
   in a worker process, compile-only SQL client (`docs/adr/0001`), execution in `warehouse.py`.
   State which dbt version analytics-dbt pins and whether `osi_document.json` is produced/used.

   ```
   your dbt project                      dbt-core                  MetricFlow (Apache 2.0)
   ─────────────────                     ────────                  ───────────────────────
   models/*.sql        ┐
   semantic_models:    ├── dbt parse ──► target/semantic_manifest.json ──► semantic graph
   metrics:            │                 target/osi_document.json            │
   saved_queries:      ┘                 (dbt ≥1.12 also exports OSI)        ▼
                                                                request: metrics + group_by
                                                                         + where + grain
                                                                             │
                                                                             ▼
                                                                dataflow plan ──► SQL in the
                                                                target dialect (Redshift,
                                                                Trino, DuckDB, Snowflake, ...)
                                                                             │
                                                        dbt adapter (your profiles.yml) ──► rows
   ```

2. **The semantic index** — a table of every kind (metric; dimension/entity; saved query;
   model/column docs; dimension values): where it comes from (`semantic_manifest.json`,
   `manifest.json`, the warehouse via dimension-values queries), and the EXACT text embedded
   for each, quoted from `catalog.py`/`indexer.py` with a real Olist example. Say that
   model/column docs are context only, never a hit; which dimensions get values
   (`meta.index_values`) and which never do (identifiers, zip prefixes); embeddings (local
   ONNX MiniLM 384-d), hybrid search (cosine + `ts_rank` in simple/portuguese/english → RRF →
   floor → top_k), pinned to the served sha. Link `docs/search.md` for calibration.

3. **The tools, under the hood** — one diagram of the six, then per tool: purpose, inputs,
   the steps it takes (guards → catalog lookup → MetricFlow request → compiled SQL →
   warehouse → rows, or index query), what it returns, its refusals. E.g. `query_metrics`:
   names checked against the served catalog, op allow-list, literals escaped into a MetricFlow
   `where`, `start`/`end` as `metric_time` filters, the worker compiles the dataflow plan to
   dialect SQL, `warehouse.py` runs it under the deadline, the result carries SQL, sha and
   readable definitions. Plus the per-call span and audit row.

4. **The agent workflow it is designed for** — a sequence diagram: human question →
   `search_semantic` → a metric / dimension / value / saved query → the agent reasons
   (`describe_metric` for valid group-bys, `get_dimension_values` to resolve a literal) →
   `query_metrics` or `run_saved_query` → rows with definition and sha → cited answer. Then
   how chatbot-backend's metrics spoke actually uses it (deterministic first pass under
   `CHAT_MODEL=echo`, tool-calling with a capable model) — describe only from the contract
   and `contracts/README.md` § "The metrics spoke", not another repo's internals.

5. **Releases, CI/CD** — this diagram (the user's ideal), then what is built today and where
   it differs: analytics-dbt's release job (load → `dbt build` → `mf validate-configs` →
   `bundle.tar.gz`, `release.json` LAST under `<project>/<sha>/`), the indexer the only writer
   of `current.json` (index first, flip second — so "gateway reload" happens AFTER the
   indexer, not in parallel), the gateway polling and swapping with a query in flight. On dev
   the release and the indexer run as post-install/upgrade hook Jobs at deploy, with
   `RELEASE_SHA` = analytics-dbt's image sha; there is no merge-triggered prod dbt job and
   no prod (BRIEF out of scope). PR-time CI uses the local topology.

   ```
     PR ─► CI ─────────────────► merge ─► prod dbt job ──► publish artifacts ──┬─► gateway reload
           dbt parse                       dbt build        s3://semantic/      └─► indexer (re-embed diffs)
           mf validate-configs             (tables first!)  referrals/<sha>/...
           dbt build (CI schema)                            + pointer "current"
           explain/run saved queries
   ```

Concise: diagrams and short prose, no padding. The repo's docs gate must pass.

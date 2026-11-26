# 0009 — Governed metrics spoke

## Why

The assistant cannot answer a data question ("GMV by state in 2018 Q1?") at all, and an
agent that writes its own SQL answers it with numbers nobody can audit. This adds a fourth
spoke that answers only from MetricFlow metrics defined in dbt — over Olist in Postgres and
the Olist marketing funnel in Iceberg via Trino — with every number carrying its definition
and the release that produced it.

Source: the reviewed proposal `tmp/governed-metrics-spoke.html` (2026-11-17), with its
D1–D6 recommendations accepted: Trino; route between two projects, never federate; the
marketing funnel in Iceberg; Glue on dev, Iceberg REST + MinIO locally; two new repos; two
databases on the existing RDS. Two departures, both decided with the user:

- **Data is a committed, deterministic slice** of the public Kaggle datasets (CC BY-NC-SA
  4.0, attributed in analytics-dbt), the same locally, in CI and on dev. No credentials.
- **chatbot-eval stays a black-box API client** (docs/adr/0013). It measures routing over
  four routes and metric-citation recall through the API; search recall@3 against the
  gateway lives in analytics-dbt's CI search eval and in this suite's gateway steps.

## Design

- **analytics-dbt** (new): two dbt projects, `olist` (dbt-postgres) and `funnel`
  (dbt-trino, Iceberg catalog `lake`), with semantic models, metrics and saved queries; the
  loaders; and one image whose release job loads, builds, then publishes each project's
  bundle (`contracts/releases/`).
- **metrics-gateway** (new): MCP server (`contracts/mcp/metrics-gateway.json`), one
  MetricFlow worker process per project, hybrid search (pgvector + full-text, RRF, floor)
  over `semantic_index`, audit, release polling with worker swap. The indexer is a second
  entrypoint of the same image and the only writer of `current.json`.
- **Release order**: dbt build → publish `<sha>/` → index → flip `current.json` → gateway
  swaps. Search and engine always serve the same sha.
- **chatbot-backend**: a `metrics` spoke and route. The spoke runs a deterministic first
  pass — search, pick the metric, dimensions, value filters and time window from the hits,
  query — so a metrics turn cites a governed result even under `CHAT_MODEL=echo`; with a
  tool-capable model the answering agent additionally gets the gateway's tools, and every
  further query it runs is cited too. The heuristic coordinator routes to `metrics` when
  `search_semantic(kinds=[metric, saved_query])` clears the floor (after the calls check,
  before documents). Gateway down or no release: `metrics` is not chosen; never a 5xx.
- **dev**: Trino (coordinator + one worker, Spot) on EKS; Glue + S3 warehouse; releases
  bucket; `olist` and `semantic_index` on the existing RDS with four roles; the release Job
  and the indexer Job run by the deploy (Helm hooks, in that order) so `deploy` returns with
  a release served; a nightly CronJob refreshes dimension values; NetworkPolicies admit
  only the backend to the gateway.

## Acceptance criteria (these are the oracle)

Local-only criteria are marked (L): the gateway has no origin on dev.

1. (L) The gateway serves the sha `current.json` names, for both projects, and every
   search hit carries it.
2. (L) A release adding a metric makes it searchable and queryable together; a published
   release that has not been indexed is neither, and is not served.
3. (L) `search_semantic("revenue by state")` ranks metric `gmv` in the top three; "health
   and beauty products" finds the value `health_beauty`.
4. (L) "Write a linked list in Python" returns `no_match` with no hits.
5. (L) `query_metrics(gmv by customer__state)` returns 27 rows with its SQL and sha; the
   per-state values sum to the mart's item total (analytics-dbt's own dbt test).
6. (L) An unknown dimension, a disallowed operator, and `{` in a value are each refused
   with their named error code; no SQL is returned; the refusal is a span with
   `audit.outcome = refused`.
7. (L) `mql_to_deal_conversion` by origin computes through Trino over Iceberg; every value
   is in [0, 1] (analytics-dbt's own dbt test).
8. (L) A query whose budget is below the engine time is refused `engine_timeout`; the
   limit + 5 s bound is the gateway's own test.
9. (L) Identifiers and zip prefixes are never indexed: `get_dimension_values` on
   `customer__zip_code_prefix` is refused `values_not_indexed`.
10. "What was GMV in SP in 2017?" routes to `metrics`; the message carries
    `metric_citations[0]` with `project: olist`, `metric: gmv`, a 40-hex `sha` (locally, the
    served one), the filter on SP and the 2017 window, and a one-row result.
11. Off-topic and coding questions do not route to `metrics`.
12. The eval's question set covers all four routes; the run meets its routing and recall
    thresholds, and an impossible threshold exits 1.
13. A metric citation renders in the browser: metric label, definition, sha (short), and
    the result as a table (frontend's Playwright suite against the joined origin).
14. On dev, the deployed spoke answers criterion 10 end to end; the gateway is reachable
    only from the backend pods (infra's chart test asserts the NetworkPolicy).
15. (Amended 2026-11-23) metrics-gateway's docs explain the whole mechanism to a reader who
    has never seen MetricFlow: the dbt → semantic manifest → MetricFlow → SQL → rows pipeline,
    every kind of semantic object and the exact text embedded for it, each tool and what it
    does under the hood, the agent workflow it is designed for, and the release CI/CD flow —
    each as a diagram plus prose, with the ideal flow and what is built today told apart.
    No smoke step: a document is reviewed, not asserted; the slice's docs gate and the PR
    review are its oracle.

## Out of scope

- Per-user OAuth, row-level security — metrics are organisation data, as calls are.
- A raw-SQL tool, any write tool — the governance is the point.
- Cross-source metrics — D2 chose routing.
- The full Kaggle datasets — a slice proves every metric type; the full set is a data load,
  not a design change.
- Materialised saved-query exports, BI tools, streaming ingestion, production.
- The eval calling the gateway directly — it would reverse docs/adr/0013.
- PR-time dbt CI against `dev` — runners cannot reach the VPC; CI uses local topology.

## Contract changes

All additive, frozen in `86700da`:

- `openapi.yaml` 1.8.0: `Message.route` gains `metrics`; `Message.metric_citations`
  (`MetricCitation`, `MetricResult`).
- `mcp/metrics-gateway.json` (new): six tools, errors, telemetry, `/healthz`.
- `releases/semantic-release.schema.json` (new): bucket layout, `release.json`, `current.json`.
- `infra-outputs.yaml`: dbt and gateway registries and deployed images, both buckets, the
  Glue database, the gateway URL, the DB secret prefix.
- `README.md` § "The metrics spoke".

## Deployment

- Local: `./scripts/iterate.sh 0009-governed-metrics-spoke`. Seven jobs run before smoke
  (`change.yaml`): three releases and two index runs, then the eval twice.
- Infra deploy: yes — Trino, Glue, the buckets, the Jobs and the gateway exist only on dev.
  Requires, by a human, before `/dev-push`: `make dev-bootstrap` (two new ECR repos) and
  harness PR #43 merged (it passes every image to `plan`/`deploy`).

## Slices

- `analytics-dbt.md`, `metrics-gateway.md` (both new repos)
- `chatbot-backend.md`, `chatbot-eval.md`, `frontend.md`, `infra.md`

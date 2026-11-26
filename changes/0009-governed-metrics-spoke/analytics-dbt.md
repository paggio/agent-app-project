# 0009 — analytics-dbt slice

This repo is new: it starts from the scaffold. Choose the toolchain (Python 3.13, uv), make
`make check` real (it refuses until you do), and fill `docs/architecture.md`, `README.md`
and `CLAUDE.md` as you build.

## What to build

Governed metrics as code: two dbt projects with MetricFlow semantic layers, the loaders that
feed them, and one image whose release job loads, builds and publishes.

### 1. Data — a committed, deterministic slice

- Source: the public Kaggle datasets, downloadable without credentials:
  `https://www.kaggle.com/api/v1/datasets/download/olistbr/brazilian-ecommerce` and
  `.../olistbr/marketing-funnel-olist` (zip). License CC BY-NC-SA 4.0: attribute both in
  `data/README.md` and `README.md`.
- `scripts/make-slice.py` (committed, re-runnable, seeded): from the e-commerce set keep a
  stratified sample of ~8,000 orders that **contains every one of the 27 `customer_state`
  values** and every product category, with all their items, payments, reviews, customers,
  sellers and products; the category translation table whole. Drop `geolocation` (zip
  prefixes are not needed and must not be indexed). The two funnel files are small: keep
  them whole. Output CSVs under `data/` (target < 15 MB total), committed.
- Loaders, idempotent (a re-run on a loaded database changes nothing):
  - Olist → Postgres database `olist`, schema `raw`, via `COPY`.
  - Funnel → Iceberg namespace `funnel` (`ICEBERG_NAMESPACE`) with **PyIceberg**, not
    through Trino. Catalog by `ICEBERG_CATALOG_TYPE`: `rest` (`ICEBERG_REST_URI`, local and
    CI) or `glue` (`GLUE_DATABASE`, dev). Warehouse `ICEBERG_WAREHOUSE`.

### 2. Two dbt projects

`projects/olist` (dbt-postgres) and `projects/funnel` (dbt-trino; Trino catalog named
**`lake`** in every environment). Staging → marts → semantic models. dbt-core 1.10+ and
`dbt-metricflow`; pin exact versions.

Initial catalog (a starting set that exercises every metric type):

| Project | Semantic models | Metrics | Saved queries |
| --- | --- | --- | --- |
| olist | orders, order_items, customers, sellers, products (English category), payments, reviews | simple: `order_count`, `gmv`, `freight_value` · ratio: `avg_order_value`, `freight_ratio`, `late_delivery_rate`, `cancellation_rate` · derived: `gmv_mom_growth` · cumulative: `gmv_rolling_30d` · `avg_review_score` | `monthly_gmv_by_state`, `category_performance_monthly` |
| funnel | mql (marketing-qualified leads), closed deals | simple: `mql_count`, `closed_deal_count` · conversion: `mql_to_deal_conversion` · `declared_monthly_revenue` | `monthly_conversion_by_origin` |

Names the gateway and the smoke suite depend on — exactly these:

- entity `customer` keyed on **`customer_unique_id`** (not the per-order `customer_id`),
  with dimensions `state`, `city`, `zip_code_prefix`; `gmv` must accept group-by
  `customer__state` (carry `customer_unique_id` on the item mart so the join is one hop).
- `product__category` — the English category name (`health_beauty`), with Portuguese
  original in its description/label.
- funnel: `mql__origin`; `mql_to_deal_conversion` by origin.
- `gmv` = sum of item price over orders not cancelled/unavailable; its description must say
  "revenue" and "gross merchandise value".
- A seller's review score counts only single-seller orders (model it in the semantic
  model, not in prose).

Rules:

- **Every metric, dimension, entity and saved query has a description**; `make check`
  fails otherwise. The index can only find what is described.
- `meta: {index_values: true}` on low-cardinality dimensions only: `customer__state`,
  `product__category`, order status, payment type, `mql__origin`. Never on ids, zip
  prefixes or free text (review comments).
- dbt tests: the per-state `gmv` sum equals the mart's item total; every
  `mql_to_deal_conversion` value is in [0, 1]; plus not_null/unique on keys.
- `DBT_FIXTURE_METRICS` (comma list of `a`, `b`; empty by default) adds the fixture metrics
  `fixture_order_count_a` / `fixture_order_count_b` to `olist` — simple order counts whose
  descriptions are "Fixture metric A (B): orders counted for the release ordering check."
  They exist only to prove release ordering; document that.

### 3. The release job — the image's default command

Per project, in order: load (idempotent) → `dbt build --target build` → `mf validate-configs`
→ publish. Publish exactly as `contracts/releases/semantic-release.schema.json` says:
`<project>/<RELEASE_SHA>/bundle.tar.gz`, then `release.json` LAST, to
`SEMANTIC_RELEASES_BUCKET`. Never write `current.json`. A sha whose `release.json` exists
is left untouched and the job still succeeds. `RELEASE_SHA` is required (40 hex) — exit 2
naming it when unset; never derive one.

`profiles.yml` reads every credential from env vars and has targets `build` (writer) and
`serve` (reader: `OLIST_READER_*`, Trino user `metrics_gateway`), which is what the gateway
uses from the bundle.

Environment (all set by the stack locally and by infra on dev):
`RELEASE_SHA`, `DBT_FIXTURE_METRICS`, `OLIST_DB_HOST/PORT/NAME`,
`OLIST_WRITER_USER/PASSWORD`, `OLIST_READER_USER/PASSWORD` (written into `profiles.yml`
as env references only), `TRINO_HOST/PORT/USER`, `ICEBERG_*`, `GLUE_DATABASE`,
`SEMANTIC_RELEASES_BUCKET`, `S3_ENDPOINT_URL` (local only), `LAKE_S3_ACCESS_KEY_ID` /
`LAKE_S3_SECRET_ACCESS_KEY` (when set, used for S3 and PyIceberg only; otherwise the
default AWS chain — pod identity on dev), `AWS_REGION`, `LAKE_CREATE_BUCKETS` (`true` locally:
create `semantic-releases` and `iceberg-warehouse` when absent; never on dev).

Exit 0 published · 1 a build, test or validation failed · 2 refused (missing config).

### 4. Compose and CI

- `docker-compose.yml` declares ONLY these services, by these names (the control repo
  includes this file and couples on them): **`trino`** (`trinodb/trino`, pinned; JVM heap
  ≤ 1 GB; catalog `lake` = Iceberg REST at `http://iceberg-rest:8181`, S3 at
  `http://minio:9000`, path-style, `minioadmin`/`minioadmin`; healthcheck), **`iceberg-rest`**
  (`apache/iceberg-rest-fixture`, pinned; warehouse `s3://iceberg-warehouse/` on
  `http://minio:9000`; healthcheck), **`dbt-release`** (this image, `profiles: ["manual"]`).
  It names `postgres` and `minio` without defining them. No host bind mounts, no external
  volumes. A separate `compose.dev.yml` may add postgres/minio for standalone work.
- CI (`.github/workflows/ci.yml`): `make check` = lint, `dbt parse` both projects, the
  description check, then against a compose topology (Postgres, Trino, Iceberg REST,
  MinIO) `dbt build` + `mf validate-configs` + run every saved query. A search eval is
  metrics-gateway's, not yours.

## Contract entries this depends on

- `contracts/releases/semantic-release.schema.json` — you are its producer.
- `contracts/mcp/metrics-gateway.json` — the names your semantic layer exposes are what its
  tools accept; read it so your names fit (`customer__state`, `metric_time__month`).
- `contracts/infra-outputs.yaml` → `semantic_releases_bucket`, `iceberg_warehouse_bucket`,
  `glue_database`, `metrics_db_secret_refs`.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and
report it rather than working around it.

## Verification

- [ ] `make check` real and green; CI workflow runs it.
- [ ] the slice script is deterministic (same seed → byte-identical CSVs) and keeps 27 states.
- [ ] a second run of the release job on the same sha exits 0 and changes nothing.
- [ ] `docs/architecture.md`, `README.md`, `CLAUDE.md` describe the projects, the release
      job, its env and exit codes.

## Smoke — what this slice is actually judged on

Jobs (`change.yaml`): `the-release-job-loads-builds-and-publishes`,
`a-release-adding-fixture-metric-a-publishes` (`RELEASE_SHA=a1a1…`, `DBT_FIXTURE_METRICS=a`),
`a-release-adding-fixture-metric-b-publishes-unindexed` (`b2b2…`, `a,b`) — each exit 0.

Steps with `owner: analytics-dbt`, asserted through the gateway's MCP endpoint:
`gmv-by-state-has-a-row-for-each-of-the-27-federative-units`,
`funnel-conversion-computes-through-trino-over-iceberg` (SQL names catalog `lake`),
`zip-prefixes-are-never-indexed`.

The assertions belong to the control repo: fix the cause, never the assertion.

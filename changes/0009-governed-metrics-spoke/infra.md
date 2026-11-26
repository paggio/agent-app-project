# 0009 — infra slice

## What to build

Run the metrics spoke on `dev`: Trino over Iceberg (Glue + S3), the releases bucket, two
databases on the existing RDS, the release and indexer Jobs, and the gateway — reachable
only from the backend.

### 1. Images and the deploy interface

- `bootstrap/`: ECR repositories `analytics-dbt` and `metrics-gateway` (IMMUTABLE, like the
  others); `registries` prints `dbt_image_repository` and `gateway_image_repository`.
  This needs a bootstrap re-apply, by a human — say so in the docs.
- `plan`/`deploy` accept `DBT_IMAGE` and `GATEWAY_IMAGE` beside the existing three (the
  control repo now passes one `<IMAGE>_IMAGE` per image in `.gitmodules`). Unset → exit 2.
- `outputs`: every new key in `contracts/infra-outputs.yaml` — `deployed_dbt_image` from
  the release Job the deploy ran, `deployed_gateway_image` from the Deployment.

### 2. Data plane (Terraform)

- S3: `agentapp-<env>-semantic-releases` and `agentapp-<env>-iceberg-warehouse`
  (versioning off, SSE, public access blocked, `force_destroy` so `destroy` leaves nothing).
- Glue database `agentapp_<env>_funnel`.
- Secrets Manager under `agentapp/<env>/metrics/`: `olist-writer`, `olist-reader`,
  `index-writer`, `index-reader` — random passwords, synced by External Secrets.
- RDS: unchanged instance. A Helm hook Job (copy the `phoenix-db` pattern, idempotent)
  creates databases `olist` and `semantic_index`, the four roles with those passwords,
  `CREATE EXTENSION vector` in `semantic_index`, `olist_reader` with
  `statement_timeout = '30s'` and default SELECT grants on what `olist_writer` creates,
  `CONNECT` for the readers. Must run before the release and indexer Jobs.

### 3. Trino

- `trinodb/trino` Helm chart (pinned), coordinator + 1 worker, on the Spot node group;
  heap sized to fit. Catalog **`lake`**: Iceberg connector, Glue catalog
  (`agentapp_<env>_funnel`), S3 warehouse via pod identity. A resource group with
  `query_max_run_time` (60 s) for user `metrics_gateway`; `dbt` unrestricted.
- Node group: grow it so Trino, the gateway and the existing workloads fit (e.g. max 4,
  desired 3, or a larger instance type) — record the cost delta in `docs/`.

### 4. Workloads (chart `charts/agentapp/`)

- **Release Job** (`DBT_IMAGE`), post-install/post-upgrade hook after the DB job:
  `RELEASE_SHA` = the image tag (the analytics-dbt commit), `DBT_FIXTURE_METRICS` unset,
  `ICEBERG_CATALOG_TYPE=glue`, `GLUE_DATABASE`, `ICEBERG_WAREHOUSE=s3://<warehouse>/`,
  `ICEBERG_NAMESPACE=funnel`, `SEMANTIC_RELEASES_BUCKET`, `OLIST_DB_*` (RDS endpoint,
  `olist`), `OLIST_WRITER_*` and `OLIST_READER_*` from the secrets, `TRINO_HOST/PORT`,
  `TRINO_USER=dbt`, `AWS_REGION`. No `S3_ENDPOINT_URL`, no `LAKE_*` keys,
  `LAKE_CREATE_BUCKETS` unset. Pod identity: S3 read/write on both buckets, Glue
  read/write on the database and its tables. Generous `activeDeadlineSeconds` (30 min).
- **Indexer Job** (`GATEWAY_IMAGE`, args `indexer`), hook after the release Job:
  `INDEX_WRITER_DATABASE_URL`, the gateway's env below. Pod identity: S3 read on releases,
  write on `*/current.json`.
- **Nightly CronJob**: the indexer with `--values-only`.
- **metrics-gateway Deployment** (1 replica) + Service `metrics-gateway:8080`:
  `METRICS_PROJECTS=olist,funnel`, `SEMANTIC_RELEASES_BUCKET`, `METRICS_RELEASE_POLL_S=30`,
  `OLIST_DB_*`, `OLIST_READER_*`, `TRINO_HOST/PORT`, `TRINO_USER=metrics_gateway`,
  `INDEX_DATABASE_URL` (index-reader), `PHOENIX_COLLECTOR_ENDPOINT`, `PHOENIX_API_KEY`,
  `PHOENIX_PROJECT_NAME=metrics-gateway`, `AWS_REGION`. HTTP probes on `/healthz` (it is
  200 before any release). Pod identity: S3 read on releases. `enableServiceLinks: false`,
  OpenTelemetry injection off, like every chart pod.
- **backend**: `METRICS_GATEWAY_URL=http://metrics-gateway:8080/mcp`.
- `deploy` returns only after the hooks completed and the gateway is Ready; a failed hook
  leaves its evidence (logs, describe) before rollback, as today.

### 5. NetworkPolicies

- Ingress to `metrics-gateway:8080`: **only** pods of the backend Deployment. Not the call
  worker, not the simulator, not the ALB, not Trino.
- Ingress to Trino: only the gateway, the release Job and the indexer.
- Egress needs of each (RDS, S3 via the gateway endpoint, Glue via NAT, Phoenix) work.
- A chart test (`helm template` + assertions, in `make test`) fails if any policy admits
  another source to the gateway.

## Contract entries this depends on

- `contracts/infra-outputs.yaml` → `dbt_image_repository`, `deployed_dbt_image`,
  `gateway_image_repository`, `deployed_gateway_image`, `semantic_releases_bucket`,
  `iceberg_warehouse_bucket`, `glue_database`, `metrics_gateway_url`,
  `metrics_db_secret_refs`.
- `contracts/releases/semantic-release.schema.json` (bucket layout, who writes what).
- `contracts/mcp/metrics-gateway.json` → `x-transport` (port, no auth).

The contracts are FROZEN. If this slice appears to require a contract change, STOP and
report it rather than working around it.

## Verification

- [ ] `fmt`, `validate`, `lint` green; `plan` without the new image args exits 2.
- [ ] the NetworkPolicy chart test.
- [ ] `docs/architecture.md`: module map, request and release lifecycle, IAM per workload,
      policies, the bootstrap re-apply, the cost delta.
- [ ] the repo's own gates pass.

## Smoke — what this slice is actually judged on

`the-deployed-spoke-cites-gmv` (remote): "What was GMV in SP in 2017?" through CloudFront
routes to `metrics` and cites `gmv` with a 40-hex sha and a one-row result — the DB job,
release Job, indexer, Trino, gateway, IAM and backend→gateway policy must all be right.
Spell out IAM and probes exactly: the last change lost three remote rounds to a missing
permission and a probe shape.

The assertions belong to the control repo: fix the cause, never the assertion.

## Remote failure — /dev-push run 44489795903

`helm upgrade --install` failed at the pre-install hook `Job/metrics-db` (BackoffLimitExceeded)
on a fresh RDS 17.9. The RDS log, every retry:

    agentapp@postgres: ERROR:  must be able to SET ROLE "olist_writer"

`SET createrole_self_grant` did not give the RDS master SET on the roles, so
`CREATE DATABASE … OWNER olist_writer` and `ALTER DEFAULT PRIVILEGES FOR ROLE olist_writer`
fail. Grant the master membership explicitly (it holds ADMIN on roles it created; idempotent
on re-runs, roles may already exist), e.g. `GRANT olist_writer, index_writer TO CURRENT_USER
WITH SET TRUE, INHERIT FALSE`, before those statements. Your job tests must cover a
non-superuser CREATEROLE admin, which is what RDS is — a superuser hides this.

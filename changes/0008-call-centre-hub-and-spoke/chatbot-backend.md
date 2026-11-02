# 0008 — chatbot-backend slice

> **Amended 2026-11-02 (`/ship-iterate`)** — your branch already implements §1–4 and the
> correction at the end. Do the new § "Amended, 2026-11-02" at the bottom. Nothing is
> removed.

## What to build

### 1. The call pipeline — a second and third entrypoint of this image

- **Worker** (`python -m app.calls.worker`, its own module tree `src/app/calls/`): long-polls
  `CALL_QUEUE_URL`, validates each body against the vendored
  `contracts/events/call-completed.v1.schema.json`, and indexes the call.
  - Idempotent on `call_id`: a redelivery or a later event for the same id replaces the
    stored copy — one call, never two.
  - Retention `CALL_RETENTION_DAYS` (default 7) from `ended_at`, in every copy you keep. An
    event already past it is refused at ingest; an hourly sweep removes calls that age out.
    Make the clock injectable so tests prove the sweep.
  - Refused events (schema-invalid, unmasked phone, past retention) go straight to
    `CALL_DEAD_LETTER_QUEUE_URL` and are deleted from the main queue. Transient failures are
    left for SQS redrive (`maxReceiveCount` 3). Log every refusal with `call_id` and reason.
  - A system of record plus a derived index, as documents have (your ADR 0008): e.g. a
    postgres `calls` table and an OpenSearch calls index of transcript chunks embedded with
    the **same injected embedder**, metadata on every chunk for filtering. Your choice; state
    it in an ADR. Volume to design for: ~10k live calls, ~80k chunks — use the `knn_vector`
    field / ANN with metadata pre-filtering rather than brute-force cosine.
  - Creates its queues if absent — **`GetQueueUrl` first, `CreateQueue` only on
    `QueueDoesNotExist`** (locally ElasticMQ; on dev they exist and `GetQueueUrl` succeeds).
    The worker only. **The simulator never creates a queue** and calls nothing but
    `GetQueueUrl` and `SendMessage`: on dev its role allows exactly those, and an
    `AccessDenied` on `CreateQueue` left it retrying forever, publishing nothing. Queue credentials and endpoint come from `Settings`, the way the S3 client's
    do — locally ElasticMQ takes any key; on dev, pod identity (default chain).
  - A healthcheck the stack can wait on (`call-worker` is `service_healthy` for the eval).
  - Traces to Phoenix under your project, one span per message processed.
- **Simulator** (`python -m app.calls.simulator`): publishes one valid event at start and
  every `CALL_SIMULATOR_INTERVAL_S` (default 60). Templated and seeded — no model call, no
  cost — with plausible variety across queues (`billing`, `technical_support`, `sales`,
  `cancellations`, `general`; round-robin so every queue appears within five calls), agents,
  outcomes, 6–14 turns. Ids `CALL-<yyyymmdd><6-digit sequence>`; `ended_at` = publish time;
  phones always masked. It is a dev fixture standing in for a call centre: keep it in its
  own module and never import it from the API or the graph.
- **Compose**: add `elasticmq` (`softwaremill/elasticmq-native:1.6.11`, host port 9324, queues
  `calls` and `calls-dlq` reachable at `/000000000000/calls[-dlq]`), `call-worker`,
  `call-simulator` — those exact service names, the control repo's stack labels them. Named
  volumes only, no bind mounts. The worker gets the same `EMBEDDING_MODEL` and datastore
  configuration as `backend`.

### 2. The API

`GET /v1/calls` (newest `ended_at` first, cap 50, metadata only) and
`GET /v1/calls/{call_id}` (with transcript), both behind `require_session`, organisation-wide
(not scoped by account — the first resource that is not; say so in `docs/architecture.md`).
`404 CALL_NOT_FOUND` for unknown, expired, refused or malformed ids alike. No phone field in
any response.

### 3. The graph: hub and spoke

Replace `route_query`'s yes/no with a **coordinator** that picks exactly one spoke:

- `documents` — today's `retrieve` → `answer` path, unchanged in behaviour.
- `calls` — searches calls: an exact `CALL-…` id in the message is a direct lookup and is
  cited first; otherwise metadata filters parsed from the message (queue names, agent id,
  "today"/"yesterday"/"last N days", outcome) narrow a hybrid search. At most one citation
  per call. Inject numbered extracts as `documents` does.
- `general` — `answer` with no retrieval.

Heuristic coordinator (`RETRIEVAL_ROUTER=heuristic`, CI): a call id or call vocabulary
("call", "calls", "caller", "call centre/center", "transcript", a known queue name used with
"call") → `calls`; else manifest overlap → `documents`; else `general`. **The current message
only** — history must not drag a joke into the calls spoke. `llm` mode: one call, one word of
three. Retriever protocols stay account-free in `graph/`; binding happens in
`main.build_replier` as today (calls need no account binding, documents still do).

Persist on the assistant message: `route`, `call_citations` (marker, call_id, started_at,
queue, agent_name snapshot, snippet). `retrieval_consulted` is `true` exactly when
`route == documents`. `POST /v1/chat` stays stateless and routes nothing. Under `echo` the
reply text echoes, routing and citations are still deterministic.

### 4. Documentation, skills, agents

- Update `docs/architecture.md` (module map, the worker and simulator lifecycles, calls as
  org data, known gaps), `docs/graph.md` (the coordinator and three spokes, state table),
  `README.md`, `CLAUDE.md`; ADRs for the call record/index and for the coordinator.
- Replace `.claude/skills/example-skill` and `.claude/agents/example-agent.md` (and the
  example rule) with real ones, e.g. a skill `add-a-graph-spoke` (the checklist: node,
  coordinator rule, state keys, persisted fields, `docs/graph.md`, tests) and an agent
  `graph-reviewer` that checks a diff against `docs/graph.md` and the boundaries table.
- Make this repo's gate fail when `src/` or `migrations/` changed against `origin/main` and
  none of `docs/`, `README.md`, `CLAUDE.md` did.

## Contract entries this depends on

- `contracts/events/call-completed.v1.schema.json` → the whole event.
- `contracts/openapi.yaml` → `listCalls`, `getCall`, `Call*` schemas, `Message.route`,
  `Message.call_citations`, `CALL_NOT_FOUND`.
- `contracts/README.md` → § "Call-centre calls", § "The coordinator and its spokes" (the
  control repo's copy; read it from the frozen tree you were given).

The contracts are FROZEN. If this slice appears to require a contract change, STOP and report
it rather than working around it.

## Verification

- [ ] unit: schema validation and refusal reasons; idempotent upsert; retention refusal and
      the sweep with an injected clock; DLQ routing; the simulator's events validate against
      the schema and are deterministic per seed; coordinator decisions for each rule; the
      calls spoke's id lookup and filters; `route`/`call_citations` persisted and read back.
- [ ] `make contract` green against the vendored 1.7.0.
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`), including the new docs check.

## Smoke — what this slice is actually judged on

Every step in `smoke.yaml` with `owner: chatbot-backend` — ingest through ElasticMQ, both
calls endpoints, the simulator's output, the five coordinator steps and the stored routes.
The baseline's `a-question-about-the-document-is-answered-with-one-citation` must still pass.
A failure comes back with the request, the response and your container log. The assertions
belong to the control repo: fix the cause, never the assertion.

## Notes

- `BACKEND_IMAGE_TAG` is bumped to `local-0.1.0` in the control repo; nothing to do here.
- Every new `Settings` field has a default that works in your own `make up`.

## Corrected, 2026-10-23 — after the remote pass

Two defects found after `verified`, both this repo's:

1. **`.claude/hooks/gate.sh` is broken on this branch.** Commit `3e6f6d3` pasted the docs-check
   block over each `exit 0`; the hook now `exit 0`s at line 16 before ruff, mypy or pytest run.
   Restore the hook from `origin/main` and add the docs check ONCE, after the existing gates.
   Then run the restored hook by hand and fix whatever it reports.
2. **CI `integration` is red: `minio/minio` no longer exists on Docker Hub** ("pull access
   denied ... repository does not exist"). Pin a pullable MinIO image (e.g.
   `quay.io/minio/minio` at a fixed tag) in `docker-compose.yml` and anywhere CI names it,
   keeping the service name `minio`. CI must be green on the PR.
   **Decided 2026-10-23 (user): `cgr.dev/chainguard/minio@sha256:d88920d6a50bd0b088223b688be3b76c63e6205dbe494437f67ba1240ea12880`** — both upstream
   MinIO registries are gone. Same server; check its entrypoint/healthcheck differences
   (no shell, no `curl`), record the choice and the manual-update cost in an ADR.

## Amended, 2026-11-02 — Phoenix tags and a generated graph diagram

Criteria 21–24. Today every root span shows kind `unknown` in Phoenix, and one `call.ingest`
trace a minute buries the conversations. Make them filterable. Nothing is removed.

1. **The worker's own project.** New setting `PHOENIX_CALLS_PROJECT_NAME`, default
   `chatbot-backend-calls`; `app.calls.worker` registers its tracer under it, not
   `PHOENIX_PROJECT_NAME`. Add it to the `call-worker` environment in `docker-compose.yml`
   as `${PHOENIX_CALLS_PROJECT_NAME:-chatbot-backend-calls}`. The API keeps
   `chatbot-backend`. Every `call.ingest` span: `openinference.span.kind` = `CHAIN`, tag
   `call-ingest` (OpenInference `tag.tags`).
2. **Root spans of the API.** Every root HTTP span gets `tag.tags` containing `api`. The root
   span of `POST /v1/threads/{thread_id}/messages` additionally gets
   `openinference.span.kind` = `CHAIN`, tags `conversation` and `route:<route>`, and
   OpenInference `metadata` `{"route": "<route>"}` — the route the turn was answered by,
   known only after the graph ran, so set it on the root span before the response ends
   (`core/telemetry.py` already explains why a span ended before `http.response.start`
   discards attributes). `POST /v1/chat`: `api` only. Phoenix returns these flattened —
   `tag.tags`, `metadata.route` — and the smoke reads exactly those keys.
3. **The graph diagram from the code.** A script (and `make graph`) writes the Mermaid
   output of the compiled turn graph (`get_graph().draw_mermaid()`, built with stub
   dependencies, no network) between markers in `docs/graph.md`, as a ```mermaid block
   GitHub renders. Keep the ASCII sketch or replace it — one picture, not two disagreeing.
   A unit test regenerates it and fails when the committed block differs.
4. **Docs**: `docs/architecture.md` (the two Phoenix projects, the tags and how to filter on
   them), `README.md`, `CLAUDE.md` (`make graph`), and the add-a-graph-spoke skill (re-run
   `make graph`).

Verification: unit tests for the tags on each kind of root span and the worker's project,
the diagram test, `make contract`, the repo's gate. Smoke: the four new Phoenix steps in
`smoke.yaml` (`a-chat-turn-is-a-tagged-conversation`, `a-non-chat-request-is-tagged-api-only`,
`call-ingestion-traces-go-to-their-own-project`, `no-call-ingestion-trace-in-the-chat-project`).
Infra sets nothing for this: on dev the default names the calls project.

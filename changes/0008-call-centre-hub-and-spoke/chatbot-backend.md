# 0008 — chatbot-backend slice

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
  - Creates its queues if absent (locally ElasticMQ; on dev they exist and `GetQueueUrl`
    succeeds). Queue credentials and endpoint come from `Settings`, the way the S3 client's
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

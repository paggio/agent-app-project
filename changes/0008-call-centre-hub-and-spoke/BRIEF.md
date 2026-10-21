# 0008 — Call-centre calls, a hub-and-spoke graph, and the eval over both

## Why

The assistant can only search a person's own uploaded documents. A support organisation also
needs it to answer from what was said on its calls — "what happened on CALL-…", "summarise
today's billing calls". That needs three things the system lacks: an ingest path for call
transcripts, a graph that picks the right source per question, and an eval that measures the
choice. The dev environment also has no standing login, so trying it needs a fresh signup
and a password read out of Secrets Manager each time.

## Design, as decided (2026-10-21)

- **Producer → SQS → backend worker → OpenSearch.** One `CallCompleted v1` event per call
  (`contracts/events/`). The consumer is a second entrypoint of the **backend image**, not a
  Lambda and not in `infra/`: the backend owns the embedder and the index (`chatbot-backend`
  ADR 0008), infra must hold no application source (`docs/adr/0004`), and dev's OpenSearch
  is in-cluster where a Lambda cannot reach it without a new exposure. Locally the queue is
  ElasticMQ (the SQS API), so both environments run one topology.
- **Vectorising is a model call, but not a paid one by default.** `EMBEDDING_MODEL=local` is
  an in-process ONNX model in both environments; `bedrock` stays selectable.
- **Volume:** a simulator publishes one call a minute — 1,440/day, ~10k live calls at a
  7-day retention, ~80k chunk vectors. Templated and seeded, no model call: an LLM-written
  transcript a minute is 1,440 Bedrock calls a day for test data.
- **Calls are organisation data**: every signed-in account reads them. No roles yet.
- **Hub and spoke:** a coordinator node picks exactly one spoke per turn — `documents`,
  `calls`, `general` — and the message records it as `route`. Deterministic (`heuristic`)
  in CI, model-chosen under `RETRIEVAL_ROUTER=llm`.
- **The fixed dev login** is one stable password, created by bootstrap (survives
  `dev-down`), for an `operator@agentapp.test` app account and Phoenix's `admin`. Never
  committed: dev is a public URL that spends money.

## Acceptance criteria (these are the oracle)

Ingest (local through ElasticMQ; remotely through the simulator):

1. A valid event published to the queue is readable at `GET /v1/calls/{call_id}` within
   60 s with its metadata and transcript as published.
2. Redelivering an event leaves one call.
3. An event whose `ended_at` is older than 7 days is never readable (`404 CALL_NOT_FOUND`);
   an indexed call is removed once it ages past 7 days (backend tests, injected clock).
4. An event that fails the schema — including an unmasked phone number — is never stored and
   lands on the dead-letter queue; no API response carries a phone field.
5. Both calls endpoints refuse without a session (`401`); an unknown id is `404 CALL_NOT_FOUND`.
6. The simulator's calls (`CALL-<14 digits>`) appear in `GET /v1/calls`, locally and on dev.

Hub and spoke:

7. Every new assistant turn carries `route` ∈ {`documents`, `calls`, `general`}, stored on
   the message and read back unchanged.
8. A question naming a call id is routed to `calls`, cites that call first, and has empty
   `citations` and `retrieval_consulted: false`.
9. A question about an uploaded document is routed to `documents`, `retrieval_consulted: true`.
10. Small talk from an account with no documents is routed to `general` with no citations.
11. A question about one queue's calls cites only calls from that queue.

Eval:

12. The eval run meets its thresholds (job exit 0) and a breached threshold exits 1.
13. The question set is stratified across all three routes; `routing_accuracy` compares
    `route` to `expected_route`.
14. All four evaluators score every example.
15. Each experiment records `calls_fixture_hash`.
16. The eval seeds its fixture calls through the queue, not around it — `CALL-EVAL000001`
    is readable through the API after a run.

Frontend:

17. An answer routed to `calls` shows its call sources (call id, queue, agent) in the
    browser (`e2e`).
18. `/api/v1/calls` reaches the API through the proxy, never the app shell.

Dev login:

19. On dev, `operator@agentapp.test` signs in to the app and `admin` to Phoenix with the one
    bootstrap secret; `make -C infra credentials ENV=dev` prints both logins and the command
    that reads it. Oracle: infra's `deploy` signs in to both before returning 0.

Documentation:

20. Every repo this change touches updates its `docs/architecture.md`, `README.md` and
    `CLAUDE.md` to match, replaces its `.claude` example skill/agent with real ones, and its
    own gate fails when code moves without docs. Oracle: each repo's gate, the control
    repo's `docs-currency` check, and review.

## A gap in the oracle

- **19 has no smoke step.** The password is a `secret_ref` and is never exported to a suite;
  infra's deploy check is the oracle and a failure there fails the remote pass at deploy.
- **The judge's quality on calls questions** needs `EVAL_JUDGE=bedrock`, which the loop must
  not require. `/dev-eval` is its oracle once the harness passes `EVAL_CALL_QUEUE_URL`.
- **Retention of an already-indexed call** cannot be waited out by a suite; criterion 3's
  second half is the backend's tests with an injected clock.

## Out of scope

- **Lambda, managed OpenSearch, a fifth repo** — decided above.
- **A real call-centre integration** (Amazon Connect, audio, speech-to-text) — the event
  schema is the seam a real one would publish to.
- **Roles or per-team visibility of calls** — needs an authorisation concept; a contract change.
- **PII redaction beyond phone masking** — names stay; transcripts are synthetic.
- **More than one spoke per turn** — a composite question is answered by the coordinator's
  single choice; fan-out is a later change once routing is measured.
- **A calls browsing page in the UI** — sources render in chat; browsing is not asked for.
- **Aggregate questions in the scored eval set** ("how many calls this week") — the simulator
  makes their answers move every minute.
- **The eval and the simulator as Kubernetes jobs of the eval image** — no eval image is
  deployed; the simulator ships in the backend image instead.

## Contract changes

All additive; `info.version` 1.6.0 → 1.7.0.

- `contracts/events/call-completed.v1.schema.json` — new, the first event.
- `contracts/openapi.yaml` — `GET /v1/calls`, `GET /v1/calls/{call_id}`; `Message.route`,
  `Message.call_citations`; `CALL_NOT_FOUND`.
- `contracts/infra-outputs.yaml` — `call_queue_url`, `call_dead_letter_queue_url`,
  `operator_login_email`, `operator_password_secret_ref`.
- `contracts/README.md` — § "Call-centre calls", § "The coordinator and its spokes".

## Deployment

- Local: ElasticMQ, the worker and the simulator join the stack; `iterate.sh` asserts it.
- Infra deploy: yes — the queue, the worker and simulator Deployments, IAM and the dev login
  only exist on `dev`. **Bootstrap must be re-applied once** (`make dev-bootstrap`): the
  deployer role needs SQS permissions and the operator secret lives there.

## Slices

- `chatbot-backend.md`
- `chatbot-eval.md`
- `frontend.md`
- `infra.md`

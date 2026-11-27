# 0010 — chatbot-backend slice

## What to build

1. **Steps on every assistant turn.** `run_turn` records an ordered list of `AgentStep`s:
   `coordinate` (kind `route`, agent `coordinator`) first; the spoke's retrieval as kind
   `retrieval` named for its tool — `search_documents` (documents), `search_calls` (calls),
   the gateway tool actually called (metrics, e.g. `search_semantic`, `query_metrics`); each
   gateway tool the metrics answer agent calls as kind `tool`; `answer` (kind `answer`) last.
   `general` has no retrieval step. Each carries a deterministic, human `label` and `summary`
   ("Sent to calls: the message names a call id", "Found 3 calls", "No governed metric
   matched"), `status`, `started_at`, `duration_ms`. Store them on the assistant message
   (new migration, JSONB column, like `metric_citations`) and return them from
   `GET /v1/threads/{id}` and `POST …/messages`. Old rows: absent, not `[]`. A tool refusal
   that does not fail the turn is a step with `status: error`. Summaries never carry SQL,
   credentials or raw arguments beyond what a citation already shows.
2. **`POST /v1/threads/{thread_id}/messages/stream`.** Same gates in the same order as the
   JSON endpoint, all refusals as the
   same JSON before the stream opens, same bucket. Then `text/event-stream`: `event: step` with
   `StepEvent` (`started`, then `completed`, same `id`) as each step happens, flushed per event;
   then exactly one `event: done` (the `SendMessageResponse`, after the turn is stored) or one
   `event: error` (`ErrorResponse`; nothing stored). One compact JSON `data:` line per event. A
   `: keep-alive` comment at least every 15 s. Headers `Cache-Control: no-cache` and
   `X-Accel-Buffering: no`. A step emitter injected into `run_turn` (a callback or queue) — the
   graph still knows nothing about HTTP. Declare the 200 as `text/event-stream` so
   `make contract` matches.
3. **Roles and capabilities.** `users.role` (migration, default `member`) and `User.role` on
   register / login / me. A small role policy in code — role → allowed spokes, allowed tools,
   `visibility.steps`; `member` allows everything and sees steps. `GET /v1/capabilities`
   returns role, every spoke this deployment runs (metrics only when `METRICS_GATEWAY_URL` is
   set) with label, description, `allowed` and its tools (`search_documents`; `search_calls`;
   the six gateway tools from the vendored `contracts/mcp/metrics-gateway.json`), and
   `visibility`. **Enforce it**: the coordinator skips a spoke the role may not use (`general`
   is the floor); the metrics answer agent is bound only the allowed tools; with
   `visibility.steps` false, `steps` is omitted and no `step` events are sent. The role is
   resolved per request and passed in by the replier — `graph/` still never sees an account.
4. **Markdown.** The answer prompts ask for GitHub-flavoured Markdown (headings, lists, tables,
   bold, code) with `[n]` markers kept. Content is stored as returned.

## Contract entries this depends on

- `contracts/openapi.yaml` 1.9.0 → `postThreadMessageStream`, `getCapabilities`,
  `AgentStep`, `StepEvent`, `CapabilitiesResponse`, `AgentCapability`, `ToolCapability`,
  `Visibility`, `Message.steps`, `User.role`
- `contracts/README.md` → § "Agent steps, progress and capabilities"
- `contracts/mcp/metrics-gateway.json` → the six tool names

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] Unit/graph tests: step order per route (documents, calls, metrics, general), an error
      step on a gateway refusal, steps stored and read back, absent on old rows.
- [ ] A test with a restricted role (test-only policy): a disallowed spoke is never routed to,
      a disallowed tool never bound, `visibility.steps: false` omits steps and step events.
- [ ] Stream tests: refusals are JSON before the stream; event order `started` → `completed`
      → `done`; a failing model yields `error` and appends nothing; heartbeat under a slow turn.
- [ ] `make contract`, `make typecheck`, the repo's gates.

## Smoke — what this slice is actually judged on

The steps whose `owner:` is `chatbot-backend`:

- [ ] `capabilities-require-a-session`, `the-stream-requires-a-session`
- [ ] `register-flow-account`, `login-flow-account`, `me-carries-the-member-role`
- [ ] `capabilities-name-the-role-and-visibility`, `capabilities-list-every-spoke-and-its-tools`,
      `capabilities-list-the-metrics-spoke-and-the-gateway-tools`
- [ ] `create-a-flow-chat`, `the-stream-validates-the-body`, `the-stream-refuses-an-unknown-chat`
- [ ] `a-turn-streams-steps-then-done` — started before completed, one `done` carrying steps, last
- [ ] `the-streamed-turn-names-its-route-and-answer-steps`
- [ ] `the-transcript-stores-the-steps-in-order`
- [ ] `the-json-endpoint-also-returns-steps`
- [ ] `a-call-question-steps-through-search-calls` — route `calls`, a `search_calls` step

The stack runs `CHAT_MODEL=bedrock` (a credential-free run uses `echo`) and the heuristic router;
nothing here depends on the reply's wording. These
run through the reverse proxy; a failure comes back with the request, the response and your
container log. The assertions belong to the control repo: fix the cause, never the assertion.

## Documentation

- `docs/architecture.md` — the stream endpoint, capabilities, roles and enforcement; drop the
  "no streaming" and "no roles" gaps; a turn's lifecycle with the emitter.
- `docs/graph.md` — steps: who records each, and the emitter.
- an ADR for the role policy living in code, and for SSE over WebSockets.
- `README.md` — any new make target (e.g. `make chat-stream MSG=…`).

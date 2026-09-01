# 0005 — Observability: Phoenix tracing now, classic monitoring instrumented only

## Why

Nothing can see inside a turn. When a reply is wrong, slow or expensive there is no record
of which node ran, what the model was given, how long retrieval took or how many tokens it
cost — only a line of text and a stack trace if it crashed. That is survivable while the
graph is small and it is not survivable now: 0004 put a routing decision and a retrieval
step in front of the answer, so "the assistant ignored my document" has four candidate
causes and no evidence to choose between them.

Two layers, deliberately unequal:

1. **LLM tracing is turned on for real.** Self-hosted Arize Phoenix in the local stack,
   persisted, with the backend instrumented once at its composition root. One API request
   becomes one trace, with the LangGraph run nested under the HTTP span.
2. **Classic monitoring is instrumented and NOT deployed.** Structured JSON logs carrying
   the trace id, and OTel metric instruments defined at the composition root — with no
   exporter, no scraper and no dashboard. The instrumentation is the expensive half and
   the part that has to be right in code; choosing a metrics backend is a later decision
   that must not block this one.

## Acceptance criteria (these are the oracle)

Numbers 1–7 are `smoke.yaml` steps against the joined stack. 8–13 name a different oracle
because the seam cannot see them — see § A gap in the oracle.

- [ ] 1. Phoenix answers `GET /healthz` on its own port with a 200, and lists a project
      named `chatbot-backend` — it is up, and the backend has reached it.
- [ ] 2. A message posted into a chat through the origin returns an `X-Trace-Id` response
      header holding 32 lowercase hex characters.
- [ ] 3. Querying Phoenix for exactly that trace id returns at least one span. The id the
      caller was handed is the id of a trace that exists.
- [ ] 4. That trace contains a root span — one with `parent_id: null` — named for the HTTP
      route (`POST /v1/threads/{thread_id}/messages`). The trace is rooted at the request,
      not at the graph.
- [ ] 5. The same trace contains at least one OpenInference `CHAIN` span. The LangGraph run
      is inside that trace rather than in one of its own.
- [ ] 6. That `CHAIN` span has a non-null `parent_id`. Nested, not a second root.
- [ ] 7. A stateless `POST /v1/chat` also returns an `X-Trace-Id`, and that trace is present
      in Phoenix rooted at `POST /v1/chat`. Instrumentation is at the composition root and
      therefore covers every route, not the one endpoint that was tested.
- [ ] 8. Traces survive a restart. After `docker compose restart phoenix`, a trace id
      recorded before the restart is still queryable. — `make phoenix-durability`
- [ ] 9. Every line the backend writes to stdout is a single JSON object, and lines produced
      while serving a request carry a `trace_id` equal to that request's `X-Trace-Id`.
      — chatbot-backend's own tests, plus `make phoenix-durability` printing the pair
- [ ] 10. With `OTEL_EXPORTER_OTLP_ENDPOINT` unset the app starts, serves, and logs exactly
      one warning saying telemetry is disabled. No `X-Trace-Id`, no crash.
      — chatbot-backend's own tests
- [ ] 11. With `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at an unreachable host the app starts
      and serves normally. Export failures never reach a request.
      — chatbot-backend's own tests
- [ ] 12. Four metric instruments exist — request count, request latency, graph-run
      duration, token count — and the meter provider has **no** metric reader attached.
      Defined, and going nowhere, on purpose. — chatbot-backend's own tests
- [ ] 13. No `arize.otel` import, no Arize API key, no SaaS endpoint anywhere in the backend
      or its lockfile. — chatbot-backend's own gate

## A gap in the oracle

Criteria 8–13 are real and they are not seam-visible, so saying so is part of the plan
rather than an omission.

- **8 needs a restart.** `smoke.py` makes HTTP requests against a stack somebody else
  brought up; it cannot cycle a container mid-suite. `make phoenix-durability` is the
  oracle, and this session runs it and reports the result rather than asserting the
  configuration looks right.
- **9 needs container stdout.** `smoke.py` reads responses, not logs. The response header
  is what makes the correlation checkable at all — without it there is no shared id between
  a log line and a Phoenix trace, and "correlated" is an unfalsifiable claim. The header
  half is asserted at the seam (criteria 2, 3, 7); the log half is asserted inside
  chatbot-backend and printed by `make phoenix-durability`.
- **10–13 need a differently-configured process.** The loop brings the stack up once, from
  one compose file. A second configuration is a unit test, and it belongs in the repo that
  owns the code.

## Out of scope

- **Prometheus, Grafana, Loki, an OTel Collector.** Named because an agent asked for
  "metrics" will otherwise deploy one. The instruments are defined and export nowhere; the
  backend is a later decision, and it is cheap precisely because the instrumentation
  already exists.
- **Eval pipelines, datasets, experiments.** Phoenix does all of it. This change puts
  traces in front of a person; running evals over them is its own change with its own
  criteria.
- **Any frontend change.** No trace surfaced in the UI, no error id shown to a user. The
  header exists so a machine can correlate, not so a person can read it.
- **Phoenix in AWS.** `infra/` is an empty scaffold with no IaC tool chosen — one commit,
  two `.gitkeep` files. There is nothing to add a container to. The code is already
  deploy-ready: `OTEL_EXPORTER_OTLP_ENDPOINT` is the only environment-specific input, and
  the same image runs against a collector, a hosted Phoenix or nothing at all. See
  § Deployment.
- **Sampling, redaction, PII scrubbing on span content.** OpenInference records prompts and
  completions, so a deployed Phoenix holds user text. That is acceptable for a local stack
  and is a real decision to make before the first deployed one; it is not this change.

## Contract changes

`contracts/README.md`: one new section, **Trace correlation**, promising the `X-Trace-Id`
response header — its shape, when it is absent, and what a consumer may and may not do
with it. Additive: nothing that exists today changes meaning, and a consumer ignoring the
header is unaffected.

It goes in `README.md` rather than `openapi.yaml` for the reason that file already gives
for the session cookie: `openapi.yaml` is machine-rewritten by `harvest-contract.py`, so a
response header declared there would be dropped at the next re-harvest. Prose in the README
survives.

The freeze SHA does NOT go here. It goes in `change.yaml` as `freeze_sha`.

## Deployment

- Local stack and smoke: always. `./scripts/iterate.sh 0005-observability-phoenix` brings
  every repo up together and runs `smoke.yaml` against the single origin, plus Phoenix's
  own origin for the steps that read the trace back.
- Infra deploy: **no**. `deploy.infra: false`, and there is no `infra` slice. `infra/` can
  currently deploy nothing, so the best outcome this change can reach is `verified-local`
  — deliberate, not an oversight. The original request named backend and infra as the two
  repos it expected to touch; the backend half is here in full, and the infra half is
  literally unbuildable today. It is named in § Out of scope with that reason rather than
  quietly dropped.

## Slices

- `chatbot-backend.md`

The control repo also changes, and that is not a slice: `stack/compose.yml` declares who
owns the two new services, `stack/dev.env` declares the variables the suite interpolates,
and `Makefile`/`scripts/stack.sh` gain the durability check criterion 8 needs.

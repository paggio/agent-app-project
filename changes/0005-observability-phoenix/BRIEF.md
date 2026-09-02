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

## Amended, 2026-09-02 — `/ship-iterate`

The first version put one trace per request in front of a person. Looking at one produced
four changes. Nothing merged, so this supersedes rather than adds.

| Was | Is | Why |
| --- | --- | --- |
| the ASGI instrumentor's default span set | `exclude_spans=["receive", "send"]` | one HTTP request drew five spans — `evidence/trace-has-asgi-send-receive-spans.png`. Four of them are ASGI plumbing and none is a thing anybody debugs |
| the root span carried `http.*` and nothing else | `user.id`, `session.id`, `input.value` | the trace could not answer "who asked this, and what did they ask" — the two questions you open a trace to answer |
| — | credentials are redacted before any body reaches a span | capturing request bodies puts `/v1/auth/login` on the wire into a store with a UI and an API. This is new risk that the first version did not carry |
| — | a standing dev account, in `stack/dev.env` | signing in by hand meant inventing an account each time |

And one thing that was already true and is now written down and enforced: `make down`
leaves nothing behind, Phoenix included. Measured before changing anything — 33 traces
before, project gone after — so this is a principle given a home and a gate, not a repair.

## Acceptance criteria (these are the oracle)

Numbers 1–11 are `smoke.yaml` steps against the joined stack. 12–18 name a different oracle
because the seam cannot see them — see § A gap in the oracle. **New in this amendment: 8–11
and 13.**

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
- [ ] 8. **One request draws one HTTP span.** The trace contains no span named
      `... http receive` or `... http send`. The graph's own nesting is untouched — it is
      the thing worth seeing, and criteria 5 and 6 still hold it.
- [ ] 9. **The root span says who asked and what they asked.** `user.id` is the account id
      that made the call, `session.id` is the chat it was made in, and `input.value` is the
      request body.
- [ ] 10. **No credential ever reaches a span.** After signing in, no span anywhere in the
      project contains the password that was sent. This is the criterion that makes
      criterion 9 safe to have, and it is asserted against the whole project rather than
      one trace, because one missed redaction anywhere is the whole failure.
- [ ] 11. **The standing dev account signs in with the credentials in `stack/dev.env`**, and
      `GET /v1/auth/me` answers with that same email.
- [ ] 12. Traces survive a restart. After `docker compose restart phoenix`, a trace id
      recorded before the restart is still queryable. — `make phoenix-durability`
- [ ] 13. **`make down` leaves no state anywhere, Phoenix included**, so `make up` is always
      a cold start. No service in the joined stack keeps data outside a project-scoped named
      volume — not a host bind mount, not an `external: true` volume.
      — `./scripts/check-docs.py`, plus the measurement in § A gap in the oracle
- [ ] 14. Every line the backend writes to stdout is a single JSON object, and lines produced
      while serving a request carry a `trace_id` equal to that request's `X-Trace-Id`.
      — chatbot-backend's own tests, plus `make phoenix-durability` printing the pair
- [ ] 15. With `OTEL_EXPORTER_OTLP_ENDPOINT` unset the app starts, serves, and logs exactly
      one warning saying telemetry is disabled. No `X-Trace-Id`, no crash.
      — chatbot-backend's own tests
- [ ] 16. With `OTEL_EXPORTER_OTLP_ENDPOINT` pointed at an unreachable host the app starts
      and serves normally. Export failures never reach a request.
      — chatbot-backend's own tests
- [ ] 17. Four metric instruments exist — request count, request latency, graph-run
      duration, token count — and the meter provider has **no** metric reader attached.
      Defined, and going nowhere, on purpose. — chatbot-backend's own tests
- [ ] 18. No `arize.otel` import, no Arize API key, no SaaS endpoint anywhere in the backend
      or its lockfile. — chatbot-backend's own gate

## A gap in the oracle

Criteria 12–18 are real and they are not seam-visible, so saying so is part of the plan
rather than an omission.

- **12 needs a restart.** `smoke.py` makes HTTP requests against a stack somebody else
  brought up; it cannot cycle a container mid-suite. `make phoenix-durability` is the
  oracle, and this session runs it and reports the result rather than asserting the
  configuration looks right.
- **13 needs a down and an up**, which is the one thing a suite running against a live stack
  can never do to it. Split in two rather than left as a claim: the enforceable half is a
  `check-docs.py` gate over what the joined stack may declare, which fails on a bind mount
  or an `external: true` volume and therefore fails *before* anyone loses data. The half
  that stays a measurement was taken on 2026-09-02 against a live stack — 33 traces in the
  `chatbot-backend` project, then `make down && make up`, then the project gone.
- **14 needs container stdout.** `smoke.py` reads responses, not logs. The response header
  is what makes the correlation checkable at all — without it there is no shared id between
  a log line and a Phoenix trace, and "correlated" is an unfalsifiable claim. The header
  half is asserted at the seam (criteria 2, 3, 7); the log half is asserted inside
  chatbot-backend and printed by `make phoenix-durability`.
- **15–18 need a differently-configured process.** The loop brings the stack up once, from
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
- **Response bodies on the span.** Requests only. Capturing a response means buffering it
  at the composition root, and the answer is already on the LangGraph spans where it is
  more useful. `input.value` without `output.value` is deliberate, not half-finished.
- **Sampling, and PII scrubbing of model content.** Credential redaction IS in scope now —
  criterion 10, and it is the price of criterion 9. What stays out is the broader question:
  OpenInference records prompts and completions, so a deployed Phoenix holds whatever users
  type. That is acceptable for a local stack and is a real decision before the first
  deployed one.
- **The dev account anywhere but a developer's machine.** It is seeded only when both
  variables are set, and refused unless the address is under a `.test` TLD — so a stray
  environment variable in a real deployment creates nothing. It is a convenience with a
  committed password, and it must stay one.

## Contract changes

`contracts/README.md`: one new section, **Trace correlation**, promising the `X-Trace-Id`
response header — its shape, when it is absent, and what a consumer may and may not do
with it. Additive: nothing that exists today changes meaning, and a consumer ignoring the
header is unaffected.

It goes in `README.md` rather than `openapi.yaml` for the reason that file already gives
for the session cookie: `openapi.yaml` is machine-rewritten by `harvest-contract.py`, so a
response header declared there would be dropped at the next re-harvest. Prose in the README
survives.

**The amendment does not move the interface, so there is no re-freeze.** `dfbb48f` stands.
Span attributes are not contract — nothing outside the backend reads them, and Phoenix is
not a consumer. The seeded account adds no endpoint, no field and no status. Reasserted
here because "we changed our minds, therefore re-freeze" is the reflex, and a second freeze
with an identical `contracts/` tree would make the record say an interface moved when it
did not.

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
owns the two new services, `stack/dev.env` declares the variables the suite interpolates —
now including the dev account's credentials — and `Makefile`/`scripts/stack.sh` gain the
durability check criterion 12 needs. The amendment adds `docs/adr/0011`, which is where the
clean-slate principle belongs, and the `check-docs.py` gate that enforces it.

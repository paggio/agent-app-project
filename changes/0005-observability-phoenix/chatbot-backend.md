# 0005 — chatbot-backend slice

## AMENDED, 2026-09-02 — read this before the rest

Your branch already carries a working implementation and its PR is open. This amendment
changes four things about it. **Where this section and the sections below disagree, this
wins**, and two of the disagreements are places where the earlier text explicitly forbade
what is now required — so read them rather than pattern-matching.

1. **One HTTP span per request** (§8 below). New.
2. **The root span must say who and what** (§9). This needs ONE line in `api/dependencies.py`,
   which §"Out of scope for this slice" previously forbade. That exception is now granted,
   and it is exactly one line — see §9.
3. **Credential redaction is now IN scope** (§9). The earlier text said "Sampling, redaction
   or PII scrubbing of span content... Not here." That was written when nothing captured a
   request body. §9 captures one, so redaction arrives with it and is not optional.
4. **A seeded dev account** (§10). New.

**Nothing is removed.** No file on your branch should be deleted and no behaviour reverted
— every criterion the first version passed still has to pass. Re-read `smoke.yaml`: it grew
from 10 steps to 18, and the 10 that were there are unchanged.

## What to build

Telemetry, entirely at the composition root. No node, no route handler, no service and no
store changes. If a diff in `graph/`, `threads/` or `knowledge/` is needed to make this
work, the design is wrong — say so rather than making the diff.

### 1. One module, one call

`src/app/core/telemetry.py`, called once from `create_app()`. It does four things and
nothing else:

1. Builds a tracer provider through **`phoenix.otel.register`** — the open-source package.
   `arize.otel` and anything wanting an Arize API key are forbidden outright; there is no
   SaaS account and there will not be one.
2. Instruments LangChain with the **OpenInference** instrumentor, so every LangGraph node,
   model call and tool call becomes a span.
3. Instruments the FastAPI app, so every request becomes the root span those nest under.
4. Builds a `MeterProvider` **with no metric readers** and defines four instruments on it.

```python
def install_telemetry(app: FastAPI, settings: Settings) -> Telemetry: ...
```

Called **last** in `create_app()` — after the guards middleware and after the routers. The
HTTP span has to be the outermost thing in the request path, or the guards run outside it
and a refusal is a request with no trace. Do not verify that by reading Starlette's
middleware ordering; verify it with the test in §6 that compares a response header against
the log line the same request produced.

### 2. Configuration, and fail-open

Four settings, all read from the environment. The code is identical locally and in the
cloud; only these move.

| Variable | Default | Meaning |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | OTLP base URL, e.g. `http://phoenix:6006`. The traces path is built from it — `f"{base.rstrip('/')}/v1/traces"` — rather than assumed. **Unset or empty disables tracing.** |
| `PHOENIX_PROJECT_NAME` | `chatbot-backend` | The project spans are filed under. |
| `OTEL_SERVICE_NAME` | `chatbot-backend` | `service.name` on the resource. |
| `LOG_FORMAT` | `json` | `json` or `text`. `text` exists for `make dev`; containers get `json`. |

Fail-open is a hard requirement, and it has three cases that must be handled separately
because they fail in different places:

- **Endpoint unset or empty** → log exactly one warning saying telemetry is disabled, and
  return. No provider, no instrumentors, no `X-Trace-Id`. The app is otherwise unchanged.
- **Setup raises** — a missing package, a malformed URL, an instrumentor that changed its
  signature → catch it, log one warning with the exception, and carry on serving. Telemetry
  must never be the reason the app fails to start.
- **The endpoint is unreachable at export time** → nothing happens to the request. This is
  what **batch processors only** buys: `register(..., batch=True)`. A simple/sync span
  processor exports on the request's own path and turns an unreachable collector into
  latency and then into errors. Never use one, not even "just for local".

### 3. The trace id on the wire

Every response the app produces — 200s, 401s, 422s, 500s — carries `X-Trace-Id`: the
32-character lowercase hex trace id of the request's root span. Absent, not empty, when
tracing is disabled.

Set at the composition root, from `trace.get_current_span().get_span_context()`, never in a
handler. It is what makes correlation checkable at all: without a shared id there is no way
to tie a log line, a support report or a smoke assertion to a trace, and "correlated" stays
an unfalsifiable claim.

`contracts/README.md` § **Trace correlation** is the frozen promise. Read it — it says what
a consumer may and may not do with the header, and the implementation must match it rather
than the other way round.

Health checks are excluded from tracing (`excluded_urls="healthz"` on the FastAPI
instrumentor). The container healthcheck runs every five seconds forever, and a trace store
full of it is a trace store nobody opens. Those responses therefore carry no header, which
is correct rather than a gap.

### 4. Structured logs

`configure_logging` gains a JSON formatter. One JSON object per line on stdout — stdout is
still where the container log driver reads, and that does not change.

Every record carries at least `timestamp`, `level`, `logger`, `message`. A record emitted
while a span is current also carries `trace_id` and `span_id`, **the same 32 hex characters
that request's `X-Trace-Id` holds**. Exceptions go in the object, not as a trailing
traceback that breaks the one-object-per-line rule.

Do this in the formatter, reading the current span. Not by threading an id through call
sites — that is the change to every module this slice exists to avoid.

### 5. Metrics: defined, exported nowhere

```python
MeterProvider(resource=..., metric_readers=[])   # empty, and that is the decision
```

No `PeriodicExportingMetricReader`, no Prometheus reader, no console exporter, no
collector. Four instruments, and where each is recorded matters because the answer must not
be "inside a node":

| Instrument | Kind | Recorded |
| --- | --- | --- |
| `http.server.requests` | Counter | the composition-root middleware that sets the header |
| `http.server.duration` | Histogram, ms | the same middleware |
| `graph.run.duration` | Histogram, ms | around `run_turn` inside `build_replier` in `main.py` — already the composition root, and already the one place the graph is called |
| `llm.token.count` | Counter, `token.type` = `prompt`/`completion` | a `SpanProcessor.on_end` in `telemetry.py`, reading `llm.token_count.*` off the OpenInference spans |

The token processor is the only non-obvious one, and it is the reason it is a processor: the
token counts already exist as span attributes the instrumentor wrote, so reading them there
costs nothing and touches no node. Anything else means changing the model call.

Build the meter provider **unconditionally**, including when tracing is disabled. A provider
with no readers discards every measurement, so the recording sites need no on/off branch —
there is nothing to switch off. Token counts are the exception and necessarily so: no spans,
no attributes to read.

### 6. Tests — these carry the criteria the seam cannot see

The smoke suite asserts criteria 1–11 through the joined stack. These are yours, and they
are the only oracle for the rest. **Renumbered by the amendment** — what was 9–13 is now
14–18, and the content is unchanged:

- **Criterion 14.** One request, and the `X-Trace-Id` on its response equals the `trace_id` in
  a log record emitted while handling it. Assert equality of the two strings, captured from
  one request — not that both are "present", which passes with two unrelated ids and is the
  exact shape of a correlation that does not correlate. Include a record emitted from the
  guards middleware, which is what pins the middleware ordering in §1.
- **Criterion 15.** `OTEL_EXPORTER_OTLP_ENDPOINT` unset: the app builds, serves a request,
  logs **exactly one** warning naming telemetry as disabled, and the response has no
  `X-Trace-Id`. Assert the count — a warning per request is a different bug that a
  presence check passes.
- **Criterion 16.** The endpoint pointed at a port nothing listens on: the app builds, serves,
  and the response is unaffected. This is the test that catches a sync span processor,
  because that is where the request pays for the failed export.
- **Criterion 17.** The four instruments exist by name, and the meter provider has **no**
  metric reader. Assert the emptiness — it is the whole "instrumented, not deployed" claim,
  and the day someone adds an exporter this is what says so.
- **Criterion 18.** No `arize.otel` import and no Arize API key anywhere in the source or
  the lockfile. A grep-shaped test is fine; the point is that it fails if someone reaches for
  the hosted product.

Four more, from the amendment. The smoke suite asserts all of these too, but each is
cheaper to debug here and two of them are about a case smoke cannot construct:

- **Redaction, per field and per shape.** A login body produces a span whose `input.value`
  contains neither the password nor the signup code; a register body likewise. Then the two
  cases the seam cannot reach: a body that is **not parseable JSON** sets no `input.value`
  at all, and a body **over the cap** is truncated with the marker rather than stored whole.
- **A non-JSON content type is never read.** Assert a `multipart/form-data` upload produces
  no `input.value` — not "a short one". This is what keeps a 10 MB PDF out of the trace store.
- **Seeding is idempotent and refuses non-`.test` addresses.** Build the app twice with the
  same `DEV_ACCOUNT_*` and assert one account with an unchanged id. Then with
  `dev@example.com` and assert nothing is created and one warning is logged. Then with only
  one of the two variables set, same.
- **`session.id` is absent, not empty, on a route with no chat id.** `GET /v1/documents`
  sets no `session.id`. An empty string would group every non-chat request into one session
  in Phoenix's Sessions tab, which looks like a feature working.

Plus whatever `make test typecheck lint contract` requires. All four must pass.

### 7. The stack

`docker-compose.yml` gains two services. Both are local-dev infrastructure, exactly like
`opensearch` and `minio`.

```yaml
  phoenix:
    image: arizephoenix/phoenix:version-20.4.0
```

- **`PHOENIX_SQL_DATABASE_URL`** pointed at the second service, `phoenix-db` — a
  `postgres:17-alpine` with its own named volume and its own `pg_isready` healthcheck. The
  app's Postgres is not shared with it: one database that loses its volume then takes the
  accounts with it, and two services whose retention policies have nothing to do with each
  other.
- **`PHOENIX_WORKING_DIR` on a named volume** as well. Both halves persist or criterion 8
  fails, and it fails by looking like everything worked until the first restart.
- **Publish 6006 as `${PHOENIX_PORT:-6006}:6006`**, parameterised for the reason the other
  ports already are: this repo's own stack has to be able to run beside the control repo's
  joined one instead of colliding with it.
- **The healthcheck cannot be `CMD-SHELL`.** That image ships no shell. Its entrypoint is
  `/usr/bin/python3.13`, so use `CMD` with that interpreter and a stdlib one-liner against
  `http://localhost:6006/healthz` — the same shape the backend's own healthcheck already
  uses, and for the same reason.
- **`backend` must NOT `depends_on` phoenix.** Fail-open is the requirement; a dependency
  makes a trace store outage an app outage, which is precisely what §2 forbids.

Backend service environment, and the defaulting is deliberate:

```yaml
      OTEL_EXPORTER_OTLP_ENDPOINT: ${OTEL_EXPORTER_OTLP_ENDPOINT-http://phoenix:6006}
      PHOENIX_PROJECT_NAME: ${PHOENIX_PROJECT_NAME:-chatbot-backend}
      OTEL_SERVICE_NAME: ${OTEL_SERVICE_NAME:-chatbot-backend}
      LOG_FORMAT: ${LOG_FORMAT:-json}
```

`${VAR-default}` on the endpoint, **not `${VAR:-default}`**. The bare `-` leaves an
explicitly empty value empty, which is how someone asks for telemetry to be off —
`OTEL_EXPORTER_OTLP_ENDPOINT= make up` and the app runs with no exporter. With `:-` that
request is silently overridden and criterion 10 is unreachable from the stack.

`make up` in this repo must come up green with the two new services, unattended, from an
empty volume.

### 8. One request draws one HTTP span — AMENDED

`evidence/trace-has-asgi-send-receive-spans.png` is what this fixes. A single
`POST /v1/threads/{thread_id}/messages` drew five spans: the root, one
`... http receive`, and three `... http send`. The four extras are ASGI protocol events.
Nobody debugs them, and they bury the LangGraph subtree that is the reason to open the
trace at all.

```python
FastAPIInstrumentor.instrument_app(app, ..., exclude_spans=["receive", "send"])
```

Supported by the `opentelemetry-instrumentation-asgi` version already in your lockfile
(0.65b0) and passed straight through by `instrument_app`. **Do not** achieve this with a
sampler or a span processor that drops them after the fact — that pays to create them
first, and a future reader cannot tell a filtered span from one that never existed.

**This changes nothing about the graph's nesting.** `route_query`, `answer`, `model` and
the rest stay exactly as they are; criteria 5 and 6 still assert them.

### 9. The root span says who asked, and what they asked — AMENDED

The screenshot is the complaint: thirteen attributes, all `net.*` and `http.*`, and no way
to tell which account made the call or what they sent. Three attributes fix it, and they
use the **OpenInference** names rather than invented ones — that is what makes Phoenix
render them as Input and group traces in its Sessions tab instead of listing them as loose
key/values.

| Attribute | Value | Set where |
| --- | --- | --- |
| `user.id` | the account id | see the exception below |
| `session.id` | the chat id, where the route has one | the composition root, after `call_next` |
| `input.value` + `input.mime_type` | the request body, redacted | the composition root |

**`user.id` needs one line in `api/dependencies.py`, and that exception is granted.** The
account id exists nowhere else: it is resolved inside the session dependency, and a
middleware that wanted it would have to re-resolve the cookie, which means a second copy of
the auth logic and a second thing to keep correct. So the `CurrentAccount` dependency
stamps the id on the current span and does nothing else — one statement, no import of
anything but `opentelemetry.trace`, no branching, no new parameter. Anything larger than
that is the wrong shape and should come back as a question.

**`session.id` is read from `scope["path_params"]` AFTER `call_next` returns.** The router
populates it on the same scope dict during routing, so it is not there before. A request to
a route with no `thread_id` sets nothing rather than setting an empty string — absent is a
fact, `""` is a lie.

**The body is captured by a small pure-ASGI middleware that wraps `receive`.** Two ways of
doing this are wrong and both are the obvious first attempt:

- **`await request.body()` in a `BaseHTTPMiddleware`.** Starlette caches the body on the
  request INSTANCE, and the route builds its own instance over the same exhausted `receive`.
  The route then hangs or sees an empty body.
- **`client_request_hook` on the instrumentor.** It is the natural home and it is
  unreachable here: with `exclude_spans=["receive"]` the ASGI instrumentation returns the
  raw `receive` before any hook runs — `opentelemetry/instrumentation/asgi/__init__.py:884`.
  §8 and this section would silently cancel each other out.

So: wrap `receive`, accumulate `body` chunks as the app consumes them, and set the attribute
when the request completes. Installed inside the OTel middleware and outside the guards, so
the current span is the HTTP root.

**Three limits on what is captured, all of them load-bearing:**

- **JSON request bodies only.** Content type outside `application/json` is skipped
  entirely — never read a `multipart/form-data` body, or a 10 MB PDF upload goes onto a span
  and into the trace store.
- **Capped**, around 4 KB, with a marker when truncated. A span attribute is not a place to
  put an unbounded string.
- **Redacted before it is ever set** — the next section, and it is not optional.

#### Credentials must never reach a span

This is criterion 10, it is asserted across the WHOLE project rather than one trace, and it
is the reason capturing a body needs care rather than enthusiasm. `POST /v1/auth/login` and
`POST /v1/auth/register` carry a password and a signup code. Phoenix has a UI, a REST API
and a persistent database; a password written there is a password disclosed, and no status
code reveals it.

**Reuse the redactor `api/errors.py` already has.** It exists because a `422` was echoing a
rejected password back to the caller, which is the same defect through a different pipe.
One redaction rule with two callers, not two rules that will drift.

Redact by key name over the parsed JSON — `password`, `signup_code`, and anything matching
the password-ish set `errors.py` already recognises. Not by route: a redactor that keys off
the path silently stops covering an endpoint the day somebody adds one. **If the body cannot
be parsed as JSON, set nothing at all** rather than attaching the raw string — an
unparseable body is exactly where a credential would survive a key-based filter.

### 10. A standing dev account — AMENDED, new

Signing in by hand currently means registering a throwaway account every time. Seed one at
startup instead, from the lifespan, before the app serves.

```
DEV_ACCOUNT_EMAIL       unset by default
DEV_ACCOUNT_PASSWORD    unset by default
```

- **Both set, or nothing happens.** One of the two alone is a misconfiguration, not a
  half-request: log one warning naming which is missing, and seed nothing.
- **Idempotent.** An account that already exists is left alone — its password is not reset
  and its id does not change, so a `make down`-less restart does not invalidate a session
  somebody is holding. Seeding must not fail when the row is there.
- **Refuse any address outside a `.test` TLD.** `dev@auth.test` is fine; anything else logs
  a warning and seeds nothing. `.test` is RFC 2606 reserved and can never be a real mailbox,
  so a stray copy of these variables in a deployed environment creates nothing rather than
  creating a known-password account on it. This is the whole safety argument for shipping a
  committed password — do not weaken it to "only when `APP_ENV=dev`", which is a variable
  somebody will set wrongly one day.
- **It goes through the same password policy and the same hashing as a registration**, and
  it does NOT need the signup code — it is not a registration, it is a seed. A password that
  fails the policy must fail loudly at startup rather than being silently accepted, or the
  credentials in `stack/dev.env` will not work and nobody will know why.
- The values live in the control repo's `stack/dev.env`. Your `docker-compose.yml` passes
  them through with `${DEV_ACCOUNT_EMAIL-}` / `${DEV_ACCOUNT_PASSWORD-}` — the bare `-`,
  so an explicitly empty value stays empty, exactly as `OTEL_EXPORTER_OTLP_ENDPOINT` does.
  **Do not put a default email or password in the compose file.** Unset must mean unset, or
  every environment that merely forgets to set them gets an account.

## Contract

Vendored at the freeze SHA and read-only. Two things in it apply:

- `contracts/README.md` § **Trace correlation** — the `X-Trace-Id` promise. New in this
  freeze, and the normative version of §3.
- `contracts/openapi.yaml` — **unchanged by this slice.** No new endpoint, no new field, no
  status that did not exist. If your implementation wants one, stop: that is a control-repo
  change and this slice is blocked on it.

## Dependencies

`arize-phoenix-otel`, `openinference-instrumentation-langchain`,
`opentelemetry-instrumentation-fastapi`, and the OTel SDK they need. Pinned exactly, like
every `langchain-*` package already is, and bumped as a set.

## How it is verified

- This repo: `make test typecheck lint contract`, including the five tests in §6.
- The seam: `changes/0005-observability-phoenix/smoke.yaml`, which you are judged on. It
  posts a message, reads `X-Trace-Id` off the response, and asks Phoenix for exactly that
  trace. It then asserts that the span named `POST /v1/threads/{thread_id}/messages` has a
  null parent, and that every `CHAIN` span in the same trace has a non-null one — so a
  LangGraph run traced into a trace of its own fails, and so does an app instrumented
  without the FastAPI root. `POST /v1/chat` is asserted the same way, because
  instrumentation attached to one router passes everything else.
  The amendment adds eight more steps: the trace has no `http receive`/`http send` children,
  the root span carries `user.id`, `session.id` and the message text, the dev account signs
  in with the values committed in `stack/dev.env`, and **no password or signup code appears
  anywhere in the whole project**. That last one is asserted after a real sign-in, so an
  empty store cannot satisfy it.
- Out of band: `make phoenix-durability` in the control repo restarts Phoenix and asks for
  the trace again.

## Docs

`docs/architecture.md` gains telemetry in the module map and the request lifecycle, in the
same commit. An ADR too — "telemetry is installed at the composition root and nowhere else"
is exactly the decision a future reader will otherwise undo by adding a tracer import to a
node, and the metrics-with-no-reader choice needs its reason on the record beside it.

## Out of scope for this slice

- Any change to `graph/`, `threads/`, `knowledge/`, `auth/` or `db/` beyond the one timing
  call in `main.py`'s `build_replier` — and, **added by the amendment**, the one line in
  `api/dependencies.py` that stamps `user.id` on the current span, plus the lifespan hook
  that seeds the dev account. Nothing else moves. Those two are named exceptions with
  reasons in §9 and §10; they are not permission to instrument from inside the app.
- Sampling, and PII scrubbing of MODEL content. OpenInference records prompts and
  completions; that is accepted for a local stack and is a real decision before a deployed
  one. **Credential redaction is no longer out of scope** — the amendment captures request
  bodies, so §9's redaction requirement arrives with it and is mandatory.
- Response bodies. `input.value` only, no `output.value`: capturing a response means
  buffering it, and the answer is already on the LangGraph spans.
- Any metrics exporter, collector or scrape endpoint. Adding one is the failure mode of this
  slice, not an improvement to it.
- Anything in `infra/`. There is nothing there yet.

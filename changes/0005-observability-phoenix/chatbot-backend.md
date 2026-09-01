# 0005 — chatbot-backend slice

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

The smoke suite asserts criteria 1–7 through the joined stack. These are yours, and they are
the only oracle for the rest:

- **Criterion 9.** One request, and the `X-Trace-Id` on its response equals the `trace_id` in
  a log record emitted while handling it. Assert equality of the two strings, captured from
  one request — not that both are "present", which passes with two unrelated ids and is the
  exact shape of a correlation that does not correlate. Include a record emitted from the
  guards middleware, which is what pins the middleware ordering in §1.
- **Criterion 10.** `OTEL_EXPORTER_OTLP_ENDPOINT` unset: the app builds, serves a request,
  logs **exactly one** warning naming telemetry as disabled, and the response has no
  `X-Trace-Id`. Assert the count — a warning per request is a different bug that a
  presence check passes.
- **Criterion 11.** The endpoint pointed at a port nothing listens on: the app builds, serves,
  and the response is unaffected. This is the test that catches a sync span processor,
  because that is where the request pays for the failed export.
- **Criterion 12.** The four instruments exist by name, and the meter provider has **no**
  metric reader. Assert the emptiness — it is the whole "instrumented, not deployed" claim,
  and the day someone adds an exporter this is what says so.
- **Criterion 13.** No `arize.otel` import and no Arize API key anywhere in the source or
  the lockfile. A grep-shaped test is fine; the point is that it fails if someone reaches for
  the hosted product.

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
- Out of band: `make phoenix-durability` in the control repo restarts Phoenix and asks for
  the trace again.

## Docs

`docs/architecture.md` gains telemetry in the module map and the request lifecycle, in the
same commit. An ADR too — "telemetry is installed at the composition root and nowhere else"
is exactly the decision a future reader will otherwise undo by adding a tracer import to a
node, and the metrics-with-no-reader choice needs its reason on the record beside it.

## Out of scope for this slice

- Any change to `graph/`, `threads/`, `knowledge/`, `auth/` or `db/` beyond the one timing
  call in `main.py`'s `build_replier`.
- Sampling, redaction or PII scrubbing of span content. OpenInference records prompts and
  completions; that is accepted for a local stack and is a real decision before a deployed
  one. Not here.
- Any metrics exporter, collector or scrape endpoint. Adding one is the failure mode of this
  slice, not an improvement to it.
- Anything in `infra/`. There is nothing there yet.

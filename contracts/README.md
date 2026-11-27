# contracts/ — owned here, consumed everywhere

The interface between the product repos. Edited only in this repo, and frozen by commit
before any implementation starts. Each product repo vendors a copy and verifies conformance in its own CI.

| File | Interface |
| --- | --- |
| `openapi.yaml` | HTTP |
| `events/*.schema.json` | async messages |
| `<kind>/*.json` | any other interface a service exposes — e.g. `mcp/<server>.json`, an MCP server's tools |
| `infra-outputs.yaml` | what infra promises the app repos (ARNs, URLs, secret names) |

`openapi.yaml` describes the API as the backend serves it — paths without the `/api`
prefix, which the proxy strips before forwarding. `events/` holds one JSON Schema per event
and version; each names its consumers in `x-consumers`, which is who it is published to.
Any JSON contract under a `<kind>/` directory follows the same rule, so a new kind of
interface needs no script change (`docs/adr/0020`).

`infra-outputs.yaml` is real as of `version: 1`. It has **no environment dimension on
purpose** — the environment lives in the invocation (`make -C infra outputs ENV=dev`),
so the names are invariant and only the values move. A per-environment block would let
one environment promise less than another, which institutionalises the drift it claims to describe.
Its `kind` field distinguishes a value from the *name* of something, and has one
mechanical consequence: `verify.sh` exports only `kind: value` outputs into the
environment a smoke suite can interpolate, so a secret reference can never be
interpolated into a request body.

**`openapi.yaml` is machine-rewritten.** `./scripts/harvest-contract.py --write` drafts
it from a running service, so YAML comments inside it do not survive. Durable guidance
belongs in this file. Prose you write in the spec — `summary`, `description`,
`operationId`, `tags` — IS preserved across re-harvests; only structure is retaken from
the implementation.

## Auth and sessions

Promised here rather than in `openapi.yaml`, because OpenAPI describes bodies and statuses
and these are neither — a re-harvest would drop them, and they are exactly the parts a
consumer cannot discover by reading a response.

**The session cookie.** Named `session`. Its value is an opaque server-side session id
carrying no claims, so it means nothing without the server's record — which is what makes
logout immediate rather than eventual.

| Attribute | Value | Why it is promised |
| --- | --- | --- |
| `HttpOnly` | always | Script cannot read the cookie, so an XSS cannot exfiltrate the session. |
| `SameSite` | `Lax`, always explicit | Blocks cross-site POST outright. Set explicitly on purpose: a cookie that merely *omits* `SameSite` gets Chrome's two-minute `Lax-allowing-unsafe-on-top-level` grace period, and declaring the attribute forfeits it. |
| `Path` | `/` | One session for the whole origin. |
| `Secure` | wherever the origin is HTTPS | **Environment-conditional, not promised unconditionally.** The local stack is `http://localhost:8080`, and Python's `http.cookiejar` refuses to return a `Secure` cookie over HTTP with no localhost exemption — so a hardcoded `Secure` breaks `smoke.py` at the seam while browsers hide the problem. The local pass asserts the three attributes above and never this one; a `remote`-tagged step asserts `Secure` against a deployed HTTPS origin by reading the raw `Set-Cookie` header, which bypasses the jar entirely. Nothing else catches a missing `Secure`: over HTTPS the jar accepts such a cookie happily, so every session-carrying step still passes. |
| `Max-Age` | absent | A browser-session cookie: closing the browser ends it client-side. Server-side expiry is the authority. |

**Lifetime is sliding, seven days idle.** The server record expires seven days after the
last authenticated request, and a request bearing a valid session pushes the expiry out.
The rewrite is throttled to at most once an hour so a read does not become a write on
every request; a client therefore cannot infer exact expiry from behaviour, which is why
no expiry is exposed in `IdentityResponse` yet.

**CSRF posture, and the invariant it rests on.** `SameSite=Lax` is the primary control.
On top of it, unsafe methods are refused with `403 AUTH_CROSS_ORIGIN` when `Origin` or
`Sec-Fetch-Site` is present and does not indicate same-origin. When neither header is
present the request is allowed: a browser cannot be made to omit `Origin` on a
cross-origin POST, so the only callers that reach that branch are non-browser clients,
which were never the CSRF threat model. The check runs before the rate limiter, so a
cross-site page cannot burn down someone else's attempt budget.

This leaves one invariant that every repo must uphold and no schema can express:

> **No `GET` ever mutates state.** `SameSite=Lax` still sends the cookie on top-level
> cross-site GET navigation. A mutating GET is therefore a CSRF hole that the cookie
> attribute cannot close, and adding one silently converts a sound posture into an
> unsound one.

**Two error shapes, one rule.** `422` keeps the framework's `{"detail": [...]}` shape,
already frozen for `/v1/chat`; the `{"error": {"code", "message"}}` envelope covers `401`,
`403`, `404`, `409` and `429`. The rule that decides which: **422 means the request was malformed
or violated a stated policy, the envelope means the request was well-formed and refused.**
Password-policy failures are therefore `422`, because the policy is stated — they are
enforced as validation, not as a semantic refusal. Consumers must tolerate an unknown
`error.code` by falling back to `message`; codes are added additively and exhaustive
switching on them will break.

## Chats, ownership and titles

Promised here rather than in `openapi.yaml` for the same reason the session is: these are
rules about *which* answer is correct and *why*, and a re-harvest would drop every word of
it.

**A chat belongs to exactly one account, and everyone else gets `404`.** Not `403`. The
status is load-bearing: `403 THREAD_FORBIDDEN` would confirm the chat exists, which turns
every chat endpoint into an oracle for other people's chat ids — and chat ids appear in URLs
people paste. So four situations return one indistinguishable answer, `404
THREAD_NOT_FOUND`:

| The caller asks for | Answer |
| --- | --- |
| a chat id that was never issued | `404 THREAD_NOT_FOUND` |
| a chat that was deleted | `404 THREAD_NOT_FOUND` |
| a chat owned by another account | `404 THREAD_NOT_FOUND` |
| a malformed chat id | `404 THREAD_NOT_FOUND` |

This is the same reasoning that already makes an unknown email and a wrong password return
a byte-identical `401`, and it has the same corollary: a client must not try to tell these
apart, and must not render "you do not have permission" — it does not know that.

> **The refusal must not be a delete that reports itself missing.** An implementation that
> deletes the row and *then* answers `404` satisfies every negative assertion — the other
> account is refused, exactly as promised. The only thing that catches it is the owner
> reading the chat back afterwards, which is why the smoke suites carry that step
> immediately after the refusals rather than treating the three `404`s as sufficient.

**Scoped in the query, not filtered after it.** Every statement that reads or mutates a chat
is scoped by the account in the same clause that finds it. Stated here because it is the
difference between an endpoint that cannot leak and one that does not happen to today: a
detail endpoint can guard correctly while the *list* endpoint returns everybody's chats, and
no assertion about the detail endpoint would notice.

**Titles are derived once, then owned by the caller.** A chat needs a name before anyone has
chosen one, so the server derives one from the first user message — server-side, so a client
never invents a title and two clients cannot derive different ones. *How* it derives one is
not promised and may change. What is promised:

- `title` is always present and never empty, from the first reply onwards.
- Derivation happens **once**. Once a caller has set a title with `PATCH`, later messages
  never re-derive it. A rename that a conversation silently undoes is worse than no rename.
- Clearing a title is not possible. `RenameThreadRequest.title` is required and not nullable,
  because a chat with no title is not something a client can render.

**Delete is a hard delete.** The chat and its messages are gone: no archive, no trash, no
undo, and no `deleted_at`. A client must not present an interface that implies otherwise.
Deleting an already-deleted chat is the same `404` a stranger gets, not a forgiving `204` —
a `204` for a chat the caller cannot see would leak which ids once existed.

**What history promises, and what it does not.** `POST /v1/threads/{id}/messages` supplies
the earlier turns of that chat to the model, so a follow-up question works. `POST /v1/chat`
does not and never will — it stays stateless, and that is why it survives rather than being
replaced.

The window is **bounded and its size is not promised.** Turns that fall outside it are not
sent, and they are not summarised or compacted either — they are simply absent from what the
model sees, while remaining in the transcript a person reads. Two consequences worth stating
because a client will otherwise imply otherwise to a user:

- The assistant can be asked a follow-up. It cannot be relied on to recall the start of a
  long chat, and a UI must not claim it can.
- **The stored transcript is the single source of history.** There is no second record — no
  checkpointer holding a parallel view of the same conversation. Two records of one
  conversation is a divergence with no tie-breaker, and the transcript is the one a person
  reads back.

**Sending is rate limited per account**, `429 AUTH_RATE_LIMITED` with `Retry-After`. It is
declared on the message endpoint and not on `/v1/chat` for a specific reason: a turn that
carries history costs more than one message's worth of tokens, so the endpoint that made
replies affordable to an authenticated caller is the one that needs a bound. The buckets are
per-process, so above one replica the effective limit multiplies — the same caveat the
credential endpoints already carry, and the same trigger to revisit: a shared store.

**No `GET` mutates a chat.** Reading one, or listing them, does not touch `updated_at` and
does not extend anything. This is not a new rule — it is the invariant the whole CSRF posture
above rests on, restated here because `updated_at` is exactly the field somebody will be
tempted to bump on read.

## Documents, the knowledge base, and what a citation promises

Promised here rather than in `openapi.yaml` for the same reason the session and the chats
are: these are rules about *which* answer is correct and *why*, and a re-harvest would drop
every word of it.

**A document belongs to exactly one account, and everyone else gets `404`.** The same four
situations collapse to one indistinguishable `404 DOCUMENT_NOT_FOUND` — never issued,
deleted, owned by someone else, malformed — for the reason the chats section already gives:
a `403` confirms the id exists, and ids appear in URLs people paste. **Including on the
content path**, which is the one that reaches the object store: that is the one handler where
fetching first and checking ownership afterwards is a natural thing to write, and where the
consequence is somebody else's document body on the wire rather than a status code.

> **The refusal must not be a delete that reports itself missing.** Identical to the trap
> the chats section names, and it has the same only-cure: the owner reads the document back
> afterwards. Every negative assertion is satisfied by a backend that destroys the thing and
> then honestly reports it gone.

**Scoped in the query, not filtered after it.** The list endpoint especially. A detail
endpoint can be scoped correctly while the list returns everybody's documents, and no
assertion about the detail endpoint would notice.

**The stored original is the system of record; the index is derived.** This is the load-bearing
one, and it is why `GET /v1/documents/{document_id}/content` exists at all rather than being
an obvious thing to omit. Chunking strategies, embedding models and vector dimensions all
change, and every one of those changes means re-deriving the index from the originals.
Re-deriving must never mean asking people to upload their documents again. So:

- What was uploaded is served back unchanged, under the content type it was uploaded as.
- How a document is split, what it is embedded with, and how retrieval scores are combined
  are **not promised** and will change. `chunk_count` and `chunk_index` are therefore
  descriptive, not addressable: they tell a consumer "one part of a longer document" and
  nothing more.
- **Deleting a document deletes all three copies** — the record, the stored original, and
  every indexed piece. A delete that leaves the object behind satisfies every metadata
  assertion and quietly accumulates bytes nobody is accounting for.

**Ingest is synchronous, and `status` exists anyway.** A `201` means the document is already
searchable — there is no pending state to poll through, which is what keeps a client from
having to model one. `Document.status` is in the schema from the first version so that
`pending` or `indexing` is an additive value later rather than a reshape, and a consumer
must tolerate a value it does not know.

**Size and type are stated policy; the quota is a refusal.** Content over the configured
limit and a content type outside the accepted set are `422`, because the rule above —
*422 means the request was malformed or violated a stated policy* — puts them there, exactly
as it puts the password policy there. An account that has reached its document limit sent a
well-formed request that was refused, so that is `409 DOCUMENT_QUOTA_EXCEEDED` in the
envelope. **The limit is enforced before anything is stored, chunked or embedded**: a refusal
that has already paid for the embeddings is not a refusal, and no status code reveals the
difference.

**Two intakes, one resource.** `application/json` with a `content` string carries text and
markdown. `multipart/form-data` with a `file` part carries anything binary, which today means
`application/pdf`. A client picks by what it holds; a PDF read as text is a corrupted PDF.
There is deliberately no base64 field: at the size limits a deployment configures, a base64
body is a third larger and has to be decoded in memory before it can be refused, which makes
the refusal the expensive path.

**A PDF is stored as a PDF and indexed as its text.** The extracted text is what is chunked,
summarised, retrieved and quoted in a citation; the content path still returns the original
bytes.
How extraction works is not promised. **A PDF with no extractable text is refused `422`**
rather than stored — a scan indexes nothing, so accepting it would put a document in a
knowledge base that can never be retrieved, which looks like success and is not.

**Formats are exhaustive per intake, and grow additively.** Nothing else is accepted today,
and a new format arrives as a new accepted content type rather than as a new endpoint.

### What a citation promises

Read this one precisely, because the temptation to over-claim is the whole risk of a grounded
assistant.

> **A citation says the model WAS GIVEN this text. It does not say the model used it.**

Nothing in this contract can certify the second. A consumer must not present citations as
proof that a particular sentence came from a particular document, and must not phrase them as
verification. What they honestly support is "here is what the assistant was working from",
which is exactly the thing a person cannot otherwise see.

- **`filename` on a citation is a snapshot**, taken when the answer was written. It is not a
  lookup and it is not a join. This is what lets a transcript keep naming its sources after
  the knowledge base has moved on, and it is the difference between a durable record and one
  that develops holes the first time somebody tidies up. `document_id` is carried alongside
  it so a consumer can link to a document that still exists — and must handle the `404` when
  it does not.
- **At most one citation per document, per message.** Retrieval may supply several chunks of
  one file and often does; the citation list is per DOCUMENT, and the highest-scoring chunk
  is the one whose `chunk_index` and `snippet` represent it. This is promised rather than
  left to a consumer to collapse, because a consumer cannot: two genuinely different
  documents may share a filename, so a client deduplicating by name would hide a real
  distinction, and one deduplicating by `document_id` would be reimplementing this rule
  slightly differently in every client.
- **`marker` is per message**, 1-based, contiguous over the deduplicated list, and is what
  the reply's own text refers to as `[1]`. It is not stable across messages. A reply from a
  model that emits no markers still carries a complete citation list; the list is the promise
  and the inline markers are a convenience.
- **`retrieval_consulted` absent is a real state, not false.** Every assistant message stored
  before knowledge bases existed has neither field, and a transcript that mixes old and new
  messages is the ordinary case rather than an edge case. Treat absence as "not applicable".
- **True with an empty citation list is also a real state**: the assistant consulted the
  knowledge base and found nothing relevant. That is a different fact from not having looked,
  and it is worth showing as one.

**Whether a turn consults the knowledge base is a per-turn judgement, and its criteria are
not promised.** A consumer must not depend on any particular question producing retrieval,
must not offer a control that forces it, and must not describe the assistant as searching
every time — because it does not, deliberately: consulting a knowledge base costs something
on every turn, and the decision not to is the reason it is affordable.

**`POST /v1/chat` never consults anything.** It is stateless by contract, it has no history,
and it has no knowledge base either. That is its whole shape, and the reason it survives
alongside the chat endpoints rather than being replaced. A caller that wants the knowledge
base posts into a chat.

## Call-centre calls

**One event per finished call**, `events/call-completed.v1.schema.json`, as the body of one
message on the call queue (`call_queue_url`). Producers: the call centre — here, the
simulator (one call per minute) and the eval. Consumer: chatbot-backend's call worker. No
other repo reads or writes the call index: the HTTP paths below are the only way out.

- **At-least-once, so `call_id` is the idempotency key.** The latest event for a call_id
  replaces every earlier copy; redelivering one changes nothing. `event_id` distinguishes
  publishes, never calls.
- **Retention is seven days from `ended_at`**, in every copy the backend keeps. An event
  already past it is refused at ingest; one that ages out disappears from search, from
  `GET /v1/calls` and from the detail path — `404 CALL_NOT_FOUND`, the same answer as never
  received. Citations already written into a transcript keep their snapshot.
- **A refused event goes to the dead-letter queue**, never silently dropped. Schema-invalid
  events go there at once — retrying a malformed message cannot fix it; a transient failure
  goes there after the redrive limit.
- **Calls are organisation data.** Every signed-in account reads the same calls. There are no
  roles, so "who may read calls" is "who holds a signup code"; a role is a contract change.
- **No phone number in the clear**, anywhere: the producer masks it, the backend refuses an
  event whose `phone_masked` does not match the mask pattern, and the API never returns one.
- **An event is at most 256 KiB serialised**, the queue's limit.

## The coordinator and its spokes

Every chat turn is answered by **exactly one spoke**, chosen by the coordinator, and the
assistant message says which in `route`: `documents` (the caller's own knowledge base),
`calls` (the call-centre calls), `metrics` (governed metrics, below) or `general` (no
retrieval). The criteria the coordinator
uses are **not promised**, for the reason the knowledge-base decision never was.

- `retrieval_consulted` keeps its meaning — *the knowledge base was consulted* — so it is
  `true` exactly when `route` is `documents`. A consumer written before `route` still reads
  every new turn correctly.
- A `calls` turn carries `call_citations` and an empty `citations`; a `documents` turn the
  reverse; a `metrics` turn `metric_citations` and neither of the others; a `general` turn
  none. Markers are 1-based within whichever list is present.
- A message that names a call id (`CALL-…`) is about that call. The `calls` spoke must cite
  that call when it exists, and answer that it found nothing when it does not.
- `POST /v1/chat` stays stateless and routes nothing.

## The metrics spoke

Data questions are answered **only** from MetricFlow metrics defined in analytics-dbt, through
metrics-gateway's tools (`mcp/metrics-gateway.json`). Nothing else in the system reaches a
warehouse, and there is no raw-SQL tool and no write tool, now or as an additive change —
either would be a new contract decided on purpose.

- **Every number carries its definition and release.** A `metrics` turn cites each query
  whose result reached the model, in `metric_citations`, with the metric's readable
  `definition` and the `sha` that answered — snapshots, like `Citation.filename`. A number in
  a metrics answer with no citation behind it is a defect, not a style choice.
- **`no_match` ends the turn.** Search enforces a score floor on the server; below it the
  answer is that no governed metric answers the question, with empty `metric_citations`.
  There is no fallback to SQL and no fallback to another spoke after routing.
  The floor's value is not promised and is calibrated from the eval.
- **One release, end to end.** The gateway serves exactly the sha in `current.json`, search
  returns only objects of that sha, and every hit and result carries it. Only the indexer
  moves `current.json`, and only after the index for the new sha is ready — so a new metric
  becomes searchable and queryable together, and before the flip it is neither
  (`releases/semantic-release.schema.json`). A swap never fails a query in flight.
- **Guards are the gateway's, not the caller's.** Names are checked against the release,
  filter ops against an allow-list, literals escaped, `{` and `}` refused, at most 500 rows,
  and an engine time limit with cancellation. A refusal is a tool result with
  `isError: true` and a named `error.code`, and no SQL runs.
- **Every tool call is accounted for**: one audit row (tool, arguments, sha, SQL, rows,
  latency, outcome, trace id) and one span in Phoenix project `metrics-gateway`, refusals
  included. The result names both (`audit_id`, `trace_id`).
- **The gateway is not public.** No origin, no auth of its own: inside the cluster only the
  backend may reach it, which is its whole access control. Metrics are organisation data —
  every signed-in account reads the same numbers, as with calls.
- **Projects are routed, never federated.** `olist` (Postgres) and `funnel` (Trino over
  Iceberg) are separate semantic graphs; one query reads one project, and a cross-source
  metric does not exist. A question that needs both gets two cited queries.
- **Identifiers, free text and personal data never enter the index.** Dimension values are
  indexed only for dimensions opted in with `meta: {index_values: true}`.

## Agent steps, progress and capabilities

**Steps.** Every assistant turn records the steps that produced it in `Message.steps`, in the
order they ran: one `route` step (agent `coordinator`, name `coordinate`) first, one
`answer` step last, and between them the spoke's `retrieval` steps and the answering agent's
`tool` calls. A `retrieval` or `tool` step's `name` is a tool `getCapabilities` lists under
that step's `agent`. `summary` is a sentence the server writes for a person; it is not model
output, and it never carries credentials, SQL or another account's data. Steps are stored
with the turn and read back unchanged, like citations. A step that failed without failing
the turn (a gateway refusal, an empty search) is stored with `status: error` and the turn
goes on.

**Progress.** `POST /v1/threads/{id}/messages/stream` is the same turn as
`POST /v1/threads/{id}/messages` — the same gates, the same rate-limit bucket, the same two
messages stored — delivered as Server-Sent Events:

| Event | Data | When |
| --- | --- | --- |
| `step` | `StepEvent` | each step's `started`, then its `completed` under the same `id` |
| `done` | `SendMessageResponse` | once, last, after the turn is stored; its assistant message carries `steps` equal to the completed steps, in order |
| `error` | `ErrorResponse` | once, last, instead of `done`: the turn failed and nothing was stored |

A `:`-comment heartbeat goes out at least every 15 seconds, so an edge with a read timeout
does not cut a long turn. Every refusal is a plain JSON response before the stream opens.
Every hop between the browser and the backend must pass events through as they are written
— not buffered, not compressed. The non-streaming endpoint stays, unchanged, for consumers
that do not want events.

**Capabilities and roles.** `GET /v1/capabilities` names the account's `role`, every spoke the
deployment runs (`agents`), each with its tools, and whether the role may use each; plus what
the role may see (`visibility`). Every account is `member` today, and `member` is allowed
everything and sees steps. The policy behind it lives in the backend; there is no endpoint to
change a role. What it promises now, so the day roles differ is not a contract change:

- **The server enforces, the client only displays.** The coordinator never routes to an agent
  the role may not use (`general` is always allowed and is the floor), and no tool the role
  may not use is called. A client never hides or disables anything on its own judgement.
- **`visibility.steps: false` means absent, not empty** — no `steps` on messages, no `step`
  events — and is decided per request, from the caller's role at the time.
- A consumer must tolerate unknown `role`, agent and tool names.

**Agents per chat.** A chat is created with the agents it may use (`CreateThreadRequest.agents`,
default every agent the role may use; `general` always included) and carries them as
`Thread.agents`. They are fixed at creation — no endpoint changes them, and `patchThread`
ignores the field — so a conversation is never answered by an agent it did not start with.
The coordinator routes a turn only to an agent in both `Thread.agents` and the role's allowed
set; anything else falls to `general`. A client creates the chat when the first message is
sent, so choosing agents is part of starting a conversation.

**Formatting.** An assistant `content` is Markdown — CommonMark plus GFM tables, task lists
and strikethrough. A client renders it as Markdown with raw HTML disabled (shown as text,
never parsed), and leaves `[n]` citation markers resolvable against the turn's citation list.

## Trace correlation

Promised here rather than in `openapi.yaml` for the reason the session cookie already is:
`openapi.yaml` is machine-rewritten by `harvest-contract.py`, so a response header declared
there is dropped at the next re-harvest. This is also not a body or a status, which is all
that file describes.

**`X-Trace-Id` is on every response the API produces** — successes, refusals and failures
alike. Its value is the W3C trace id of the request's root span: 32 lowercase hexadecimal
characters, no dashes.

| Situation | Header |
| --- | --- |
| any API response, tracing enabled | present |
| tracing not configured in that environment | **absent**, never empty |
| `/healthz` | absent — health checks are deliberately not traced |

Three things it promises, and they are narrow on purpose:

- **It identifies a trace, not a request and not a session.** One request produces one
  trace, so the two coincide today; nothing promises they always will, and a consumer must
  not use the value as an idempotency key, a request id or a correlation id of its own.
- **It is safe to show a person and safe to log.** An opaque hex id carrying no account, no
  session and no content. That is what makes it the right thing to put in a support report
  or an error page.
- **It is not authorisation and not a lookup.** Holding one grants nothing. Whether any
  store can still resolve it — and who is allowed to ask — is entirely a property of the
  telemetry backend that environment runs, and there may not be one.

**A consumer must tolerate its absence.** An environment with no telemetry configured is an
ordinary environment, not a broken one, and a client that requires the header to render a
response is a client that breaks the moment tracing is turned off.

**What may NOT be inferred from its presence.** That a trace exists somewhere a person can
open, that it is complete, or that it will still be there later. Export is batched and
lossy by design: a response returns before its spans are written, and a collector that is
unreachable drops them without touching the request. The header says what the id was, not
that anybody kept it.

## What `GET /v1/version` promises

Session-required, and that is the unusual part of an `ops` endpoint. `/healthz` answers
liveness for an anonymous caller and is the endpoint a load balancer polls; this one answers
*which build and which models*, which is deployment information. The one consumer signs in
anyway, so authenticating it costs nothing and keeps that information off an open endpoint.

**It exists so that a consumer can record what it measured by reading it.** That is the whole
reason, and it is a narrow one. A process told its own image tag by a flag records what its
caller believed; a process that reads it records what is serving. `chatbot-eval` copies
`image_tag`, `chat_model`, `embedding_model` and `retrieval_router` into every Phoenix
experiment's metadata, and a wrong value there is not a wrong response — it is a wrong
permanent record of what was measured.

**Every field is a selector or an identifier.** No credential, no connection string, no
endpoint URL, and never a wholesale serialisation of the settings object. That last one is
the implementation to refuse: "report the configuration" is exactly the instruction under
which a secret arrives later, so the seam suite asserts that no field NAME in the body
matches `secret|password|credential|signup_code|aws_access|session_token`. Written against
names rather than values, so it fails on the day such a field is added rather than once it
holds a real key.

**`image_tag` and `git_sha` are null when nothing supplied them**, and null is the answer
rather than a fallback. An application that derives its own build identity — from its
version, its git tree, its hostname — is not reporting one, and the fallback reads as true in
every deployed environment. A consumer must treat null as "unknown" and never as a value.

**What may NOT be inferred.** That the values are still true a moment later: a deploy is not
atomic with a read, and a consumer that pins a measurement to a tag is recording what it saw,
not a guarantee. That they describe the instance that served any other request — behind a
load balancer, they do not. And that a value absent from the response means a default: no
field is ever absent, four of them are nullable instead.

**Retrieval tuning is deliberately NOT here.** `retrieval_top_k`, the score floor and the
fusion weights all change what a recall number means, which is exactly the argument for
adding them, and it is refused: they are internals that must be free to move, and a promise
here would freeze them. `retrieval_router` is promised because it is a behavioural mode
rather than a tuning value — a routing figure produced by a model and one produced by lexical
overlap are not the same measurement, and a reader of two experiments has to be able to tell.
Anything else a consumer turns out to need is a contract change, which is the cost
`docs/adr/0013` accepts on purpose.

## Changing a contract

1. Additive by default. The repos deploy independently, so production will always
   briefly run mismatched versions: new fields optional, new entries alongside old
   ones, removals in a later change once every consumer is updated.
2. One commit, nothing else in the diff. That commit is the freeze point.
3. Record its SHA as `freeze_sha` in the change's `change.yaml`.
4. Only then dispatch. `fanout.sh` extracts `contracts/` at exactly that SHA and gives the
   slices nothing else, so the freeze is a tree rather than a promise.

Two directions arrive at the same place — a reviewed contract, committed alone. They differ
only in where the first draft comes from. **Deciding an interface that does not exist yet**
is hand-written, during `/ship` phase 2. **Promoting something already built** starts from
`./scripts/harvest-contract.py --diff` against the running service, which is the `/realign`
path; an exact spec published at `/openapi.json` beats one inferred from source.

Neither lets the implementation decide. The harvest drafts and classifies — additive versus
breaking, judged by what it would do to a consumer — and refuses to write a breaking change
until you pass `--accept-breaking`, which means you looked. A contract that automatically
matched the implementation could never fail a build, which is the whole thing
`docs/adr/0001` was written to prevent. And review the draft: `operationId` becomes a client
method name, generated prose describes internals, and everything served gets harvested
whether or not you meant to promise it.

## The `/api/` prefix is an asserted invariant, not a convention

`servers[0].url` is `/api`, and every path below it is written as the backend serves it —
so something at the edge must STRIP the prefix. Locally that is Caddy's
`handle_path /api/*`. A cloud edge does not do this for free: an ALB path rule forwards the
original path unless an explicit rewrite is configured.

The failure is silent rather than loud, which is why it is asserted rather than documented.
The frontend answers any unmatched path with the SPA shell and a `200`
(`try_files $uri $uri/ /index.html`), and `smoke.py --contract` checks only that a path,
method and status are declared — never a body. So a rule that never matches `/api/*`
returns `200 text/html` for API calls and any step asserting only a status passes.

Three steps hold it, untagged because these are invariants of *any* origin:

| Step | Asserts |
| --- | --- |
| `api-prefix-reaches-the-api` | `GET /api/healthz` returns JSON, and NOT the app shell |
| `api-prefix-is-not-doubled` | `GET /api/api/healthz` is a 404 |
| `prefix-boundary-is-respected` | `GET /apiary` reaches the app, not the API |

The second is the one that earns its place. Locally the proxy strips one `/api`, the
backend sees `/api/healthz`, and 404 is the pass. If someone makes the backend
prefix-aware instead — `FastAPI(root_path="/api")` — it serves 200 and **this step fails**.
That is how the shortcut is caught from outside, without reading any code, at the moment it
is introduced rather than when someone notices the contract has become a lie.

## Two origins, one suite

A change is asserted twice: against the local stack, and against the deployed origin. The
same suite serves both. `local` and `remote` are the only meaningful tags, and an
**untagged step runs in both** — that default is the point, because it means an ordinary
step is asserted against the deployed environment without anyone having to think about it.

**A difference between origins is expressed as an additional tagged step, never as a
parameterised expectation.** Interpolating the differing fragment of an assertion — a regex
assembled from an environment variable, say — makes the suite unreviewable: a reader can no
longer tell what is being asserted, which destroys the property that makes these files
usable as acceptance criteria. The count of tagged steps is then a visible measure of how
far the two environments have diverged, and a growing count is worth acting on.

**Every remote step against declared API surface asserts a body property, never a status
alone** — see the SPA-fallback trap above. This stays a convention rather than a mechanism,
because the mechanical version would fail legitimate steps like `logout-ends-session`,
which is a `204` with no body.

## What enforces this

- `./scripts/harvest-contract.py --diff` — contract versus what is actually served. Run on
  every deploy by `verify.sh`, before smoke: a structural drift means the suite is about to
  run against something that is not the promise, and that is the right first failure.
- `./scripts/smoke.py --contract` — every asserted request must be declared surface, with a
  declared status. Note what this is *not*: it never inspects `requestBody`, response
  schemas, required fields or types, so a response whose body violates the frozen schema
  passes as long as its status is declared. The harvest gate above is what covers that, and
  `docs/adr/0003` records the residual gap as an accepted cost.
- `./scripts/infra-outputs.py` — every promised output produced and well-typed, checked the
  moment infra deploys, plus `--contract-only` in preflight so an empty contract fails
  before it costs an apply.
- `./scripts/infra-crosscheck.py` — the prefix agrees three ways, and the deployed image
  tags match the submodule SHAs just verified locally.
- each product repo's own `make contract` — note it HARD-FAILS if `openapi.yaml` is
  vendored with no conformance check wired, so vendoring and wiring must land together.

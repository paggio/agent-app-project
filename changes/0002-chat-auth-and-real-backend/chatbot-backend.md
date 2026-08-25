# 0002 — chatbot-backend slice

`POST /v1/chat` answers anonymous callers with a real Bedrock completion. Verified through
the joined origin with an empty cookie jar: `200 {"reply":"giraffe"}`. Your own
`docs/architecture.md` already lists it under known gaps, and `docs/adr/0004` nominated
this as the next change. Close it.

## What to build

- **A reusable "there must be a valid session" dependency**, and `POST /v1/chat` behind
  it. Reusable rather than inline because the intent is that *every* endpoint needing a
  session gets one from a single place; chat is simply the only one currently missing.
  The audit result, so you do not have to redo it: `/healthz` and
  `/v1/auth/{register,login}` are open by design, `/v1/auth/{me,logout}` already resolve
  the session themselves, `/v1/chat` is the only gap. Do not change the posture of any
  endpoint other than `/v1/chat`.
- **Refuse before the model is invoked.** This is the point of the change: an
  unauthenticated request must cost nothing. Authenticating after the graph has run
  produces a correct-looking 401 with the bill already paid, and the smoke step
  `chat-without-a-session-is-refused` asserts `"reply"` is absent from the refusal body
  precisely to catch that ordering.
- **Reuse the existing 401.** Same status, same `{"error":{"code":"AUTH_REQUIRED",…}}`
  envelope, same handler as the other endpoints that already refuse this way. Do not
  invent a second code or a second shape for chat.
- **Refusal must read the server-side session record, not the presence of a cookie.** A
  cookie whose session was deleted by logout is refused. The suite replays a captured
  cookie value after logout to check exactly this.
- **The validation contract does not move.** An empty or oversized `message` from an
  authenticated caller is still `422` in the framework's `detail` shape. Auth is a new
  gate in front of validation, not a replacement for it.
- **Do not add CORS middleware.** The browser reaches this service through a reverse proxy
  on a single origin, and the cross-origin refusal your guards already perform is the CSRF
  control. `Access-Control-Allow-Credentials` with an allowed origin would reopen it. If
  you believe a caller needs it, report that rather than adding it.

## Contract entries this depends on

- `contracts/openapi.yaml` → `postChat`: now carries `security: [{cookieAuth: []}]` and a
  `401` response whose body is `ErrorResponse`. The `200` and `422` responses and the
  `ChatRequest`/`ChatResponse` schemas are unchanged.
- `contracts/openapi.yaml` → `components.securitySchemes.cookieAuth`: the existing
  `apiKey`-in-cookie scheme named `session`. Unchanged — chat now references what
  `getAuthMe` and `postAuthLogout` already reference.
- `contracts/README.md` → "Auth and sessions" for the cookie attributes and the two error
  shapes, and its rule that `422` means malformed-or-against-stated-policy while the
  envelope means well-formed-and-refused.

This is the one non-additive contract change in this brief and it was decided upstream
with its reasons; it is not a mistake to report back. Nothing else in `contracts/` moves.

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] An integration test: no cookie → `401` with code `AUTH_REQUIRED`, and the response
      carries no reply.
- [ ] An integration test: valid session → `200` with a reply.
- [ ] An integration test: session deleted by logout, same cookie replayed → `401`.
- [ ] An integration test: valid session, empty `message` → `422`.
- [ ] A test that proves the model is not invoked on the refusal path — a spy, a fake, or
      a model that raises if called. Asserting the absence of `reply` in the body is the
      weaker outside-in version; this is the one that pins the ordering.
- [ ] `make contract` passes against the frozen `openapi.yaml`, including the new
      `security` and `401` on `postChat`.
- [ ] `make lint`, `make typecheck`, `make test`, `make test-int` pass.
- [ ] `docs/architecture.md` loses "unauthenticated and unthrottled" from its known-gaps
      list and gains the new posture. Your Stop hook blocks the turn if `src/app/api/`
      moves without `docs/` — that is expected, not a bug to route around.
- [ ] The `eval`-marked tests stay excluded from the default run. Nothing in this slice
      needs a real provider.

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys all of them together and runs
`smoke.yaml` against one origin. The steps whose `owner:` is `chatbot-backend` are yours:

- [ ] `chat-without-a-session-is-refused` — no cookie, `401`, code `AUTH_REQUIRED`, and
      no `"reply"` anywhere in the body.
- [ ] `register-a-chat-account` — `201` cold or `409` on a warm volume.
- [ ] `login-establishes-the-session` — `200` and a `session` cookie.
- [ ] `chat-with-a-session-answers` — `200` and a non-empty `reply`. Retried three times
      at three seconds, so a cold model is not read as a failure.
- [ ] `chat-still-validates-the-body` — authenticated, empty `message`, `422` with
      `detail`.
- [ ] `logout-then-chat-is-refused` — logout is `204`.
- [ ] `revoked-session-cannot-chat` — the pre-logout cookie value, replayed, `401`.

These run against your code through a reverse proxy, not against your test doubles, and
a failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- **Deliberately not in this slice: a `429` on `/v1/chat`.** Your `docs/adr/0004` asked
  for it and it is coming, but not here — it is contract surface, and a per-process token
  bucket is not a rate limit on a scaled service, so it needs the shared store your
  `docs/adr/0003` deferred. Do not add throttling to chat in this change; a `429` the
  contract does not declare will fail the control repo's contract check.
- **Merge order.** This repo merges first. An old frontend never calls `/v1/chat` at all,
  so requiring a session breaks no deployed consumer.
- Branch `feat/0002-chat-auth-and-real-backend`. Your own rules forbid editing while HEAD
  is on `main`; the dispatcher creates the branch before you start, so confirm you are on
  it rather than assuming.
- Your `.env` is gitignored, holds live credentials, and is not part of this change.
  Do not read it, copy it, echo it, or reference a value from it in a commit, a test
  fixture, a log line or a docs example. Variable names are fine.

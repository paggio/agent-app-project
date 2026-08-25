# 0002 — frontend slice

`main.tsx` wires `chat: mocks.chat` unconditionally — no env var, no flag, no override —
so every reply the product has ever shown came from `pickReply()` hashing the message and
indexing four canned strings. The backend has served `POST /v1/chat` since before auth
existed, and from this change it requires a session. Point the UI at it.

## What to build

- **An HTTP `ChatClient`**, implemented against the `ChatClient` interface already
  declared in `src/api/client.ts`, exactly as `HttpAuthClient` was implemented against
  `AuthClient`. Same conventions: relative URL under `/api`, `credentials: 'same-origin'`,
  no configurable base URL, every failure crossing the boundary as an `ApiError` with a
  `kind`.
- **Wire it in `main.tsx`** so the real client is what the app uses. `MockChatClient`
  **stays** — it is what the unit tests and the design work run against, exactly as
  `MockAuthClient` stayed. If you keep a query-param escape hatch for the mock, guard it
  behind `import.meta.env.DEV` the way `?mockauth` already is; the production bundle must
  have no path back to a canned reply.
- **Map the interface onto a stateless endpoint, and keep thread state client-side.**
  Read the contract before designing this: the endpoint takes one `message` and returns
  one complete `reply`. It has no threads, no history and no streaming, and the contract
  says conversational surface is explicitly not promised yet. Your interface assumes
  threads and an `AsyncIterable` of `SendEvent`s. Resolve that here, in the client, by
  holding thread state in the browser and emitting the reply as `accepted` → `done` (with
  or without a single `token` carrying the whole text). Do **not** invent
  `/v1/chat/threads`, do not send a thread id the endpoint does not accept, and do not
  report this as a contract gap — mapping the interface onto the stateless endpoint is the
  decided approach for this change. Threads becoming durable is a later change.
  Client-held threads do not survive a reload; that is accepted here, and it is the kind
  of thing that belongs in your architecture doc's known-gaps list.
- **Handle `401` as "sign in", not as "broken".** An unauthenticated chat send maps to the
  `unauthorized` kind and the user ends up at `/login`, the same way a `401` from
  `/v1/auth/me` already routes. A signed-out user must never see a reply — neither a real
  one nor a fabricated one. Keep the existing three-way distinction between signed in,
  signed out, and *we could not reach the server*: a network failure or a `5xx` on a chat
  send is not a sign-out and must not clear the session.
- **A Vite dev proxy.** `vite.config.ts` has no `server.proxy`, so `make dev` on `:5173`
  cannot reach the API at all — which is the only real reason anyone would ask for CORS.
  Proxy `/api` to the backend instead. That preserves the single origin your
  `docs/adr/0001` decided on, keeps cookies host-only and same-site, and needs no
  cross-origin negotiation. Make the upstream overridable by an environment variable with
  a working local default, and add the proxy to `preview` too if that costs nothing.
- **Do not add CORS handling, and do not add a configurable API base URL.** Your
  `docs/adr/0001` closed both, the reverse proxy is what replaces them, and the dev proxy
  above removes the last motivation.

## Contract entries this depends on

- `contracts/openapi.yaml` → `postChat`: `POST /v1/chat`, body `ChatRequest`
  (`message`, 1–8000 characters), `200` → `ChatResponse` (`reply`, complete and
  unstreamed), `422` → `HTTPValidationError`, and now `401` → `ErrorResponse` with
  `security: [{cookieAuth: []}]`.
- `contracts/openapi.yaml` → `components.schemas.ErrorResponse` / `AuthError`: the
  `{"error":{"code","message"}}` envelope, `code` = `AUTH_REQUIRED` for a missing or
  expired session. Per the contract you must tolerate an unknown `code` by falling back to
  `message`, and never switch exhaustively on it.
- `contracts/openapi.yaml` → `servers[0].url` = `/api`: the proxy strips the prefix, so
  every path in the spec is written as the backend serves it and your client must send it
  under `/api`.
- `contracts/README.md` → the two error shapes and the rule that decides which, and the
  session-cookie attributes.

`make contract` regenerates `wire.generated.ts` from the frozen spec and diffs it, so the
`postChat` types are available to you rather than hand-written.

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] Unit tests for the HTTP chat client against a stubbed transport: a `200` produces
      the reply; a `401` produces an `ApiError` of kind `unauthorized`; a network failure
      produces `network`; a `422` produces `invalid`.
- [ ] A test that a signed-out send does not render a reply.
- [ ] `make typecheck`, `make lint`, `make test`, `make contract` pass.
- [ ] `docs/architecture.md` no longer says chat is fixtures, and records the
      thread-state-in-the-browser decision and its cost. Your Stop hook fails the turn if
      `src/api/` or `src/routes/` moves without `docs/` — that is expected.
- [ ] An ADR for the "map a thread-shaped interface onto a stateless endpoint" decision,
      because it is a why rather than a what.

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys all of them together and runs
`smoke.yaml` against one origin. The steps whose `owner:` is `frontend` are yours:

- [ ] `chat-route-deep-links-to-the-app` — `GET /chat` returns the app shell.

**That is deliberately thin, and it is not your acceptance criterion.** Every
HTTP-visible property of this repo was already true while the chat client was a mock, so
the control repo's HTTP suite cannot see this change at all. Your real oracle is
**Playwright against the joined origin**, which the control repo runs as its own stage:

- [ ] A browser test that signs in and sends a message, and asserts the rendered reply is
      **not** one of `MockChatClient`'s canned replies. Assert it came from the backend,
      not merely that some text appeared — a test that accepts any reply passes against
      the mock and proves nothing.
- [ ] A browser test that a signed-out visitor to `/chat` lands on `/login`.

These run against the joined stack, where a real backend answers `/api/*`. Two constraints
that follow from that, and both matter:

1. **They must skip cleanly when there is no backend.** Your own CI brings up this repo
   alone, where `/api/*` has no upstream, and these tests must not fail there. Gate them
   on `/api/healthz` answering, and on the signup code being present in the environment.
   A skipped test in your CI and a running test in the joined stack is the correct
   outcome; a red CI is not.
2. **Credentials come from the environment, never from a literal.** The joined stack
   exports `SIGNUP_CODE` and `SMOKE_PASSWORD`; read those. Register a fresh account per
   run at an address of the form `smoke-0002-<nonce>@auth.test` — `.test` is reserved and
   the control repo refuses any suite that creates an identity outside
   `smoke-*@auth.test`. Do not hardcode a password, and do not reuse a fixed email.

`tests/e2e/auth-stub.ts` stays for the tests that legitimately stub the network; these two
must not use it, because stubbing the API is the exact thing they exist to disprove.

## Notes

- **Merge order: this repo merges second.** The backend's session requirement lands
  first. Both orders happen to be safe — an old UI never calls chat, and a new UI against
  an old backend gets `200` — but this is the order recorded in `STATUS.md`.
- Branch `feat/0002-chat-auth-and-real-backend`. Your own rules forbid editing while HEAD
  is on `main`; the dispatcher creates the branch before you start, so confirm you are on
  it rather than assuming.
- Out of scope: streaming (the contract routes it to a separate endpoint that does not
  exist yet), durable threads, and renaming or deleting conversations.

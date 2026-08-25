# 0002 — A session gates the chat endpoint, and the UI actually calls it

## Why

Three facts, all verified against the running joined stack rather than inferred:

1. **`POST /v1/chat` is open, and it now bills a real model.** `chatbot-backend` PR #4
   put Claude Haiku 4.5 on Bedrock behind `CHAT_MODEL=bedrock` and said so in its own
   words: "Auth or rate limiting on `/v1/chat`… is unauthenticated and unthrottled,
   which was harmless for an echo and is now an open billable endpoint." Through the
   joined origin, with no cookie at all:

   ```
   POST http://localhost:8080/api/v1/chat  {"message":"Reply with only the single word: giraffe"}
   → 200  {"reply":"giraffe"}
   ```

   That is a real Bedrock completion bought by an anonymous caller. Every other endpoint
   that needs a session already has one (`/v1/auth/me`, `/v1/auth/logout`); `/healthz`
   and register/login are open by design. Chat is the whole gap.

2. **The UI never calls it.** `frontend/src/main.tsx` wires `chat: mocks.chat`
   unconditionally — no env var, no flag, no override. Replies come from
   `pickReply()` in `src/api/mock/mock-client.ts`, which hashes the message and indexes
   four canned strings. So the product demo has never once touched the backend, and
   `TODO.md` records the symptom without the cause.

3. **The backend's `.env` already reaches the joined stack, but by accident.** The
   Bedrock reply above happened because Compose resolves `${CHAT_MODEL:-echo}` inside an
   `include:`d file against *that file's* directory `.env` — so
   `chatbot-backend/.env` supplies it and the real environment still outranks it.
   Isolated and confirmed:

   | Layer | `CHAT_MODEL` resolves to |
   | --- | --- |
   | shell sets it | the shell's value |
   | shell unset, `chatbot-backend/.env` sets it | the `.env` value |
   | neither | the compose literal (`echo`) |

   That is exactly the precedence we want and **nothing in this repo says so**, nothing
   asserts it, and it rests on `include:` interpolation scope — undocumented, and one
   Compose release away from changing. Worse, `scripts/dev-env.sh` does not know about
   the file at all: declare a name in *both* `stack/dev.env` and `chatbot-backend/.env`
   and `dev-env.sh` exports the `stack/dev.env` value into the shell, which then
   outranks the backend's `.env` and silently inverts the order. No name overlaps today.
   `chatbot-backend/.env.example` §2 lists five that could.

## Acceptance criteria (these are the oracle)

- [ ] `POST /api/v1/chat` with no session cookie is refused `401` with
      `{"error":{"code":"AUTH_REQUIRED",…}}` and **no model is invoked**.
- [ ] `POST /api/v1/chat` carrying a valid session cookie answers `200` with a
      non-empty `reply`.
- [ ] After `POST /api/v1/auth/logout`, the same cookie is refused `401` — the gate
      reads the server-side session record, not merely the presence of a cookie.
- [ ] `POST /api/v1/chat` with a session but an empty `message` is still `422`, in the
      framework's `detail` shape. Auth does not change the validation contract.
- [ ] The chat deep link `GET /chat` still serves the app shell.
- [ ] **In a browser, at the joined origin, a signed-in user sends a message and the
      rendered reply comes from the backend.** Asserted by Playwright against the joined
      origin, not by an HTTP step — see "A gap in the oracle" below.
- [ ] In a browser, a signed-out user who reaches `/chat` is sent to `/login` rather
      than shown a fabricated reply.
- [ ] `scripts/dev-env.sh` fills a still-unset, non-secret variable from
      `chatbot-backend/.env` after `stack/dev.env`, and neither file can shadow the real
      environment. Asserted by `./scripts/check-docs.py`.
- [ ] `./scripts/check-docs.py` fails if a variable name is declared in both
      `stack/dev.env` and `chatbot-backend/.env`, because that inverts the precedence
      above.
- [ ] No AWS credential value reaches a control-repo process, artifact or log. The
      credentials keep flowing only over compose's `env_file`, and `dev-env.sh` fills in
      from an explicit non-secret allowlist.

## A gap in the oracle, stated rather than hidden

"The UI consumes the real endpoint" is a browser fact. `smoke.py` speaks HTTP, and every
HTTP-visible property of the frontend — the shell is served, `/api/*` is reachable from
the same origin — was already true while the chat client was a mock. So no smoke step
can prove this criterion, and `smoke.yaml` does not pretend to: `smoke.e2e: true`, and
the frontend's Playwright suite carries it. The consequence to know when reading the
report: the frontend's smoke assertion count is thin on purpose, and a green
`smoke.json` alone does **not** prove criterion 6. The e2e stage does.

## Out of scope

- **A `429` on `/v1/chat`.** `chatbot-backend`'s PR #4 nominated it as the next change,
  and it is real contract surface. Left out because authentication already closes the
  hole that matters — an anonymous stranger spending money — and per-account throttling
  needs a shared bucket first: the backend's `docs/adr/0003` records per-process buckets
  as an accepted cost, and a per-process limit on a scaled service is a limit in name
  only. Its own change, after a bucket store is decided.
- **CORS.** Asked for; the answer is no, and it is a decision rather than an omission —
  `docs/adr/0007`. The browser sees one origin by decision (`frontend/docs/adr/0001`),
  the CSRF posture in `contracts/README.md` is *built* on refusing cross-origin unsafe
  methods with `403 AUTH_CROSS_ORIGIN`, and `Access-Control-Allow-Credentials` with an
  allowed origin would deliberately reopen it. The one real motivation — `make dev` on
  `:5173` cannot reach the API — is met by a Vite dev proxy, which *preserves* the single
  origin instead of negotiating around it. That is in the frontend slice.
- **Server-side threads, history and streaming.** The contract promises one stateless
  request and one complete reply, and says conversational surface is "a later, additive
  change and is NOT promised here". The frontend's `ChatClient` interface already assumes
  threads and an `AsyncIterable` of `SendEvent`s, so the real client maps that interface
  onto the stateless endpoint with thread state held client-side. The interface does not
  change, which is what keeps this change small; making threads durable is a contract
  change and its own brief.
- **Deleting `MockChatClient`.** It stays, as `MockAuthClient` did — it is what the unit
  tests and the design work run against.
- **Rotating the credentials in `chatbot-backend/.env`.** Out of this repo's hands, and
  the file is gitignored.
- **Any infra change.** Nothing is provisioned. Note that `bedrock:InvokeModel` is still
  missing from the deployed task role — `chatbot-backend/docs/adr/0004` records it — so
  the first real chat turn in the cloud will fail on authorization. That is an `infra/`
  change and this brief does not touch it.

## Contract changes

`contracts/openapi.yaml`: `postChat` gains `security: [{cookieAuth: []}]` and a `401`
`ErrorResponse`. Version `1.1.0` → `1.2.0`.

**This one is not additive, and that is a decision.** Requiring a session on an endpoint
that did not require one breaks any existing consumer by definition. It is accepted
because the only consumer does not call the endpoint at all (fact 2 above), there is no
deployed environment yet, and the alternative — a second authenticated path alongside an
open one — would leave the open billable endpoint serving forever, which is the entire
problem. Either merge order is safe: an old frontend never calls chat, and a new frontend
against an old backend gets `200` and works.

Frozen by a commit that touches `contracts/` and nothing else. Its SHA is recorded as
`freeze_sha` in `change.yaml` and deliberately not repeated here — nothing reads it from
this file, and two copies of a SHA is one copy that can go stale.

## Deployment

- Local stack and smoke: always. `./scripts/iterate.sh 0002-chat-auth-and-real-backend`
  brings up all repos together and runs `smoke.yaml` against the single origin, plus the
  Playwright stage because `smoke.e2e` is true.
- Infra deploy: **no**. Nothing new is provisioned; postgres, the session table and the
  Bedrock code path all already exist. `manifest.py` would reject `infra: true` without
  an infra slice, and there is correctly no infra slice here.

## Slices

- `chatbot-backend.md`
- `frontend.md`

The control repo's own half — the contract freeze, `scripts/dev-env.sh`, `stack/dev.env`,
`scripts/check-docs.py`, `docs/adr/0006`, `docs/adr/0007` — is not a slice, because
`contracts/` and the joined stack are owned here and no dispatched agent may touch them.

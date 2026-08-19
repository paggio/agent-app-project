# 0001 — frontend slice

The first real HTTP this repo has ever spoken. Chat stays mocked; only auth becomes real.

## What to build

**A real `AuthClient`, implemented against the interface already declared in
`src/api/client.ts`.** That interface is the contract this slice honours — `signIn`,
`signOut`, `currentSession` exist, components and routes already depend on them, and
nothing outside `src/api/` may learn that a network appeared. Add `HttpAuthClient` beside
the mock as another implementation of the same interface; do not restructure the boundary
to accommodate it. `src/api/provider.tsx` stays the swap point and `src/main.tsx` stays the
one line that chooses.

- URLs are **relative** — `/api/v1/auth/...`. No configurable base URL, per `docs/adr/0001`.
- `fetch` must carry credentials so the cookie is sent and stored. The session is an
  `httpOnly` cookie: it is invisible to script, there is no token to read, store or attach,
  and any code that tries to inspect it is a misunderstanding of the design.
- `src/api/` remains the only place that may speak HTTP. ESLint enforces it via
  `no-restricted-globals`; do not widen that rule.

**Two additions to `src/api/client.ts`, both additive.**

- `register(...)` on `AuthClient`, returning `Session`. The contract exposes registration
  and this slice ships a screen for it, so the interface needs it. Take a single input
  object rather than four positional strings — it carries email, password, signup code and
  an optional display name.
- New `ApiErrorKind` members for the failures that currently have nowhere to go. `409`
  (email already registered), `403` (signup closed, or refused as cross-origin) and `429`
  (too many attempts) are all distinct things a user must be told, and mapping them onto
  the existing `'server'` would produce "something went wrong" where the honest answer is
  "that email is already registered". Extend the union; do not overload a member.

**Error mapping, in one place.**

- `401` → `unauthorized`, `403` → refused, `409` → conflict, `429` → rate-limited,
  `5xx`/unparseable → `server`, transport failure → `network`, abort → `aborted`.
- Semantic failures arrive as `{"error": {"code", "message"}}`. `message` is written to be
  shown to a user, so show it. **Tolerate an unknown `code`** by falling back to `message`
  — the contract adds codes additively and requires consumers not to switch exhaustively.
- `422` arrives in a different shape, `{"detail": [...]}`, and carries the password-policy
  failures. Turn it into something a person can act on — "at least 12 characters" — rather
  than rendering a validation array. One parser handles both shapes; nothing above
  `src/api/` should know there are two.
- `ApiError` stays the only error type crossing this boundary.

**`currentSession()` maps three outcomes onto three different things, and this is the
subtle part of the slice.**

| Backend says | `currentSession()` | What the user is told |
| --- | --- | --- |
| `200` + user | a `Session` | nothing; they are signed in |
| `401` | `null` | they need to sign in |
| unreachable, `5xx`, unparseable | **throws** `ApiError` | something is broken, try again |

A `401` from `/v1/auth/me` is a normal answer meaning "nobody" — not an error, not
something to log at error level, and not a reason to show a failure state. Every
first-time visitor produces one.

**The route guard on `/chat`, which must branch three ways rather than two.**
`docs/architecture.md` already names the shape: a `beforeLoad` on the chat routes calling
`AuthClient.currentSession()`.

- `Session` → render.
- `null` → redirect to `/login`.
- **thrown `ApiError` → render a retryable error and do NOT redirect.** This is the
  criterion the whole design exists for. Redirecting on a transport failure tells the user
  "you were signed out" when nothing of the kind happened, and `/login` cannot work either
  if the backend is unreachable — so the redirect replaces a fixable error with a dead end
  and destroys the real reason. Get this wrong and a two-second blip logs everybody out.

**Session state needs exactly one owner.** Put it under TanStack Query + `src/api/`, like
threads, so a route change does not refetch on every navigation and `signOut` can
invalidate it. Add the row to the state-ownership table in `docs/architecture.md`; that
table is load-bearing in this repo, and a slice that adds shared state without appearing
in it has broken the rule the table exists to state.

**`/register`, and a sign-out control.**

- A `/register` route: email, password, signup code, optional display name. It must render
  the three refusals distinguishably — code wrong, email taken, password too weak — because
  a single "registration failed" makes all three unfixable by the person facing them.
  Link it from `/login` and back.
- Sign-out: calls `signOut()`, invalidates the session, lands on `/login`. Put it wherever
  the signed-in user's identity is shown; `display_name` is always present and never empty,
  so it is safe to render without a fallback.
- `/login` already exists and already goes through `AuthClient`. It should need very little
  — that is the point of the existing boundary. On success, go where the user was trying to
  go if the guard sent them, otherwise `/chat`.

**`MockAuthClient` stays, and stays exhaustive.** It is what makes component tests,
Playwright fixtures and screenshots runnable with no server, and it must keep satisfying
`AuthClient` — including the new `register` and the new error kinds, with the same refusal
semantics as the real client so a test proves something about production behaviour. Do not
delete it, do not narrow it to a stub, and do not make any test depend on a running backend.

The wiring in `src/main.tsx` becomes mixed for the first time: real `auth`, mock `chat`.
`createMockClients` currently returns both, so compose the pair explicitly rather than
teaching the mock factory about a real client. Keep `?fail` working.

**Do not touch chat.** `MockChatClient` continues to serve fixtures. Attaching threads to a
user is the next change and it needs this one frozen first.

**Documentation.** Update `docs/architecture.md`: the routing table's "`/login` is not
enforced" section is now false and should describe the three-way guard; add the session row
to state ownership; replace the "These types are not yet from `contracts/`" section; and
remove `No route guard on /chat, no token handling, no sign-out` from "Known gaps",
alongside the part of "No backend" that stops being true for auth.

## Contract entries this depends on

- `contracts/openapi.yaml` → `POST /v1/auth/register` (201, 403, 409, 422, 429)
- `contracts/openapi.yaml` → `POST /v1/auth/login` (200, 401, 403, 422, 429)
- `contracts/openapi.yaml` → `POST /v1/auth/logout` (204, 403)
- `contracts/openapi.yaml` → `GET /v1/auth/me` (200, 401)
- `contracts/openapi.yaml` → `IdentityResponse`, `User`, `ErrorResponse`, `AuthError`,
  `RegisterRequest`, `LoginRequest`
- `contracts/README.md` → § "Auth and sessions", for what the cookie is and why there is no
  token, no header and no CSRF token to attach

Note the naming seam: the wire is `snake_case` (`display_name`) and this codebase is
`camelCase` (`displayName`). `src/api/` is where that translation belongs and the only
place it may happen.

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

**You must also vendor them.** Copy `contracts/openapi.yaml` into this repo's `contracts/`
and wire a real conformance check into `make contract` in the same change. That target
currently hard-fails the moment `contracts/` holds anything but its README — deliberately,
so vendoring and verifying cannot drift apart. Generating types from the vendored spec and
type-checking the client against them is the cheapest honest option. Whatever you pick, it
must actually fail when the spec and the client disagree; a check that cannot fail is worse
than the `SKIP` it replaces.

## Verification

- [ ] `HttpAuthClient` satisfies `AuthClient` structurally, and so does `MockAuthClient` —
      enforced by the type system, not by a comment
- [ ] Unit: each status maps to the right `ApiErrorKind`; an unknown `error.code` still
      yields the server's `message` rather than a generic string
- [ ] Unit: `currentSession()` returns `null` on `401` and **throws** on `500` and on a
      transport failure — the three-way distinction, tested as three cases
- [ ] Component tests still run against `MockAuthClient` with no server
- [ ] Playwright: `/chat` with no session redirects to `/login`
- [ ] Playwright: `/chat` with a session renders and does not redirect
- [ ] Playwright: with `/v1/auth/me` stubbed to fail, `/chat` shows a retryable error and
      the URL is still `/chat` — asserting the URL is what actually proves no redirect
      happened
- [ ] Playwright: sign-out returns to `/login`, and `/chat` afterwards redirects
- [ ] Playwright: registration shows three distinguishable messages for wrong code, taken
      email and weak password
- [ ] `make contract` passes with the spec vendored and a real check wired
- [ ] The repo's own gates pass (`.claude/hooks/gate.sh`) — including no raw hex under
      `src/components/` or `src/routes/`, so any new colour comes from `tokens.css`

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys both repos together and runs `smoke.yaml`
against one origin. Only two steps carry `owner: frontend`, because cross-repo smoke is an
HTTP client with no JS runtime — it cannot watch a route guard decide anything. The guard
behaviour is yours to prove in Playwright, and the acceptance criteria in `BRIEF.md` say so
explicitly.

- [ ] `spa-serves-login-deep-link` — `GET /login` returns the app shell
- [ ] `spa-serves-register-deep-link` — `GET /register` returns the app shell

`nginx.conf` already has `try_files $uri $uri/ /index.html`, so these should pass the day
you add the route. They are regression guards, not new work: without an SPA fallback a deep
link 404s while in-app navigation to the same route works perfectly, which is a bug that
only ever shows up through the proxy. Keep them true.

These run against your code through a reverse proxy, not against your test doubles, and
a failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- **Merge second.** The route guard cannot pass until `/v1/auth/me` answers, so the backend
  slice deploys first. A frontend deployed ahead of it sends every visitor to `/login` and
  then fails there.
- There is no token anywhere in this slice. No `localStorage`, no `Authorization` header, no
  refresh flow, no CSRF token to fetch or echo — `SameSite=Lax` plus a server-side origin
  check covers it, and the browser attaches the cookie on its own. If a step seems to need
  one, re-read `contracts/README.md` before writing it.
- Same-origin is what makes all of this work: the app and the API share `localhost:8080`
  behind the proxy. Never introduce an absolute API URL "to test against the backend
  directly" — it would be cross-origin, the cookie would not be sent, and the failure looks
  like broken auth rather than a broken URL.

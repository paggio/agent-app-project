# 0001 — Accounts and sessions

## Why

Everything in this system currently belongs to nobody. `MockChatClient` serves the same
fixture conversations to every visitor, `/chat` is reachable by anyone who knows the URL,
and `/login` is a form that signs you into a client-side variable and forgets on reload.
The backend has no notion of a user at all: `POST /v1/chat` is stateless by design and
`postgres` sits in compose with an empty `migrations/` directory.

That blocks the next several changes rather than merely looking unfinished. Persisted
threads need an owner to hang off. Reading positions want to follow a person between
devices instead of living in one browser's `localStorage`. Rate limiting a real model
provider needs somebody to attribute cost to. None of those can be designed until
"who is this" has one answer that both repos agree on.

The affected population is small and specific: everyone who opens this application sees
another person's fixtures, and the moment it is deployed anywhere reachable, so does
everyone who finds it.

## Decisions this change makes

Recorded because the reasoning is the expensive part, and a decision without its reason
gets re-litigated in three repos.

| Decision | Choice | Because |
| --- | --- | --- |
| Session mechanism | `httpOnly` cookie, opaque id, server-side record | `AuthClient` has nowhere to put a token — `signIn` returns `Session`, `currentSession()` takes no argument — so cookies need no interface change while a bearer token forces one. Same-origin behind the proxy means `SameSite=Lax` just works. And `EventSource` sends cookies but cannot set an `Authorization` header, so this stays correct when chat starts streaming. |
| Session lifetime | 7 days idle, sliding, no `Max-Age` | Closing the browser ends the client-side half; the server record is the authority. Sliding means active people are not logged out mid-conversation. |
| Session storage | Postgres, beside `users` | One datastore, one migration path, one new failure mode rather than two. Revocation is a `DELETE`, and deleting a user takes their sessions with it by FK cascade — with Redis that is a per-user set maintained by hand. |
| Slide throttle | rewrite `expires_at` at most hourly | Otherwise every authenticated `GET` becomes a write transaction. |
| Registration | open endpoint, gated by a shared signup code | Needs no roles, no admin user and no email — none of which exist — while keeping the endpoint safe to expose. Roles are out of scope, so "admin-created only" has no admin to be. |
| Hashing | argon2id, parameters pinned explicitly | Library defaults drift between releases; pinned parameters are encoded in the hash, so they can be raised later and upgraded on next successful login. |
| Password policy | 12–128 chars, NFKC, no composition rules, top-1000 blocklist | Composition rules push everyone onto the same predictable substitutions. The blocklist is what actually stops `password1234`, which length alone admits. |
| CSRF | `SameSite=Lax` + `Origin`/`Sec-Fetch-Site` check, no token | Costs the frontend nothing — no token to read, no header to attach — and closes the sibling-subdomain hole `Lax` leaves open, since `SameSite` is scoped to the registrable domain rather than the origin. |
| Brute force | in-process token bucket, `429` + `Retry-After` | An unthrottled password endpoint is a guessing oracle. Per-container state is wrong above one replica; that is the moment to move it to a shared store, not now. |
| `/v1/auth/me` | `{"user": {...}}`, nested | Leaves an additive slot for session metadata under its own key instead of mixing altitudes later. |
| Error shapes | `422` keeps `detail`; envelope for 401/403/409/429 | Does not re-open what is already frozen for `/v1/chat`, and closes the "bespoke error envelope" gap the backend's architecture doc flagged. |

Two consequences worth stating out loud because they look like bugs otherwise:

- **`Secure` is environment-conditional.** Python's `http.cookiejar` will not return a
  `Secure` cookie over HTTP and has no localhost exemption, so hardcoding it breaks
  `smoke.py` against the local origin while browsers paper over the difference. Smoke
  asserts `HttpOnly`, `SameSite=Lax` and `Path=/`, never `Secure`.
- **`409 AUTH_EMAIL_TAKEN` is an enumeration oracle, accepted.** It is only reachable by a
  caller who already holds the signup code, which is what makes it tolerable. The signup
  code is therefore checked *before* the email is looked up. Login leaks nothing: unknown
  email and wrong password return an identical `401 AUTH_BAD_CREDENTIALS`.

## Acceptance criteria (these are the oracle)

Each line names how it is checked. Steps in `smoke.yaml` are cross-repo; Playwright flows
live in the frontend repo, because smoke is an HTTP client with no JS runtime and cannot
observe a route guard deciding anything.

**Sessions exist and behave**

- [ ] Registering with a valid signup code returns `201`, a `session` cookie and the new
      user — smoke `register-creates-account`, `login-sets-session-cookie`
- [ ] The session cookie carries `HttpOnly`, `SameSite=Lax` and `Path=/` — smoke
      `session-cookie-attributes`
- [ ] `GET /v1/auth/me` with that cookie returns `200` and the registered email — smoke
      `me-identifies-the-user`
- [ ] `POST /v1/auth/logout` returns `204`, and `me` immediately afterwards returns `401`
      with `AUTH_REQUIRED` — smoke `logout-ends-session`, `me-after-logout-is-401`
- [ ] Logging out twice is `204` both times, not an error — smoke `logout-is-idempotent`
- [ ] A session survives a backend restart, because the record is in Postgres rather than
      in process memory — manual: `./scripts/stack.sh rebuild backend`, then `me` still
      returns `200` with the same cookie jar

**Credentials are handled correctly**

- [ ] A wrong password returns `401 AUTH_BAD_CREDENTIALS` — smoke `login-rejects-wrong-password`
- [ ] An unknown email returns a byte-identical `401` body to a wrong password, so the
      endpoint reveals nothing about which addresses exist — smoke
      `login-rejects-unknown-email-identically`
- [ ] A password under 12 characters is refused with `422` naming the `password` field —
      smoke `register-rejects-short-password`
- [ ] A 12+ character password on the common list is refused with `422` — smoke
      `register-rejects-common-password`
- [ ] A rejected password is never echoed back in the `422` body. The frozen
      `ValidationError` schema has an `input` field that the framework populates with the
      offending value by default, so this needs a handler that redacts password fields —
      smoke `register-rejects-short-password`, `register-rejects-common-password`
- [ ] No response body, log line or error message ever contains a password or a hash —
      smoke `me-identifies-the-user` excludes both, plus a backend unit test over every
      auth response and a grep of the captured container log in the `runs/` evidence
- [ ] Stored hashes are argon2id with the pinned parameters — backend unit test on the
      hash prefix

**The gates hold**

- [ ] A wrong or absent signup code returns `403 AUTH_SIGNUP_CLOSED` and creates nothing —
      smoke `register-rejects-wrong-signup-code`
- [ ] A `POST` carrying a foreign `Origin` is refused `403 AUTH_CROSS_ORIGIN` before it
      reaches the rate limiter — smoke `cross-origin-login-is-refused`
- [ ] Repeated failed logins for one email reach `429` with a `Retry-After` header, and a
      different email is unaffected — smoke `login-throttles-after-repeated-failures`,
      `throttle-is-scoped-to-the-email`
- [ ] No `GET` in the API mutates state — backend review checklist item, and the contract
      states it as an invariant

**The frontend tells the three states apart**

- [ ] `/chat` with no session redirects to `/login` — Playwright
- [ ] `/chat` with a valid session renders the chat surface and does not redirect —
      Playwright
- [ ] When `/v1/auth/me` is unreachable or returns `5xx`, `/chat` renders a retryable error
      and **does not** redirect to `/login` — Playwright with the route stubbed to fail.
      This is the criterion the whole guard design exists for: a network blip must not read
      to a user as "you were signed out".
- [ ] Signing out returns to `/login` and a subsequent `/chat` visit redirects — Playwright
- [ ] `/login` and `/register` are reachable as deep links, not just by client-side
      navigation — smoke `spa-serves-login-deep-link`, `spa-serves-register-deep-link`
- [ ] `MockAuthClient` still satisfies `AuthClient` and the component tests still run with
      no server — the frontend's own test suite

## Out of scope

Named so that no agent helpfully adds them.

- **Password reset and any email sending.** There is no mail transport and no plan for one.
  A forgotten password is a support problem in this milestone; say so rather than building
  half a reset flow.
- **OAuth, social login, SSO, magic links.**
- **MFA / TOTP / recovery codes.**
- **Roles, permissions, admin users, an admin surface.** Every account is equivalent.
- **Account management**: changing an email, changing a password, deleting an account,
  listing or revoking other sessions, "sign out everywhere".
- **Attaching threads or reading positions to a user.** This change establishes identity
  and nothing else; `MockChatClient` continues to serve chat. Ownership is the next change
  and it needs this one frozen first.
- **Email verification.** A registered address is taken on trust.
- **Shared-store rate limiting.** The bucket is per-container, stated as a known limit.
- **`Secure` cookies in the local stack**, per the reasoning above.

## Contract changes

`contracts/openapi.yaml`: `info.version` `1.0.0` → `1.1.0`. Four new paths —
`POST /v1/auth/register`, `POST /v1/auth/login`, `POST /v1/auth/logout`,
`GET /v1/auth/me` — plus schemas `RegisterRequest`, `LoginRequest`, `IdentityResponse`,
`User`, `ErrorResponse`, `AuthError`, and a `cookieAuth` security scheme. Purely additive:
`/healthz` and `/v1/chat` are untouched, so a backend serving 1.1.0 still satisfies every
existing consumer.

`contracts/README.md`: a new "Auth and sessions" section carrying the promises OpenAPI
cannot hold — the cookie's attribute set, the sliding lifetime, the CSRF posture, the
no-mutating-`GET` invariant, and the rule that decides which of the two error shapes
applies. It is there rather than in the spec because `harvest-contract.py --write`
rewrites the spec's structure from the running service and would drop them.

Frozen as of `3710209` — *contract: freeze the auth surface — register, login, logout, me*.
Recorded as `freeze_sha` in `change.yaml`, which is where `fanout.sh` reads it.

<!-- If this line has no SHA, the change is not ready to fan out. fanout.sh enforces it. -->

## Deployment

- Local stack and smoke: always. `./scripts/iterate.sh 0001-auth` brings both repos up
  together and runs `smoke.yaml` against the single origin — the only arrangement where
  the cookie actually crosses the proxy, which is the seam this change is really about.
- Infra deploy: **no.** Nothing new is provisioned. `postgres` already exists in compose
  with a healthcheck and a volume, and `DATABASE_URL` is already wired into the backend's
  environment — this change is the first code to read it. `deploy.infra` stays `false` and
  there is no infra slice.
- Two new environment variables the backend needs and the deployment must supply:
  `SIGNUP_CODE` and `SESSION_COOKIE_SECURE`. Neither may ever be committed with a real
  value.

**One task belongs to this repo and to no slice.** `stack/compose.yml` must pass
`SIGNUP_CODE` through to the backend service, the same way it already overrides the proxy's
`BACKEND_UPSTREAM` — the backend cannot write that join itself, because a product repo may
not name the arrangement it is joined into. `smoke.yaml` reads the same variable from the
environment and `smoke.py` dies on an undefined one rather than guessing, which is the
right failure: a suite that silently used the wrong code would report "registration is
closed" as though the backend were broken. Do it when the change ships, not while planning
— `stack/` is deployment wiring, and this session writes contracts and plans only.

## Slices

- `chatbot-backend.md` — accounts, sessions, the four endpoints, the two guards
- `frontend.md` — the real `AuthClient`, the route guard, `/register`, sign-out

No `infra.md`: see Deployment.

## Merge order

Backend first, and it is backward compatible on its own — the new endpoints are additive
and nothing existing changes behaviour, so a deployed backend with no frontend consumer is
harmless. Frontend second, because its route guard cannot pass until `/v1/auth/me` answers.
A frontend deployed first would redirect every visitor to `/login` and fail there.

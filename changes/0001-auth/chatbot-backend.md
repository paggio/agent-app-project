# 0001 — chatbot-backend slice

Accounts, sessions, and the four auth endpoints. You are the repo that owns identity;
nothing else in the system knows what a user is until this lands.

## What to build

**Persistence — the first code in this repo to read `DATABASE_URL`.**

- Two tables. `users`: opaque id, normalised email, password hash, display name,
  timestamps. `sessions`: id, `user_id` referencing `users` with `ON DELETE CASCADE`,
  `expires_at`, `created_at`, `last_seen_at`.
- Email uniqueness is on the **normalised** form (trimmed, lower-cased), so
  `Foo@Example.com` and `foo@example.com` cannot both exist. Normalise on write and
  compare normalised.
- **Store a hash of the session id, not the id itself.** `sha256` is enough — the id is
  128 bits of entropy, not a password, so it needs no slow hash. Look up by hash. This
  costs nothing and means a leaked database dump does not hand over live sessions.
- `migrations/` is empty and has no tooling. Pick the simplest thing that runs
  migrations before the app serves and is idempotent on re-run — numbered `.sql` files
  with a small applier is entirely sufficient here and needs no new dependency. If you
  reach for a migration framework, justify it in `docs/`. Whatever you choose, a cold
  `docker compose up` on an empty volume must arrive at a serving app with the schema
  present, unattended.
- Expired sessions must never authenticate — put `expires_at > now()` in the lookup
  itself rather than filtering in Python, so there is no path that forgets. Also sweep
  expired rows periodically; without a sweep the table only grows.

**Password handling.**

- argon2id via `argon2-cffi`. Pin the parameters explicitly rather than inheriting library
  defaults, which drift between releases: `m=19456` KiB, `t=2`, `p=1` is the OWASP floor
  and the intended baseline. The parameters are encoded in the stored hash, so raising
  them later is possible — support that by re-hashing on the next successful login when
  the stored parameters are below current settings.
- Policy: 12–128 characters after NFKC normalisation, no composition rules, and rejected
  if it appears in a bundled common-password list (top ~1000 is the intent). Enforce all
  three as **validation**, so they surface as `422` in the framework's `detail` shape.
  The error envelope is for refusals, not for malformed input — the rule is in
  `contracts/README.md`.
- **A rejected password must not appear in the `422` response.** The framework populates
  `ValidationError.input` with the offending value by default, and the frozen schema
  permits that field, so the default behaviour leaks the password straight back to the
  caller. Install a validation-error handler that redacts `input` for password fields.
  Two smoke steps assert this with a canary value.
- On an unknown email, still perform a verify against a fixed dummy hash before returning
  `401`. Otherwise the response time distinguishes "no such account" from "wrong
  password" and the identical body is cosmetic.

**The four endpoints**, exactly as `contracts/openapi.yaml` declares them.

- `POST /v1/auth/register` — check the signup code **before** looking the email up. That
  ordering is the reason `409` is acceptable at all: it keeps account enumeration behind
  the gate. Creates the account and establishes a session in the same response.
- `POST /v1/auth/login` — returns the identity alongside the cookie so a caller needs no
  follow-up request. Unknown email and wrong password return an identical status, code and
  message.
- `POST /v1/auth/logout` — deletes the session row and clears the cookie. Idempotent:
  `204` with no session, `204` twice in a row, never an error.
- `GET /v1/auth/me` — `200` with the identity, `401 AUTH_REQUIRED` without. Treat `401`
  as an ordinary answer, not a fault: it must not log at error level, because every
  first-time visitor produces one.

**Cookie and session semantics.** `contracts/README.md` § "Auth and sessions" is
authoritative; it is a promise, not advice. In particular:

- Attributes: `HttpOnly`, `SameSite=Lax` **set explicitly**, `Path=/`, no `Max-Age`.
- `Secure` is driven by a new setting and must be **off** for the local HTTP stack.
  Hardcoding it on makes every session-carrying smoke step fail, because Python's
  `http.cookiejar` will not return a `Secure` cookie over HTTP and has no localhost
  exemption. On is correct wherever the origin is HTTPS.
- Lifetime: 7 days idle, sliding. Rewrite `expires_at` on an authenticated request only
  if `last_seen_at` is more than an hour old, so a read does not become a write every
  time.

**Two guards.**

- *Origin check*, as middleware on unsafe methods (`POST`/`PUT`/`PATCH`/`DELETE`): if
  `Origin` or `Sec-Fetch-Site` is present and does not indicate same-origin, refuse
  `403 AUTH_CROSS_ORIGIN`. If **neither** header is present, allow — a browser cannot be
  made to omit `Origin` on a cross-origin POST, so that branch only ever holds non-browser
  clients, which were never the CSRF threat model. Smoke asserts both directions; a guard
  that refuses everything passes the negative test, so `correct-origin-is-accepted` is as
  load-bearing as `cross-origin-login-is-refused`.
- *Rate limit*, an in-process token bucket: 10 attempts per 15 minutes per normalised
  email, and a deliberately generous per-IP limit — on the order of 100 per 15 minutes.
  Exhausted is `429 AUTH_RATE_LIMITED` with a `Retry-After` in seconds. A successful login
  clears that email's bucket.
  - **Per-IP must stay generous or you will throttle the smoke suite itself.** Everything
    arrives through one proxy, so unless you resolve the real client address every request
    in the run shares a source. The suite makes roughly twenty failing attempts on purpose.
  - Behind the proxy, the client address comes from `X-Forwarded-For`. Take the
    **rightmost** entry, not the leftmost: the proxy appends the address it actually saw,
    so anything to the left is caller-supplied and forgeable. This is only safe because
    exactly one trusted proxy fronts the service.
  - Ordering: origin check first, then the per-IP limit, then validation, then the
    per-email limit. Rejecting cross-origin before the limiter means a hostile page cannot
    burn down a victim's attempt budget; letting validation run before the per-email limit
    means a malformed body is not counted as a guess.

**Configuration.** Two new settings, read from the environment like everything else in
`core/config.py` — never from a file, never with a committed real value.

- `SIGNUP_CODE` — **fail closed.** When unset or empty, `register` returns
  `403 AUTH_SIGNUP_CLOSED` for every request. A deployment that forgets the variable gets
  closed registration, not open registration.
- `SESSION_COOKIE_SECURE` — boolean, default off for local dev.

**Structure.** The module map in `docs/architecture.md` is exact on purpose and this change
does not fit inside it. Extend it deliberately rather than smuggling persistence into
`core/`: add the layer(s) you need, add the rows to the table, and state the new import
rules. Two existing invariants must survive intact:

- `graph/` learns nothing about users, sessions or HTTP. `run_chat` stays the
  strings-in/strings-out seam. Auth is not a graph concern in this change.
- `create_app()` remains the only composition root, and nothing is constructed at import
  time. The database engine and the session store are built there and injected, exactly
  as the chat model is.

**Do not touch `/healthz`.** It is frozen as process liveness that says nothing about
dependencies, and compose depends on that. Postgres becoming a real dependency is not a
reason to start probing it there — a readiness endpoint would be new contract surface, so
if you think one is needed, STOP and report it.

**Documentation.** Update `docs/architecture.md`: the module map, the wire format section,
the boundaries list, and the "Known gaps" entries that this change makes false — `no auth`
and `postgres and redis are in docker-compose.yml but nothing reads them` are both now
wrong for postgres. Redis stays unused; say so.

## Contract entries this depends on

- `contracts/openapi.yaml` → `POST /v1/auth/register` (201, 403, 409, 422, 429)
- `contracts/openapi.yaml` → `POST /v1/auth/login` (200, 401, 403, 422, 429)
- `contracts/openapi.yaml` → `POST /v1/auth/logout` (204, 403)
- `contracts/openapi.yaml` → `GET /v1/auth/me` (200, 401)
- `contracts/openapi.yaml` → `RegisterRequest`, `LoginRequest`, `IdentityResponse`, `User`,
  `ErrorResponse`, `AuthError`, `cookieAuth`
- `contracts/README.md` → § "Auth and sessions": cookie attributes, sliding lifetime, CSRF
  posture, the no-mutating-`GET` invariant, and which of the two error shapes applies
- unchanged and must stay so: `GET /healthz`, `POST /v1/chat`

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

**You must also vendor them.** Copy `contracts/openapi.yaml` into this repo's
`contracts/` and wire a real conformance check into `make contract` in the same change.
That target currently hard-fails the moment `contracts/openapi.yaml` exists with no check
behind it — deliberately, so vendoring and verifying cannot drift apart. The check should
compare the app's generated OpenAPI against the vendored file for the paths, statuses and
schemas above.

## Verification

- [ ] Unit: password policy accepts a 12-char passphrase, rejects 11 chars, rejects a
      common-list entry; the stored hash is argon2id with the pinned parameters
- [ ] Unit: a rejected password appears in no `422` response body
- [ ] Unit: unknown email and wrong password produce byte-identical `401` bodies
- [ ] Unit: the origin check allows a request with no `Origin`, allows a same-origin one,
      refuses a foreign one
- [ ] Unit: the bucket refuses the 11th attempt for one email and still admits the first
      for another
- [ ] Unit: sliding expiry does not rewrite `expires_at` when `last_seen_at` is recent, and
      does when it is stale
- [ ] Integration (`integration` marker): register → login → me → logout → me over HTTP
      against the composed app
- [ ] Integration: a session issued before the app restarts still authenticates after it,
      which is what putting sessions in Postgres bought
- [ ] `make contract` passes with the spec vendored and a real check wired
- [ ] A cold `docker compose up` on an empty volume reaches a serving app with the schema
      applied, unattended
- [ ] The repo's own gates pass (`.claude/hooks/gate.sh`), including `mypy --strict` and
      the `S` (bandit) ruff rules over the new code

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys both repos together and runs `smoke.yaml`
against one origin. The steps whose `owner:` is `chatbot-backend` are yours — seventeen of
the nineteen:

- [ ] `register-creates-account` — registers with a valid code. Accepts `201` **or** `409`
      on purpose: the suite must be re-runnable against a stack left up, where the account
      already exists.
- [ ] `login-sets-session-cookie` — `200`, a `session` cookie, and the right email in the body
- [ ] `session-cookie-attributes` — `HttpOnly`, `SameSite=Lax`, `Path=/` on the `Set-Cookie`.
      Not `Secure`; see above for why asserting it would fail a correct implementation.
- [ ] `me-identifies-the-user` — the cookie identifies the account, and the body contains
      no hash or password material
- [ ] `logout-ends-session` / `logout-is-idempotent` — `204`, then `204` again with no session
- [ ] `me-after-logout-is-401` — `AUTH_REQUIRED` immediately after, proving the record was
      deleted rather than left to expire
- [ ] `login-rejects-wrong-password` / `login-rejects-unknown-email-identically` — the same
      `401` and the same code for both, so login is not an enumeration oracle
- [ ] `register-rejects-short-password` / `register-rejects-common-password` — `422`, and the
      submitted value absent from the response
- [ ] `register-rejects-wrong-signup-code` — `403 AUTH_SIGNUP_CLOSED`
- [ ] `uninvited-email-was-not-created` — the refused registration created nothing, so the
      gate was real and not cosmetic
- [ ] `cross-origin-login-is-refused` / `correct-origin-is-accepted` — both directions
- [ ] `login-throttles-after-repeated-failures` — repeated wrong passwords reach `429` with a
      numeric `Retry-After`. The step retries until it is refused, so a limiter that never
      engages fails here.
- [ ] `throttle-is-scoped-to-the-email` — a different address still gets `401`, not `429`.
      A global limiter is a denial-of-service dressed as a security control.

These run against your code through a reverse proxy, not against your test doubles, and
a failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- **Merge first.** This slice is backward compatible standing alone: the endpoints are
  additive, `/healthz` and `/v1/chat` do not change, and no consumer exists yet. Deploying
  it before the frontend slice is harmless. The reverse is not — the frontend's route guard
  cannot pass until `/v1/auth/me` answers.
- `SIGNUP_CODE` and `SESSION_COOKIE_SECURE` must reach the backend container in the joined
  local stack. That passthrough lives in the control repo's `stack/compose.yml`, which you
  cannot edit — declare the variables and their local-dev defaults in this repo's own
  compose file and README, and the control repo will match them.
- Redis stays unused. Sessions are in Postgres by decision; see `BRIEF.md`. Do not
  opportunistically wire Redis up because it happens to be running.
- The bucket is per-container and therefore wrong above one replica. That is a stated,
  accepted limit for this change — record it in "Known gaps" rather than solving it.

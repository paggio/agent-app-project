# contracts/ — owned here, consumed everywhere

The interface between the three product repos. Edited only in this repo, only in a
sequential single-purpose session, and frozen by commit before any implementation
starts. Each product repo vendors a copy and verifies conformance in its own CI.

| File | Interface |
| --- | --- |
| `openapi.yaml` | HTTP |
| `events/*.schema.json` | async messages |
| `infra-outputs.yaml` | what infra promises the app repos (ARNs, URLs, secret names) |

`openapi.yaml` describes the API as the backend serves it — paths without the `/api`
prefix, which the proxy strips before forwarding. `events/` is still an empty skeleton;
fill it in when the first real event exists, because an invented contract is worse than no
contract.

`infra-outputs.yaml` is real as of `version: 1`. It has **no environment dimension on
purpose** — the environment lives in the invocation (`make -C infra outputs ENV=staging`),
so the names are invariant and only the values move. A per-environment block would let
staging promise less than prod, which institutionalises the drift it claims to describe.
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
`403`, `409` and `429`. The rule that decides which: **422 means the request was malformed
or violated a stated policy, the envelope means the request was well-formed and refused.**
Password-policy failures are therefore `422`, because the policy is stated — they are
enforced as validation, not as a semantic refusal. Consumers must tolerate an unknown
`error.code` by falling back to `message`; codes are added additively and exhaustive
switching on them will break.

## Changing a contract

1. Additive by default. The repos deploy independently, so production will always
   briefly run mismatched versions: new fields optional, new entries alongside old
   ones, removals in a later change once every consumer is updated.
2. One commit, nothing else in the diff. That commit is the freeze point.
3. Record its SHA as `freeze_sha` in the change's `change.yaml`.
4. Only then fan out.

## Which way round

Two skills, one destination — a reviewed contract, committed alone. They differ only in
where the first draft comes from.

| | Skill |
| --- | --- |
| The interface does not exist yet; you are deciding it | `freeze-contract` |
| It exists and works; you are promoting it to a promise | `align-contract` |

Neither lets the implementation decide. `harvest-contract.py` drafts and classifies —
additive versus breaking, judged by what it would do to a consumer — and refuses to
write a breaking change until you pass `--accept-breaking`. A contract that
automatically matched the implementation could never fail a build, which is the whole
thing `docs/adr/0001` was written to prevent.

## The `/api` prefix is an asserted invariant, not a convention

`servers[0].url` is `/api`, and every path below it is written as the backend serves it —
so something at the edge must STRIP the prefix. Locally that is Caddy's
`handle_path /api/*`. A cloud edge does not do this for free: an ALB path rule forwards the
original path unless an explicit rewrite is configured.

The failure is silent rather than loud, which is why it is asserted rather than documented.
The frontend answers any unmatched path with the SPA shell and a `200`
(`try_files $uri $uri/ /index.html`), and `smoke.py --contract` checks only that a path,
method and status are declared — never a body. So a rule that never matches `/api/*`
returns `200 text/html` for API calls and any step asserting only a status passes.

Four steps hold it, and most are untagged because these are invariants of *any* origin:

| Step | Asserts |
| --- | --- |
| `api-prefix-reaches-the-api` | `GET /api/healthz` returns JSON, and NOT the app shell |
| `api-prefix-is-not-doubled` | `GET /api/api/healthz` is a 404 |
| `api-prefix-rewrite-strips-exactly-one` | the same, against the deployed origin, owned by infra |
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

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
prefix, which the proxy strips before forwarding. `events/` and `infra-outputs.yaml` are
still empty skeletons; fill them in when the first real interface exists, because an
invented contract is worse than no contract.

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
| `Secure` | wherever the origin is HTTPS | **Environment-conditional, not promised unconditionally.** The local stack is `http://localhost:8080`, and Python's `http.cookiejar` refuses to return a `Secure` cookie over HTTP with no localhost exemption — so a hardcoded `Secure` breaks `smoke.py` at the seam while browsers hide the problem. Smoke asserts the three attributes above and never this one. |
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

## What enforces this

- `./scripts/harvest-contract.py --diff` — contract versus what is actually served
- `./scripts/smoke.py --contract` — every asserted request must be declared surface,
  with a declared status. Run on every deploy by `verify.sh`.
- each product repo's own `make contract` — note it HARD-FAILS if `openapi.yaml` is
  vendored with no conformance check wired, so vendoring and wiring must land together.

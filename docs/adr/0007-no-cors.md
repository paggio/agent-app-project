# 0007 — No CORS. The browser sees one origin, and the CSRF posture depends on it

**Status:** accepted
**Date:** 2026-08-21

## Context

CORS was proposed during change 0002 as a thing worth adding "if it makes sense". It does
not, and the reason is worth writing down once, because the request will recur: CORS is
what an engineer reaches for when a browser call fails cross-origin, and the correct fix
in this system is almost always to stop being cross-origin.

Three existing decisions already point the other way, and none of them was made carelessly:

- `frontend/docs/adr/0001` decided the browser sees **one** origin via a reverse proxy,
  and settled two consequences explicitly: relative URLs only, and *"there is no
  configurable API base URL, and adding one would reintroduce the problem this decision
  removes"*.
- `contracts/README.md` § "The `/api/` prefix is an asserted invariant" holds the same
  property for a deployed edge, with three untagged smoke steps that run against every
  origin — including the cloud one. The deployed topology is same-origin too, by
  assertion, not by hope.
- `contracts/README.md` § "CSRF posture" makes `SameSite=Lax` the primary control and adds
  a same-origin check on unsafe methods: `403 AUTH_CROSS_ORIGIN` when `Origin` or
  `Sec-Fetch-Site` is present and does not indicate same-origin. `chatbot-backend`
  implements that as middleware on every path.

Against that, CORS is not a neutral addition. `Access-Control-Allow-Credentials: true`
with an allowed origin is a deliberate instruction to the browser to send our session
cookie from a page we do not serve — which is precisely the request the origin check
exists to refuse. Adding both leaves two mechanisms with opposite intent in one request
path, and the permissive one is the one that decides.

There is a real problem underneath the request, and it is not a CORS problem. The
frontend's `vite.config.ts` has no `server.proxy`, so `make dev` on `:5173` cannot reach
the API at all. That is the daily friction that makes CORS look necessary.

## Decision

**No CORS headers, in any service, in any environment.** No `CORSMiddleware`, no
`allow_origins`, no preflight handling. A cross-origin browser call to this API is a
misconfiguration to fix at the edge, not a negotiation to permit.

The dev-server gap is closed with a **Vite dev proxy** instead — `/api` proxied to the
backend from the dev server, which makes `:5173` same-origin exactly as Caddy makes
`:8080` same-origin. Same property, no new posture. It lands in change 0002's frontend
slice.

## Consequences

**Easier.** One posture in one place. The session cookie stays host-only and
`SameSite=Lax` with no exceptions to reason about. No preflight cache to debug, no
`Vary: Origin` interacting with a CDN, and no allowlist that quietly grows. `smoke.py`'s
cookie jar keeps working, because there is no cross-origin case for it to model.

**Harder, and accepted:**

- **Every consumer must be same-origin, forever, or this decision gets revisited.** A
  mobile app, a partner integration or a second web property cannot be served by adding a
  header; it needs a decision here first. That is the intended cost — it makes "who may
  call this API" a reviewed question rather than a config value.
- **The edge must strip `/api`, in every environment**, and a cloud edge does not do it
  for free. Already covered: three asserted smoke steps, and `api-prefix-is-not-doubled`
  catches the tempting shortcut of making the backend prefix-aware instead.
- **Non-browser clients get no benefit and no obstacle.** CORS was never their concern,
  and the origin check deliberately allows a request that presents neither `Origin` nor
  `Sec-Fetch-Site`, since a browser cannot be made to omit them.

## What would change the answer

Written down so a future reader can tell a real trigger from a recurrence of the same
request:

**The frontend being served from a different host than the API** — an S3/CloudFront
domain in front of the app with the API on its own ALB hostname. Then the cookie is
cross-site, `SameSite=Lax` stops sending it, and no amount of CORS alone fixes that: it
needs `SameSite=None; Secure`, a strict origin allowlist with credentials, and a fresh
CSRF control to replace the one `SameSite` was providing. That is a contract change and an
ADR, not a middleware toggle.

The cheaper answer, and the one to reach for first, is to put both behind one distribution
so the app and `/api/*` share a hostname — which is what `docs/infra-interface.md` and the
prefix invariant already assume.

## Alternatives considered

- **CORS with a strict allowlist and credentials.** Rejected. It contradicts the origin
  check in the same request path, and the two together are less safe than either alone
  because the permissive one wins.
- **CORS in dev only.** Rejected, and it is the most tempting option. It makes the
  development origin structurally different from production, so the class of bug it hides
  is exactly the class this harness exists to catch — a seam that works everywhere except
  where it matters. The dev proxy gives the same convenience with the same topology.
- **A configurable API base URL in the frontend.** Rejected upstream by
  `frontend/docs/adr/0001` for reasons that still hold; it is the same decision wearing
  different clothes.

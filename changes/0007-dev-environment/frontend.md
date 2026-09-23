# 0007 — frontend slice

The app is about to run in Kubernetes behind CloudFront. Two images leave this repo, both
built from it, both runnable as non-root. Nothing a person sees changes.

## What to build

1. **The SPA image runs unprivileged on 8080.** Base the runtime stage on
   `nginxinc/nginx-unprivileged:1.27-alpine`, `listen 8080`, keep `/healthz` and the
   existing cache headers. `docker-compose.yml`'s `expose` follows.

2. **The proxy becomes an image of its own: `Dockerfile.proxy`.** `FROM caddy:2-alpine`,
   the `Caddyfile` baked in, runs as a non-root user, listens on 8080, writes nothing
   outside `/data` and `/config`. The upstreams are environment variables with the local
   defaults: `{$BACKEND_UPSTREAM:backend:8000}` and `{$FRONTEND_UPSTREAM:frontend:8080}`.
   Add `X-Content-Type-Options: nosniff` and `Referrer-Policy: strict-origin-when-cross-origin`
   to every response. The request-body limit must accept 10 MiB uploads. The proxy must
   preserve the incoming `Host` (Caddy does by default; do not override it) — the backend's
   CSRF guard compares it with `Origin`.

3. **`docker-compose.yml` builds `proxy` from `Dockerfile.proxy`** instead of mounting the
   Caddyfile into `caddy:2-alpine`, so the joined local stack runs the image `dev` runs.
   The service names `frontend` and `proxy` are load-bearing for the control repo — keep them.

4. **CI builds both images** on every PR (`docker build`, no push).

5. **`.github/workflows/dev-push.yml`**: a caller of
   `Paggio/agent-app-project/.github/workflows/dev-push.yml@main` on `issue_comment`
   `/dev-push` or `/dev-push-frontend`, passing `product_pr: frontend@<pr head sha>` and
   `secrets: inherit`. It is a few lines; the logic lives in the control repo.

## Contract

Nothing in `contracts/openapi.yaml` moves. `/api/` is still stripped by the proxy —
`contracts/README.md` § "The `/api/` prefix is an asserted invariant".

## How this slice is verified

The steps with `owner: frontend` in the change's `smoke.yaml`: the headers above on the
app shell and on an API response through the proxy, locally and through CloudFront, plus
every existing baseline step, which now runs through the new proxy image. Your own gates
and `make e2e` still pass.

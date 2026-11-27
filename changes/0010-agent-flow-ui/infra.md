# 0010 — infra slice

## What to build

The app now streams one endpoint as Server-Sent Events:
`POST /api/v1/threads/{id}/messages/stream`, `Content-Type: text/event-stream`, a heartbeat
comment at least every 15 s, a turn lasting up to a few minutes. Every hop must pass events
through as they are written — not buffered, not compressed — and not cut a long turn.

- CloudFront `/api/*` behaviour: confirm against AWS docs whether `compress = true` can buffer
  or compress `text/event-stream`; if it can, turn compression off for `/api/*` (the proxy
  already gzips JSON). `origin_read_timeout` 60 s must exceed the heartbeat gap (it does);
  keep it, or say why it moves.
- ALB: `idle_timeout` 300 s, already above the heartbeat gap — confirm, no change expected.
- No new resources, outputs or IAM. If the edge needs nothing, the change is the docs below
  plus whatever confirms it (a plan showing no diff is fine).

## Contract entries this depends on

- `contracts/README.md` → § "Agent steps, progress and capabilities" ("every hop between the
  browser and the backend must pass events through as they are written")

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] `terraform validate` / the repo's gates.
- [ ] The decision on `compress` recorded with its source.

## Smoke — what this slice is actually judged on

The steps whose `owner:` is `infra`:

- [ ] `a-turn-streams-through-the-edge` (remote only) — through CloudFront on dev, the stream
      arrives with `content-type: text/event-stream` and its `step` and `done` events intact.

## Documentation

- `docs/architecture.md` — request lifecycle: the SSE endpoint, which hop's timeout bounds it,
  and the compression decision.

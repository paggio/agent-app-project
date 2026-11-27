# 0010 — frontend slice

## What to build

1. **Live progress.** `HttpChatClient.send` posts to `POST /api/v1/threads/{id}/messages/stream`
   (`fetch` + a `ReadableStream` SSE parser in `src/api/` — `EventSource` cannot POST) and maps
   events onto `SendEvent`: add a `step` case carrying `StepEvent`; `done` from the `done` event;
   an `error` event throws `ApiError` exactly like a failed send. Refusals before the stream are
   the same JSON errors as today. While a turn runs, a progress region (`role="status"`,
   `aria-live="polite"`, accessible name "Agent progress") lists each step as it starts — label,
   agent, summary — with a spinner on running steps and a tick / cross when completed, plus an
   overall "Working…" indicator before the first event. The reply replaces it on `done`.
2. **Agent flow after the reply.** Each assistant turn with `steps` gets an "Agent flow" toggle
   (a button, `aria-expanded`). Open, it shows the steps as an ordered timeline — agent badge,
   label, summary, status, duration — and each step expands to its detail (name, kind, start
   time). Read from the transcript, so it survives a reload. No `steps` → no toggle. Unknown
   `kind` / agent values render generically.
3. **Markdown.** Render assistant `content` as GFM (e.g. `react-markdown` + `remark-gfm`) with
   raw HTML disabled — never `rehype-raw`, never `dangerouslySetInnerHTML`. Code blocks keep
   today's styling; `[n]` markers still point at the turn's sources. User turns stay as typed.
4. **Session panel.** Always visible in the chat view (collapsible on narrow screens): the
   role from `GET /api/v1/capabilities`, each agent with an Allowed / Not allowed badge, and its
   tools with the same badges. Not-allowed items are shown and marked, never hidden. Render
   what the server says; decide nothing from `role`. If `visibility.steps` is false, show no
   progress list or flow toggle (the server also sends none).
5. **The proxy streams.** `Caddyfile`: `encode` must not compress `text/event-stream` (match
   out that type), and the stream passes through unbuffered (`flush_interval -1` on the API
   `reverse_proxy` if needed). The mock client gets fixture steps and capabilities with one
   not-allowed agent and tool.

## Contract entries this depends on

- `contracts/openapi.yaml` 1.9.0 → `postThreadMessageStream`, `getCapabilities`, `AgentStep`,
  `StepEvent`, `CapabilitiesResponse`, `Visibility`, `Message.steps`, `User.role`
- `contracts/README.md` → § "Agent steps, progress and capabilities" (event order, Markdown
  with raw HTML off, tolerate unknown values, the client displays and never enforces)

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] Unit: SSE parser (split chunks, heartbeats, `error` event), progress list states, flow
      panel, Markdown (bold, list, table; `<img onerror>` stays text), session panel badges.
- [ ] Stub e2e (`tests/e2e/*-stub.ts`): a slowed stream shows the progress region with a running
      step before the reply; a reply with `**bold**`, a list and a GFM table renders `strong`,
      `li`, `table`; `<img src=x onerror=alert(1)>` renders as text and adds no `img`; a
      not-allowed agent and tool are marked.
- [ ] Real-backend e2e (`tests/e2e/real-backend.spec.ts`, run by the control repo against the
      joined stack, `CHAT_MODEL=bedrock`, so a turn takes seconds):
  - sending uses `…/messages/stream` (assert the request); the "Agent progress" region is
    visible with at least one step before the reply appears, then gives way to the reply;
  - the "Agent flow" toggle opens a timeline whose first step is the coordinator and last is
    the answer; opening a step shows its detail; it is still there after a reload;
  - asking "Reply with a bulleted Markdown list of three colours" renders at least two `li`
    in the assistant turn (bold/table/raw-HTML cases live in the stub suite, which controls
    the reply text);
  - the session panel shows role `member` and agents `general`, `documents`, `calls` with
    their tools, all Allowed.
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`)

## Smoke — what this slice is actually judged on

The steps whose `owner:` is `frontend`:

- [ ] `a-turn-streams-through-the-proxy` — the stream reaches the origin through Caddy with
      `content-type: text/event-stream`, its `step` and `done` events intact.

Plus the Playwright suite above (`smoke.e2e: true`). The assertions belong to the control
repo: fix the cause, never the assertion.

## Documentation

- `docs/architecture.md` — the stream in the API boundary (`SendEvent.step`), Markdown
  rendering, the session panel, the proxy's SSE handling; drop the "no streaming" and "not
  markdown" gaps.
- `README.md` if a command or flag changed.

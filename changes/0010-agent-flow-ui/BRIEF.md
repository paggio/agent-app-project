# 0010 — agent flow in the UI

## Why

A reply arrives after seconds of silence, as plain text, with no sign of which agents and
tools produced it or which ones this person may use. Users cannot tell a slow turn from a
stuck one, cannot see how an answer was reached, and read Markdown as raw asterisks. Roles
do not exist yet, but the day they do, permissions and visibility must already be server-side
data the UI renders — not a UI rewrite.

## Acceptance criteria (these are the oracle)

Server — smoke, through the single origin:

- [ ] `GET /api/v1/capabilities` refuses a request without a session (401 `AUTH_REQUIRED`), and
      with one answers `role: member`, `visibility.steps: true`, and the agents `general`,
      `documents`, `calls` (and `metrics` where the gateway runs) all `allowed: true`, with the
      tools `search_documents`, `search_calls` and the six gateway tools listed under them.
- [ ] `GET /api/v1/auth/me` carries `user.role: member`.
- [ ] `POST /api/v1/threads/{id}/messages/stream` refuses without a session (401), for a chat
      that is not the caller's (404 `THREAD_NOT_FOUND`) and for an empty message (422), as JSON.
- [ ] With a session it answers 200 `text/event-stream`: `step` events with `started` before
      `completed`, a `coordinate` step and an `answer` step, then one `done` whose assistant
      message carries `steps`.
- [ ] The stored transcript (`GET /api/v1/threads/{id}`) returns those `steps` on the assistant
      turn, `coordinate` first and `answer` last.
- [ ] The non-streaming `POST …/messages` also stores and returns `steps`.
- [ ] A turn naming a call id is routed to `calls` and its steps include `search_calls`.
- [ ] Remotely, the stream reaches the browser's origin through CloudFront with the same events.

Per-chat agents (amended 2026-11-27):

- [ ] `POST /api/v1/threads` with `agents: [general, documents]` creates a chat whose
      `thread.agents` is exactly those; with no `agents` it is every allowed agent
      (`general`, `documents`, `calls`, `metrics`); an unknown name is 422 and creates nothing.
- [ ] The agents are fixed: a `PATCH` sending `agents` changes nothing, and `GET` returns
      the same list.
- [ ] In a chat without `calls`, a turn naming a call id is not routed to `calls` and has no
      `search_calls` step.

Browser — the frontend's Playwright suite against the joined stack (`smoke.e2e`):

- [ ] Sending a message uses the stream endpoint; while it runs a progress region
      (`role="status"`) lists each step as it starts, with a spinner on the running one and the
      step's label and summary; it is replaced by the reply when `done` arrives.
- [ ] Every assistant turn with `steps` has an "Agent flow" control; opening it shows the steps
      in order — agent, label, summary, status, duration — and opening one step reveals its
      detail. It survives a reload (read from the transcript), and a turn without `steps` shows
      no control.
- [ ] Asked for a bulleted Markdown list, the real assistant's reply renders as `<li>` items.
      Against the stub (fixed reply text): `**bold**`, a list and a GFM table render `<strong>`,
      `<li>`, `<table>`; `<img src=x onerror=…>` renders as text and creates no `<img>`.
- [ ] The chat view always shows the session panel: the role, every agent from
      `/v1/capabilities` with an allowed / not-allowed badge, and each agent's tools likewise.
      A not-allowed agent or tool (stub suite) is visibly marked, not hidden.
- [ ] A new chat shows "Agents for this chat" as tick boxes, one per allowed agent, all
      ticked; `general` ticked and disabled (always on); a not-allowed agent shown unticked
      and disabled (stub). Unticking one and sending creates the chat with exactly the ticked
      agents (the `POST /api/v1/threads` body says so).
- [ ] Once the first message is sent the selection is locked: the tick boxes are gone, and the
      conversation shows its agents as a read-only list for as long as it is open, after a
      reload too (read from `Thread.agents`).

## Out of scope

- **Assigning or editing roles, a second role, an admin UI.** No requirement for one yet;
  `role`, `allowed` and `visibility` are the seam it will plug into, and it is server-side
  policy, not contract.
- **Token streaming of the reply text.** Progress is per step; streaming tokens doubles the
  event surface and a tool-calling agent's partial text is often discarded. Additive later.
- **A request-level oracle for incremental delivery.** `smoke.py` reads the stream after it
  ends; the only seam evidence is the browser seeing a step before the reply (local, Bedrock).
  Through CloudFront it rests on the infra slice's config and its own check.
- **Model-written step commentary.** Summaries are deterministic server sentences; another
  model call per step costs latency and money for prose.
- **Choosing tools per chat, or changing a chat's agents later.** Agents only; tools follow
  their agent. Fixed at creation so a transcript is never answered by an agent the person did
  not start with — a different set is a new chat.
- **Changing the eval.** New fields are additive; chatbot-eval reads nothing that moved.

## Contract changes

`contracts/openapi.yaml` 1.9.0 and `contracts/README.md` § "Agent steps, progress and
capabilities", all additive: `Message.steps` (`AgentStep`), `User.role`,
`POST /v1/threads/{thread_id}/messages/stream` (SSE: `step` / `done` / `error`, heartbeats),
`GET /v1/capabilities`, `CreateThreadRequest.agents` / `Thread.agents` (per-chat agents,
fixed at creation; re-frozen at `3e749c6`). Assistant `content` is declared Markdown, rendered with raw HTML off.

## Deployment

- Local stack and smoke: always. `./scripts/iterate.sh 0010-agent-flow-ui`.
- Infra deploy: yes — shipped means deployed together (`docs/adr/0002`), and the stream must
  survive CloudFront → ALB → proxy, which only `dev` can show. `deploy.infra: true`, `dev`.

## Slices

- `chatbot-backend.md` — steps, the stream, capabilities, role policy and enforcement, per-chat agents, Markdown prompts.
- `frontend.md` — live progress, the flow panel, Markdown rendering, the session panel, the agent picker, the proxy.
- `infra.md` — the edge passes `text/event-stream` through unbuffered.

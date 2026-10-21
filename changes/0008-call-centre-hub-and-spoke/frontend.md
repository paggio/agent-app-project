# 0008 — frontend slice

## What to build

Assistant messages gain two optional fields: `route` (`documents` | `calls` | `general`, and
possibly values you do not know yet) and `call_citations` (sources that are call-centre
calls: `marker`, `call_id`, `started_at`, `queue`, `agent_name`, `snippet`).

- Regenerate the wire types from the vendored 1.7.0 (`make contract`).
- Render `call_citations` as the turn's sources, the way document citations render: marker,
  call id, queue, agent, local start time, snippet. Same "the assistant was given this"
  wording rules as document citations — never "verified".
- A small, quiet indicator of the route on an assistant turn (e.g. "Searched calls",
  "Searched your documents"; nothing or a neutral label for `general`). Absent or unknown
  `route` renders nothing.
- No calls browsing page, no call detail view: out of scope.

### Documentation, skills, agents

- Update `docs/architecture.md`, `README.md`, `CLAUDE.md` for the new rendering and types.
- Replace `.claude/skills/example-skill`, `.claude/agents/example-agent.md` and the example
  rule with real ones, e.g. a skill `regenerate-wire-types` (vendored spec → generated types
  → typecheck → where renderers break) and an agent `a11y-reviewer` for rendered components
  against `docs/design-tokens.md`.
- Make this repo's gate fail when `src/` changed against `origin/main` and none of `docs/`,
  `README.md`, `CLAUDE.md` did.

## Contract entries this depends on

- `contracts/openapi.yaml` → `Message.route`, `Message.call_citations`, `CallCitation`,
  `listCalls` (proxied under `/api/` like every API path — no proxy change expected).

The contracts are FROZEN. If this slice appears to require a contract change, STOP and report
it rather than working around it.

## Verification

- [ ] unit/component tests: a `calls` turn renders its call sources; a `documents` turn is
      unchanged; absent and unknown `route` render no indicator.
- [ ] a Playwright test against the joined origin: sign up, read the newest call id from
      `GET /api/v1/calls` (the simulator publishes one at start), ask "What was call <id>
      about?", and see that call id and its queue rendered as a source.
- [ ] the repo's own gates pass, including the new docs check.

## Smoke — what this slice is actually judged on

`the-calls-api-is-reached-through-the-proxy` (JSON, never the app shell) and the e2e suite
(`smoke.e2e: true`). The assertions belong to the control repo: fix the cause, never the
assertion.

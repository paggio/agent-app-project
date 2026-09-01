# 0005 — status

## Contract freeze

- SHA: `dfbb48f8f081c08ccda14d07928c299f01928a81`
- Frozen: 2026-09-01

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0005-observability-phoenix` | https://github.com/Paggio/chatbot-backend/pull/8 | ☐ | ☐ |
| control (this repo) | `feat/0005-observability-phoenix` | https://github.com/Paggio/agent-app-project/pull/13 | ☐ | ☐ |

No frontend or infra row: neither repo changes. See BRIEF.md § Out of scope.

Merge order: **chatbot-backend first.** It is backward compatible on its own — a response
header nobody reads yet, and two new local-dev services. The control repo's PR carries the
suite that asserts them, so merging it first leaves `main` with a suite that fails against
the backend on `main`.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
- **verified-local** — 20260901T113130Z, 1 attempt(s)
- report: `changes/0005-observability-phoenix/runs/20260901T113130Z/report.md`
<!-- iterate:end -->

## Out-of-band checks

The criteria `smoke.py` cannot reach — BRIEF.md § "A gap in the oracle". Run against the
same stack the suite passed against, not asserted from configuration.

| Criterion | Oracle | Result |
| --- | --- | --- |
| 8 — traces survive a restart | `make phoenix-durability` | **PASS.** `0225d2bb…` present before and after `restart phoenix`. |
| 9 — logs carry the trace id | the same target, plus by hand | **PASS.** Header `88076823718bd2cf87d4a5732ca7aa17` and the `trace_id` on both `app.api.errors` and `uvicorn.access` records are the same string. |
| 10–13 — disabled, unreachable, no reader, no SaaS | chatbot-backend's own tests | **PASS.** 288 passed, 2 skipped; `typecheck`, `lint` and `contract` green. |

## Blockers

- None. One thing a reviewer should know rather than a blocker: the run that produced this
  used `CHAT_MODEL=echo`. The credentials in `chatbot-backend/.env` are expired, so a
  Bedrock run 500s on every model-bearing step — in `smoke/baseline.yaml` as much as here,
  and unrelated to this change.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`
- [ ] `/realign` — and decide there whether the trace steps are durable enough to promote
      into `smoke/baseline.yaml`. They assert a service no other change depends on, so the
      answer is not automatically yes.

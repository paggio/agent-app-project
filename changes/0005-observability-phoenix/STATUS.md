# 0005 — status

## Contract freeze

- SHA: `dfbb48f8f081c08ccda14d07928c299f01928a81`
- Frozen: 2026-09-01

## Amended, 2026-09-02 — `/ship-iterate`

The first version was verified-local and its PRs were open when a look at a real trace
produced four changes. Nothing had merged, so this supersedes rather than adds.

| Was | Is | Why |
| --- | --- | --- |
| five spans per HTTP request | one | four were ASGI plumbing — `evidence/trace-has-asgi-send-receive-spans.png` |
| the root span carried `http.*` only | `user.id`, `session.id`, `input.value` | a trace could not say who asked, or what |
| bodies were not captured, so nothing needed redacting | credentials redacted before any body reaches a span | capturing a body puts `/v1/auth/login` into a store with a UI. New risk, arriving with the feature that creates it |
| no standing account | `DEV_ACCOUNT_EMAIL` / `DEV_ACCOUNT_PASSWORD` in `stack/dev.env`, seeded at startup | signing in meant inventing an account each time |

Plus one thing that was already true and is now written down and enforced:
**`make down` leaves nothing behind, Phoenix included.** Measured first — 33 traces, then
`make down && make up`, then the project gone — so `docs/adr/0011` and the
`check-docs.py [clean-slate]` gate record and defend a property rather than repairing one.
The gate was confirmed to block a host bind mount and an `external: true` volume, and to
pass once both were reverted.

**No re-freeze.** `dfbb48f` stands. Span attributes are not contract, and the seeded account
adds no endpoint, field or status — nothing crossing a repo boundary moved.

**What it cost, stated because a diff will not show it.** Two rules the first slice brief
stated absolutely are now exceptions with reasons: one line in `api/dependencies.py` may
stamp `user.id`, because the account id exists nowhere else; and redaction moved from "out
of scope" to mandatory, because the thing that made it unnecessary is gone. Both are named
in the slice rather than quietly relaxed.

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
| 12 — traces survive a restart | `make phoenix-durability` | **PASS.** `0225d2bb…` present before and after `restart phoenix`. |
| 14 — logs carry the trace id | the same target, plus by hand | **PASS.** Header `88076823718bd2cf87d4a5732ca7aa17` and the `trace_id` on both `app.api.errors` and `uvicorn.access` records are the same string. |
| 15–18 — disabled, unreachable, no reader, no SaaS | chatbot-backend's own tests | **PASS.** 288 passed, 2 skipped; `typecheck`, `lint` and `contract` green. |

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

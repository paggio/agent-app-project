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
- **verified-local** — 20260902T094706Z, 1 attempt(s)
- report: `changes/0005-observability-phoenix/runs/20260902T094706Z/report.md`
<!-- iterate:end -->

## Out-of-band checks

The criteria `smoke.py` cannot reach — BRIEF.md § "A gap in the oracle". Re-run against the
amended build, not carried over from the first version.

| Criterion | Oracle | Result |
| --- | --- | --- |
| 12 — traces survive a restart | `make phoenix-durability` | **PASS.** `b1aa0e0c…` present before and after `restart phoenix`. |
| 13 — `down` is a clean slate | `check-docs.py [clean-slate]`, plus a measurement | **PASS.** Gate confirmed to block a host bind mount and an `external: true` volume (exit 1) and to pass once reverted (exit 0). Measured separately: 33 traces, `make down && make up`, project gone. |
| 14 — logs carry the trace id | `make phoenix-durability`, plus by hand | **PASS.** Two log records carry the id the response returned. |
| 15–18 — disabled, unreachable, no reader, no SaaS | chatbot-backend's own tests | **PASS.** 315 passed, 2 skipped — 27 more than the first version. `typecheck`, `lint`, `contract` green. |

Read by hand off the amended build, because these are what the amendment was for:

- A chat turn is **8 spans**: one root plus the seven LangGraph spans. It was 12 — root,
  one `http receive`, three `http send`, and the graph.
- The root span carries `user.id`, `session.id` and
  `input.value = {"message": "Who won the 1998 world cup?"}`.
- A sign-in span carries `input.value = {"email": "dev@auth.test", "password": "[redacted]"}`.
  The real password appears nowhere in it.

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

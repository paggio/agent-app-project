# 0007 — status

## Contract freeze

- SHA: recorded in `change.yaml`
- Frozen: 2026-09-23

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| frontend | `feat/0007-dev-environment` @ `e7a092a` | [frontend#8](https://github.com/paggio/frontend/pull/8) | ☑ | ☐ |
| infra | `feat/0007-dev-environment` @ `0742451` | [infra#1](https://github.com/paggio/infra/pull/1) | ☑ | ☐ |
| agent-app-project | `feat/0007-dev-environment` | [#24](https://github.com/paggio/agent-app-project/pull/24) | ☑ | ☐ |

Merge order: frontend (the proxy image is backward compatible locally) → infra →
agent-app-project, then `/realign`, which pins and redeploys `dev` from the lock.

## Deploy verification

<!-- iterate:begin -->
- **verified-local** — 20260923T132833Z, 1 attempt(s)
- report: `changes/0007-dev-environment/runs/20260923T132833Z/report.md`
<!-- iterate:end -->

### Remote — `verified`

- dev-push run 35900953903 on the final heads: **58 passed, 0 failed, 8 of 8 from
  `smoke.yaml`**, through `https://d3560p6j05etw0.cloudfront.net`. Evidence:
  `runs/dev-push-35900953903/`. The first green run (35895167466) was on infra `cd2527c`.
- Deploy set: chatbot-backend `7bf1af6` (gitlink), frontend `e7a092a`, infra `0742451`.

### Criteria proved by running them

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | bootstrap creates, and a second run changes nothing | re-run 2026-09-23: "already migrated", `No changes` |
| 6 | `dev-down` leaves nothing billable; `/dev-push` brings it back | local `make dev-down`: 93 destroyed, `leftovers` "nothing remains for dev"; then run 35900953903 rebuilt it from zero, verified |
| 7 | every resource tagged | `leftovers` while up: 71 resources, each with Project, Environment, ManagedBy, Repository |
| 8 | the interface codes | infra `make test` via `bin/infra`: outputs no-state 1, plan no-ENV 2, destroy fixture 3, destroy without CONFIRM 2 |

### Deferred, and why

- The backend exits when OpenSearch is not yet answering; the chart waits with an init
  container. A retry belongs in chatbot-backend — a single-repo PR.
- The backend's `/dev-push` caller workflow — single-repo PR (BRIEF § Out of scope).


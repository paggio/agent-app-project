# 0010 — agent flow in the UI — status


## Contract freeze

- SHA: `76ac577` (full in `change.yaml`)
- Frozen: 2026-11-27

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0010-agent-flow-ui` | [#12](https://github.com/paggio/chatbot-backend/pull/12) | ☐ | ☐ |
| frontend | `feat/0010-agent-flow-ui` | [#11](https://github.com/paggio/frontend/pull/11) | ☐ | ☐ |
| infra | `feat/0010-agent-flow-ui` | [#6](https://github.com/paggio/infra/pull/6) | ☐ | ☐ |

Merge order: chatbot-backend (additive, backward compatible) → infra → frontend (needs the stream and capabilities).

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
- **unattributable** — 20261127T092345Z, 2 attempt(s)
- report: `changes/0010-agent-flow-ui/runs/20261127T092345Z/report.md`
<!-- iterate:end -->

## Blockers

- **Harness (fault: harness), blocks local green.** Attempt 1: smoke 125/0; e2e 100/102 — the
  two failures are 0009's `metrics.spec.ts`, which needs a served metrics release. Verify always
  starts cold (`down -v`), only a change's `jobs:` seed the release, and a job's owner must be a
  slice — so no change without analytics-dbt and metrics-gateway slices can pass e2e. Routed to
  frontend, which cannot fix it; the loop was stopped at attempt 2 to keep that test intact.
- Control branch is based on `chore/realign-0009-governed-metrics-spoke` (PR #51, open); merge that first.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

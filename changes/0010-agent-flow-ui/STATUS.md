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
- **verified-local** — 20261127T115933Z, 1 attempt(s)
- report: `changes/0010-agent-flow-ui/runs/20261127T115933Z/report.md`
<!-- iterate:end -->

- **verified** on dev — `/dev-push` run [45995285787](https://github.com/Paggio/agent-app-project/actions/runs/45995285787): 99 passed, 0 failed (17 from the change suite). Dev is up.

## Blockers

- Control branch is based on `chore/realign-0009-governed-metrics-spoke` (PR #51, open); merge that first.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

## Corrected, 2026-11-27 — /ship-correct

- Wrong: e2e failed on 0009's `metrics.spec.ts` — the cold local gateway served no release (`no_release`), and the repair was routed to frontend.
- Criterion: unchanged and already failing; the cause was the harness. Fixed in harness PR #52 (merged): verify seeds a metrics release (ADR 0021). Re-verified 128/0, e2e 102/102.

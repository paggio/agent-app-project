# 0010 — agent flow in the UI — status


## Contract freeze

- SHA: `76ac577` (full in `change.yaml`)
- Frozen: 2026-11-27

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0010-agent-flow-ui` | — | ☐ | ☐ |
| frontend | `feat/0010-agent-flow-ui` | — | ☐ | ☐ |
| infra | `feat/0010-agent-flow-ui` | — | ☐ | ☐ |

Merge order: chatbot-backend (additive, backward compatible) → infra → frontend (needs the stream and capabilities).

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
_Never run._
<!-- iterate:end -->

## Blockers

- None. Control branch is based on `chore/realign-0009-governed-metrics-spoke` (PR #51, open); merge that first.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

# 0010 — agent flow in the UI — status


## Contract freeze

- SHA: `3e749c6` (full in `change.yaml`); supersedes `76ac577`
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
- **verified-local** — 20261127T155856Z, 1 attempt(s)
- first dispatch: chatbot-backend frontend (`--only`)
- report: `changes/0010-agent-flow-ui/runs/20261127T155856Z/report.md`
<!-- iterate:end -->

- **verified** on dev — `/dev-push` run [45995285787](https://github.com/Paggio/agent-app-project/actions/runs/45995285787): 99 passed, 0 failed (17 from the change suite). Dev is up.

## Blockers

- PR #51 (realign 0009) merged 2026-11-27; this branch is current with `main`.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

## Corrected, 2026-11-27 — /ship-correct

- Wrong: e2e failed on 0009's `metrics.spec.ts` — the cold local gateway served no release (`no_release`), and the repair was routed to frontend.
- Criterion: unchanged and already failing; the cause was the harness. Fixed in harness PR #52 (merged): verify seeds a metrics release (ADR 0021). Re-verified 128/0, e2e 102/102.

## Amended, 2026-11-27 — /ship-iterate

- Added: the person picks the agents per chat (tick boxes on a new chat, `general` always on);
  locked at the first message and shown read-only in the conversation. Server-enforced:
  `Thread.agents`, routing bounded by it. Contract re-frozen at `3e749c6` (1.9.0, unmerged).
- Slices re-dispatched: chatbot-backend, frontend. Infra unchanged.
- Also asked: screenshots at the top of this repo's `README.md` — done by the lane after a
  green run; no step asserts it.

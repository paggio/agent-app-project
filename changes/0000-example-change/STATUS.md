# 0000 — status

<!-- EXAMPLE / TEMPLATE. Updated as the change moves. This is the only place that
     knows the state of all three PRs at once. -->

**State:** planning | contract frozen | fanned out | in review | merged

## Contract freeze

- SHA: `<sha>`
- Frozen: <YYYY-MM-DD>

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0000-<slug>` | <link> | ☐ | ☐ |
| frontend | `feat/0000-<slug>` | <link> | ☐ | ☐ |
| infra | `feat/0000-<slug>` | <link> | ☐ | ☐ |

Merge order: chatbot-backend (backward compatible) → frontend → infra as required.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
_Never run._
<!-- iterate:end -->

## Blockers

- <blocker, owner, what unblocks it>

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

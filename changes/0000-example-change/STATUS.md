# 0000 — status

<!-- TEMPLATE-ONLY: this comment is stripped by new-change.sh. Updated as the change
     moves. This is the only place that knows the state of all three PRs at once.

     There is deliberately no `State:` field. It had no writer, so it drifted — 0001-auth
     read "contract frozen — ready to fan out" directly above an iterate-maintained block
     saying "verified". A field that contradicts the machine-maintained region below it is
     worse than no field. The PR table and the Deploy verification block are the state. -->

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

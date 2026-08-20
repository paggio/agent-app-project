# 0001 — status

<!-- EXAMPLE / TEMPLATE. Updated as the change moves. This is the only place that
     knows the state of all three PRs at once. -->

**State:** **contract frozen** — brief, contract and slices written; ready to fan out

## Contract freeze

- SHA: `3710209d5a73013a6536ce71720a4f24b8dc1740`
- Frozen: 2026-08-19

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0001-auth` | <link> | ☐ | ☐ |
| frontend | `feat/0001-auth` | <link> | ☐ | ☐ |

Merge order: chatbot-backend first — additive and backward compatible on its own — then
frontend, whose route guard cannot pass until `/v1/auth/me` answers. No infra slice.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
- **verified** — 20260819T103439Z, 1 attempt(s)
- report: `changes/0001-auth/runs/20260819T103439Z/report.md`
<!-- iterate:end -->

## Blockers

- None. The smoke environment is supplied by `scripts/dev-env.sh` from `stack/dev.env`,
  so `./scripts/iterate.sh 0001-auth` needs nothing exported by hand.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

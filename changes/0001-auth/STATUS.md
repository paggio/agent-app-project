# 0001 — status

## Contract freeze

- SHA: `3710209d5a73013a6536ce71720a4f24b8dc1740`
- Frozen: 2026-08-19

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0001-auth` | [#3](https://github.com/Paggio/chatbot-backend/pull/3) | ☑ | ☑ |
| frontend | `feat/0001-auth` | [#3](https://github.com/Paggio/frontend/pull/3) | ☑ | ☑ |

Merge order: chatbot-backend first — additive and backward compatible on its own — then
frontend, whose route guard cannot pass until `/v1/auth/me` answers. No infra slice.

## Deploy verification

<!-- Maintained by the loop — edits between the markers are overwritten. A green CI column
     means each repo is internally consistent; this line is the only thing that says they
     work together. -->

<!-- iterate:begin -->
- **verified** — 20260819T103439Z, 1 attempt(s)
- report: `changes/0001-auth/runs/20260819T103439Z/report.md`
<!-- iterate:end -->

## Blockers

- None.

## After merge

- [x] Submodules bumped and `repos.lock` pinned (`65a1e65`).

# 0008 — status

## Contract freeze

- SHA: recorded in `change.yaml`
- Frozen: 2026-10-21

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0008-call-centre-hub-and-spoke` | — | ☐ | ☐ |
| chatbot-eval | `feat/0008-call-centre-hub-and-spoke` | — | ☐ | ☐ |
| frontend | `feat/0008-call-centre-hub-and-spoke` | — | ☐ | ☐ |
| infra | `feat/0008-call-centre-hub-and-spoke` | — | ☐ | ☐ |
| agent-app-project | `feat/0008-call-centre-hub-and-spoke` | — | ☐ | ☐ |

Merge order: chatbot-backend (additive API; the worker and simulator are new entrypoints) →
frontend (tolerates absent `route`) → chatbot-eval (needs the backend's `route`) → infra
(deploys the backend's new entrypoints) → agent-app-project, then `/realign`.

## Deploy verification

<!-- iterate:begin -->
- **verified-local** — 20261023T102906Z, 1 attempt(s)
- first dispatch: infra (`--only`)
- report: `changes/0008-call-centre-hub-and-spoke/runs/20261023T102906Z/report.md`
<!-- iterate:end -->

## Blockers

- Bootstrap re-apply (`make dev-bootstrap`) before the first remote pass: deployer SQS rights
  and the operator secret live there.

## After merge

- [ ] `/realign`

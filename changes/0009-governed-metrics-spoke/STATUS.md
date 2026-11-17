# 0009 — status

## Contract freeze

- SHA: recorded in `change.yaml`
- Frozen: 2026-11-17

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| analytics-dbt | `feat/0009-governed-metrics-spoke` | — | ☐ | ☐ |
| metrics-gateway | `feat/0009-governed-metrics-spoke` | — | ☐ | ☐ |
| chatbot-backend | `feat/0009-governed-metrics-spoke` | — | ☐ | ☐ |
| chatbot-eval | `feat/0009-governed-metrics-spoke` | — | ☐ | ☐ |
| frontend | `feat/0009-governed-metrics-spoke` | — | ☐ | ☐ |
| infra | `feat/0009-governed-metrics-spoke` | — | ☐ | ☐ |

Merge order: analytics-dbt and metrics-gateway (new, nothing consumes them yet) →
chatbot-backend (additive route; spoke off without `METRICS_GATEWAY_URL`) → frontend
(tolerates unknown routes) → chatbot-eval (needs the backend's `metrics` route) → infra
(deploys all of it) → agent-app-project, then `/realign`.

## Deploy verification

<!-- iterate:begin -->
- **failed** — 20261117T183509Z, 3 attempt(s)
- first dispatch: chatbot-backend (`--only`)
- failed at: `smoke: assertions failed`
- answerable: chatbot-backend
- report: `changes/0009-governed-metrics-spoke/runs/20261117T183509Z/report.md`
<!-- iterate:end -->

## Blockers

- Before `/dev-push`: `make dev-bootstrap` (two new ECR repos) — human; harness PR #43
  merged (new images reach `plan`/`deploy`) — human, the auto-merge was refused.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

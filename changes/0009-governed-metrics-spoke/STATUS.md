# 0009 — status

## Contract freeze

- SHA: recorded in `change.yaml`
- Frozen: 2026-11-17

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| analytics-dbt | `feat/0009-governed-metrics-spoke` @ `18212d0` | [analytics-dbt#1](https://github.com/paggio/analytics-dbt/pull/1) | ☑ | ☐ |
| metrics-gateway | `feat/0009-governed-metrics-spoke` @ `1bd32a9` | [metrics-gateway#1](https://github.com/paggio/metrics-gateway/pull/1) | ☑ | ☐ |
| chatbot-backend | `feat/0009-governed-metrics-spoke` @ `96a9b94` | [chatbot-backend#11](https://github.com/paggio/chatbot-backend/pull/11) | ☑ | ☐ |
| chatbot-eval | `feat/0009-governed-metrics-spoke` @ `44ae893` | [chatbot-eval#4](https://github.com/paggio/chatbot-eval/pull/4) | ☑ | ☐ |
| frontend | `feat/0009-governed-metrics-spoke` @ `3eb9499` | [frontend#10](https://github.com/paggio/frontend/pull/10) | ☑ | ☐ |
| infra | `feat/0009-governed-metrics-spoke` @ `9d20ba7` | [infra#5](https://github.com/paggio/infra/pull/5) | ☑ | ☐ |

Merge order: analytics-dbt and metrics-gateway (new, nothing consumes them yet) →
chatbot-backend (additive route; spoke off without `METRICS_GATEWAY_URL`) → frontend
(tolerates unknown routes) → chatbot-eval (needs the backend's `metrics` route) → infra
(deploys all of it) → agent-app-project, then `/realign`.

## Deploy verification

<!-- iterate:begin -->
- **verified-local** — 20261117T193113Z, 1 attempt(s)
- first dispatch: metrics-gateway chatbot-backend (`--only`)
- report: `changes/0009-governed-metrics-spoke/runs/20261117T193113Z/report.md`
<!-- iterate:end -->

## Blockers

- Before `/dev-push`: `make dev-bootstrap` (two new ECR repos) — human. Harness #43, #44,
  #45 are merged.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`

# 0009 — status

## Contract freeze

- SHA: recorded in `change.yaml`
- Frozen: 2026-11-17

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| analytics-dbt | `feat/0009-governed-metrics-spoke` @ `18212d0` | [analytics-dbt#1](https://github.com/paggio/analytics-dbt/pull/1) | ☑ | ☐ |
| metrics-gateway | `feat/0009-governed-metrics-spoke` @ `a8eb739` | [metrics-gateway#1](https://github.com/paggio/metrics-gateway/pull/1) | ☑ | ☐ |
| chatbot-backend | `feat/0009-governed-metrics-spoke` @ `96a9b94` | [chatbot-backend#11](https://github.com/paggio/chatbot-backend/pull/11) | ☑ | ☐ |
| chatbot-eval | `feat/0009-governed-metrics-spoke` @ `44ae893` | [chatbot-eval#4](https://github.com/paggio/chatbot-eval/pull/4) | ☑ | ☐ |
| frontend | `feat/0009-governed-metrics-spoke` @ `3eb9499` | [frontend#10](https://github.com/paggio/frontend/pull/10) | ☑ | ☐ |
| infra | `feat/0009-governed-metrics-spoke` @ `dda5ba3` | [infra#5](https://github.com/paggio/infra/pull/5) | ☑ | ☐ |

Merge order: analytics-dbt and metrics-gateway (new, nothing consumes them yet) →
chatbot-backend (additive route; spoke off without `METRICS_GATEWAY_URL`) → frontend
(tolerates unknown routes) → chatbot-eval (needs the backend's `metrics` route) → infra
(deploys all of it) → agent-app-project, then `/realign`.

## Deploy verification

<!-- iterate:begin -->
- **verified-local** — 20261123T135733Z, 1 attempt(s)
- first dispatch: metrics-gateway (`--only`)
- report: `changes/0009-governed-metrics-spoke/runs/20261123T135733Z/report.md`
<!-- iterate:end -->

### Merged — 2026-11-26, /realign

- Merged: analytics-dbt#1, metrics-gateway#1, chatbot-backend#11, frontend#10,
  chatbot-eval#4, infra#5, agent-app-project#46.
- `repos.lock`: analytics-dbt `3fd9eab`, chatbot-backend `dbce48f`, chatbot-eval `fde473b`,
  frontend `5672c6c`, infra `98c46ed`, metrics-gateway `9b85088`.
- Contract: agrees with what is served; the same six framework-declared 422s left unpromised.
- Promoted to `smoke/baseline.yaml`: the deployed spoke cites GMV (`remote`) and a coding
  question does not route to metrics. Not the gateway, dbt, local GMV or eval steps: each
  reads what a one-shot job produced (`docs/adr/0014`).
- Local baseline on a restarted stack: 108/0.
- The pin on dev: `/dev-push --lock` [45865446411](https://github.com/paggio/agent-app-project/actions/runs/45865446411) verified, 82/0; `/dev-eval` [45867253513](https://github.com/paggio/agent-app-project/actions/runs/45867253513) passed. Dev then taken down on request.

- **verified** on dev — `/dev-push` run [44498487651](https://github.com/paggio/agent-app-project/actions/runs/44498487651), 82 assertions passed (6 from the change's suite). Re-verified 2026-11-23 after the docs amendment, run [45191545782](https://github.com/paggio/agent-app-project/actions/runs/45191545782), 82 passed.

## Amended, 2026-11-23 — /ship-iterate

BRIEF criterion 15: metrics-gateway documents MetricFlow, the semantic index, each tool
under the hood, the agent workflow and the release CI/CD flow (ideal vs built). Docs only; the
user asked for it after reviewing. Only the metrics-gateway slice is re-dispatched.

## Blockers

- None. Verified on dev; harness #43, #44, #45, #47 merged. Dev covers 6 change steps
  (2 substantive); the gateway's 20 steps are local-only — it has no public origin on dev.

## After merge

- [x] `./scripts/lock.sh` and commit `repos.lock`

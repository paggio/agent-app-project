# 0008 — status

## Contract freeze

- SHA: recorded in `change.yaml`
- Frozen: 2026-10-21

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0008-call-centre-hub-and-spoke` @ `6b80641` | [chatbot-backend#10](https://github.com/paggio/chatbot-backend/pull/10) | ☑ | ☐ |
| chatbot-eval | `feat/0008-call-centre-hub-and-spoke` @ `8d2f71b` | [chatbot-eval#3](https://github.com/paggio/chatbot-eval/pull/3) | ☑ | ☐ |
| frontend | `feat/0008-call-centre-hub-and-spoke` @ `6808c64` | [frontend#9](https://github.com/paggio/frontend/pull/9) | ☑ | ☐ |
| infra | `feat/0008-call-centre-hub-and-spoke` @ `aeb556e` | [infra#4](https://github.com/paggio/infra/pull/4) | ☑ | ☐ |
| agent-app-project | `feat/0008-call-centre-hub-and-spoke` | [#36](https://github.com/paggio/agent-app-project/pull/36) | ☐ | ☐ |

Merge order: chatbot-backend (additive API; the worker and simulator are new entrypoints) →
frontend (tolerates absent `route`) → chatbot-eval (needs the backend's `route`) → infra
(deploys the backend's new entrypoints) → agent-app-project, then `/realign`.

## Deploy verification

<!-- iterate:begin -->
- **verified-local** — 20261102T155712Z, 1 attempt(s)
- report: `changes/0008-call-centre-hub-and-spoke/runs/20261102T155712Z/report.md`
<!-- iterate:end -->

### Merged — 2026-11-05, /realign

- Merged: chatbot-backend#10, frontend#9, chatbot-eval#3, infra#4 (squash, `1e3202f`),
  agent-app-project#36. Harness on the way: #38 (`[deployment-doc]`), #39 (`make smoke`
  run id alphanumeric — the promoted call ids are built from it).
- `repos.lock`: chatbot-backend `479e591`, chatbot-eval `97fb443`, frontend `888fa0f`,
  infra `1e3202f`.
- Contract: agrees with what is served; six framework-declared 422s left unpromised.
- Promoted to `smoke/baseline.yaml`: the calls API, the simulator, the coordinator's three
  routes, the Phoenix tags, and queue ingestion (idempotence, retention, PII, DLQ). Not the
  queue-filter question (backend-provable) nor the eval steps (job-produced).
- Local baseline on a restarted stack: 103/0.

## Remote — `verified`

- [dev-push 41817426510](https://github.com/Paggio/agent-app-project/actions/runs/41817426510) (2026-11-04) (2026-11-02, after the amendment; backend `2182d09`), at the final PR heads:
  **77 passed, 0 failed, 17 from `smoke.yaml`**, through `https://d2ts770wgdk23w.cloudfront.net`.
- Criterion 19: deploy signed in as `operator@agentapp.test` (app) and `admin` (Phoenix)
  with `agentapp/dev/operator-password`. `make -C infra credentials ENV=dev` prints both.
- Earlier red passes, all fixed in the slice briefs then the repo: worker lacked
  `GetQueueAttributes` on the DLQ (infra); infra probed HTTP while the worker reports by
  heartbeat file (infra); simulator called `CreateQueue` under a send-only role (backend).
- After the retro: backend Stop hook restored (`638abe1`, it had exited before every gate);
  MinIO moved to `cgr.dev/chainguard/minio` by digest (`6b80641`, user decision — both upstream
  registries are gone). All four PRs CI-green.
- Local runs used `CHAT_MODEL=echo`: the session in `stack/secrets.env` had expired, which
  500'd every turn under `bedrock` in the first run.
- `dev` is UP for review and billing — `make dev-down` when done.

## Amended, 2026-11-02 — /ship-iterate

User, after inspecting dev's Phoenix: every root span is kind `unknown` and the worker's
`call.ingest` traces bury the conversations; asked for clearer tags by origin and a graph
illustration. Added criteria 21–24 (worker traces in `chatbot-backend-calls`; chat turns
tagged `conversation`/`route:<route>` as `CHAIN`; other API spans `api`; a Mermaid diagram
generated from the graph, test-guarded). Backend slice only; no contract change.
Criterion 22 contradicted baseline `the-graph-run-is-nested-under-it` (no CHAIN at the
root); the backend agent named it and stopped. That step now selects `name=LangGraph`.

## Blockers

- None. Bootstrap re-applied 2026-10-23 (2 added, 1 changed, 0 destroyed).

## After merge

- [x] `/realign`

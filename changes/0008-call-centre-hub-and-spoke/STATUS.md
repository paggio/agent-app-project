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
- **verified-local** — 20261102T095412Z, 1 attempt(s)
- report: `changes/0008-call-centre-hub-and-spoke/runs/20261102T095412Z/report.md`
<!-- iterate:end -->

## Remote — `verified`

- [dev-push 39953125755](https://github.com/paggio/agent-app-project/actions/runs/39953125755), at the final PR heads:
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
- `dev` torn down 2026-10-24 (`make dev-down`); the verdict above stands at these heads.

## Blockers

- None. Bootstrap re-applied 2026-10-23 (2 added, 1 changed, 0 destroyed).

## After merge

- [ ] `/realign`

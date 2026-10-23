# 0008 — infra slice

## What to build

### 1. The call queue

- SQS standard queue `agentapp-<env>-calls` and DLQ `agentapp-<env>-calls-dlq`, redrive
  `maxReceiveCount` 3, SSE on, DLQ retention 14 days, main queue 4 days. Default tags as
  everything else.
- Outputs `call_queue_url`, `call_dead_letter_queue_url`.

### 2. Two more Deployments of the backend image

Same image and tag as `backend` (so `deployed_backend_image` still describes them), 1 replica
each, small requests:

- `call-worker` — `python -m app.calls.worker`. Env: `CALL_QUEUE_URL`,
  `CALL_DEAD_LETTER_QUEUE_URL`, `CALL_RETENTION_DAYS=7`, and the same datastore, embedding and
  OTLP configuration the backend has. Pod identity: `sqs:ReceiveMessage`, `DeleteMessage`,
  `ChangeMessageVisibility`, `GetQueueAttributes`, `GetQueueUrl` on the main queue;
  `SendMessage`, `GetQueueUrl` and `GetQueueAttributes` on the DLQ (the worker checks both
  queues before it reports ready; without it the pod never passes its startup probe on dev). Same Bedrock rights as the backend (embeddings may
  be `bedrock`).
- `call-simulator` — `python -m app.calls.simulator`, `CALL_SIMULATOR_INTERVAL_S=60`. Pod
  identity: `sqs:SendMessage`, `GetQueueUrl` on the main queue only. No datastore access.
- NetworkPolicies: worker → opensearch, postgres, phoenix; simulator → nothing in-cluster.
  Both need egress to SQS (through the NAT, or add an SQS interface endpoint if cheaper —
  say which and why).
- `deploy`'s rollout check includes both Deployments. The `/healthz` the worker exposes is
  its readiness probe.

### 3. The deployer role

Bootstrap's `agentapp-dev-deployer` gains what Terraform needs for the queues and what a CI
eval needs to publish fixtures (`sqs:SendMessage`, `GetQueueUrl` on the main queue). Bootstrap
is re-applied once by hand — say so in `README.md`.

### 4. The fixed dev login

- Bootstrap creates `agentapp/<env>/operator-password` (random, ≥ 24 chars, satisfies the
  backend's password policy — 12–128, not common — and Phoenix's), so it survives
  `destroy`. Output `operator_password_secret_ref` and `operator_login_email`
  (`operator@agentapp.test`).
- The backend is given `DEV_ACCOUNT_EMAIL=operator@agentapp.test` and
  `DEV_ACCOUNT_PASSWORD` from that secret (External Secrets) — the backend already seeds that
  account at startup for a `.test` address.
- Phoenix's `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD` comes from the same secret instead of
  today's per-environment random one, so `admin` has the same password after every rebuild.
- `deploy` does not return 0 until both sign-ins work with that secret: `POST
  /api/v1/auth/login` on the app origin and Phoenix's login on its origin. Failure is exit 1
  with which one failed.
- `make credentials ENV=dev` (and `bin/infra credentials`) prints the two URLs, the two
  usernames and the one command that reads the password. It prints the password itself only
  with `SHOW=1`.

### 5. Documentation, skills, agents

- Update `docs/architecture.md` (module map, request lifecycle for the worker and
  simulator, NetworkPolicies, the credentials target), `README.md` (bootstrap re-apply, the
  login), `CLAUDE.md`.
- Replace `.claude/skills/example-skill`, `.claude/agents/example-agent.md` and the example
  rule with real ones, e.g. a skill `read-a-plan` (what exit 3 means, finding the destroyed
  resource in `.plans/`) and an agent `rollout-debugger` that reads `.evidence/<env>/` after a
  failed deploy and names the failing pod and cause.
- Make this repo's gate fail when `modules/`, `envs/`, `bootstrap/`, `charts/`, `scripts/` or
  `bin/` changed against `origin/main` and none of `docs/`, `README.md`, `CLAUDE.md` did.

## Contract entries this depends on

- `contracts/infra-outputs.yaml` → `call_queue_url`, `call_dead_letter_queue_url`,
  `operator_login_email`, `operator_password_secret_ref`.
- The worker and simulator are the backend image's entrypoints; nothing else of the backend
  is assumed.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and report
it rather than working around it.

## Verification

- [ ] `fmt`, `validate`, `lint`, `test`, `contract` green; `outputs` produces all four new names.
- [ ] `plan` against dev is additive (exit 0) apart from the Phoenix admin-password secret
      moving to bootstrap — if that is a replace, say so; dev forgets its data on destroy.
- [ ] the repo's own gates pass, including the new docs check.

## Smoke — what this slice is actually judged on

`the-deployed-simulator-is-producing-calls` (remote): simulator → SQS → worker → index on
dev, read through the CloudFront origin. The untagged coordinator steps also run on dev
against the simulator's calls. The assertions belong to the control repo: fix the cause,
never the assertion.

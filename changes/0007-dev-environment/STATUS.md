# 0007 — status

## Amended, 2026-09-24 — /ship-iterate

Added criteria 9 (Phoenix UI on its own HTTPS origin, auth on) and 10 (`/dev-eval` runs the
eval against `dev` from a PR). Contract re-frozen at `bf2a6b8` (two additive outputs).
Infra slice only; frontend unchanged. The `/dev-eval` workflow and the `/realign` change
(the deploy is the user's to trigger) are control-repo harness work, in their own PR.

- Harness: [#30](https://github.com/paggio/agent-app-project/pull/30) merged (`/dev-eval`, `/realign` hands the deploy to the user). README: [#29](https://github.com/paggio/agent-app-project/pull/29), open.
- Local: `runs/20260924T103206Z` — verified-local, 71/0. Infra `611df58`; frontend unchanged at `e7a092a`.
- Remote: [dev-push 35988704468](https://github.com/Paggio/agent-app-project/actions/runs/35988704468) — **verified**, 60/0, 10 from this suite (criterion 9). App `https://dqmnl2n7vowos.cloudfront.net`, Phoenix `https://d2fbe2mr91k6re.cloudfront.net`.
- `/dev-eval --judge heuristic` (criterion 10): [35989985453](https://github.com/paggio/agent-app-project/actions/runs/35989985453) breached — every turn 500 while Bedrock returned `ServiceUnavailableException` (10:56–11:05 UTC); [35991167434](https://github.com/paggio/agent-app-project/actions/runs/35991167434) **passed**, 18 examples, routing 1.000, recall 0.950.
- Deferred: the Bedrock judge needs `make -C infra bootstrap ENV=dev` (deployer `bedrock:InvokeModel`); the backend answers an upstream model outage with a bare 500 — a chatbot-backend single-repo PR.

## Contract freeze

- SHA: recorded in `change.yaml`
- Frozen: 2026-09-23

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| frontend | `feat/0007-dev-environment` @ `e7a092a` | [frontend#8](https://github.com/paggio/frontend/pull/8) | ☑ | ☑ `103e58e` |
| infra | `feat/0007-dev-environment` @ `611df58` | [infra#1](https://github.com/paggio/infra/pull/1) | ☑ | ☑ `4394681` |
| agent-app-project | `feat/0007-dev-environment` | [#24](https://github.com/paggio/agent-app-project/pull/24) | ☑ | ☑ `23146aa` |

Merge order: frontend (the proxy image is backward compatible locally) → infra →
agent-app-project, then `/realign`, which pins and opens its PR; you comment `/dev-push` on it.

## Deploy verification

<!-- iterate:begin -->
- **verified-local** — 20260924T103206Z, 1 attempt(s)
- report: `changes/0007-dev-environment/runs/20260924T103206Z/report.md`
<!-- iterate:end -->

### Merged — 2026-10-09, /realign

- Merged: frontend#8, infra#1, agent-app-project#24; catch-up publishes chatbot-eval#2 (not
  a slice, so `infra-outputs.yaml` never reached it) and infra#2 (first vendored copy, which
  #31 made required; also pins the CRDs catalog and scopes the budget to eu-west-1).
- `repos.lock`: chatbot-backend `7bf1af6`, chatbot-eval `1fe285b`, frontend `103e58e`,
  infra `2afe929`.
- Promoted all 10 steps of `smoke.yaml` into `smoke/baseline.yaml`, tags carried.
- `dev`: not deployed by this lane; `/dev-push` on the realign PR is the user's.

### Remote — `verified`

- dev-push run 35900953903 on the final heads: **58 passed, 0 failed, 8 of 8 from
  `smoke.yaml`**, through `https://d38ei0kc8u02rn.cloudfront.net` (a fresh distribution after the rebuild; run 35895167466 used d3560p6j05etw0). Evidence:
  `runs/dev-push-35900953903/`. The first green run (35895167466) was on infra `cd2527c`.
- Deploy set: chatbot-backend `7bf1af6` (gitlink), frontend `e7a092a`, infra `0742451`.

### Criteria proved by running them

| # | Criterion | Evidence |
| --- | --- | --- |
| 1 | bootstrap creates, and a second run changes nothing | re-run 2026-09-23: "already migrated", `No changes` |
| 6 | `dev-down` leaves nothing billable; `/dev-push` brings it back | local `make dev-down`: 93 destroyed, `leftovers` "nothing remains for dev"; run 35900953903 rebuilt it from zero, verified; CI `dev-down` run 35903783324: 93 destroyed, nothing remains |
| 7 | every resource tagged | `leftovers` while up: 71 resources, each with Project, Environment, ManagedBy, Repository |
| 8 | the interface codes | infra `make test` via `bin/infra`: outputs no-state 1, plan no-ENV 2, destroy fixture 3, destroy without CONFIRM 2 |

### Deferred, and why

- The backend exits when OpenSearch is not yet answering; the chart waits with an init
  container. A retry belongs in chatbot-backend — a single-repo PR.
- The backend's `/dev-push` caller workflow — single-repo PR (BRIEF § Out of scope).


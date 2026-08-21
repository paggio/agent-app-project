# agent-app-project

Control repo for a three-tier system developed primarily through AI coding agents.
It holds the one thing that cannot live inside any single product repo: the interface
between them.

| Repo | Submodule path | Contents | Deploy cadence |
| --- | --- | --- | --- |
| [`agent-app-project`](https://github.com/Paggio/agent-app-project) | — | contracts, change briefs, cross-cutting docs, orchestration | n/a |
| [`chatbot-backend`](https://github.com/Paggio/chatbot-backend) | `chatbot-backend/` | API service | per merge |
| [`frontend`](https://github.com/Paggio/frontend) | `frontend/` | web client | per merge |
| [`infra`](https://github.com/Paggio/infra) | `infra/` | IaC | reviewed, gated |

## Clone

```bash
git clone --recurse-submodules git@github.com:Paggio/agent-app-project.git
# or, after a plain clone:
git submodule update --init --recursive
```

## Four lanes

**Solo (~80% of work).** Work inside the product repo. Nothing from the sibling repos
enters context. That repo's CI fails if the work turns out to touch contract surface, which
is your signal to come back here for a contract pass.

```bash
cd chatbot-backend   # or frontend, infra
claude
```

**Contract pass.** An interface between repos changes, and nothing else does. Sequential,
single session, one commit containing only `contracts/`. That commit is the freeze point.
Use the `freeze-contract` skill to decide a new interface, `align-contract` to promote one
that already works.

**Cross-repo change.** Plan and freeze here, then ship.

```bash
claude
# 1. plan   → ./scripts/new-change.sh <slug>, then the plan-cross-repo-change skill
# 2. freeze → contracts/ alone; record that commit as freeze_sha in change.yaml
# 3. ship   → /ship NNNN-<slug>   (./scripts/iterate.sh does the whole loop)
# 4. merge  → dependency order, then ./scripts/lock.sh && commit repos.lock
```

Never overlap steps 2 and 3. **Step 3 is what "shipped" means** — the repos deployed
together with the smoke suite passing. Three independently green PRs is not shipped; see
`docs/adr/0002`.

**Cross-repo change that must reach AWS.** As above, plus `deploy.infra: true`, an `infra`
slice, and a target environment. The same suite is then asserted twice: against the local
stack and against the deployed origin. Load the `deploy-to-aws` skill — and note that each
repair attempt is a real `terraform apply`, which is why the attempt budget is 1 by
default. See `docs/adr/0004`.

## Where things live

- `concept.md` — the reasoning behind this layout.
- `docs/init/` — the executable playbook: how to re-create all four repos from zero.
- `docs/adr/` — decisions and their accepted costs.
- `CLAUDE.md` — additive agent context. Never load-bearing; every product repo is
  self-describing in isolation.

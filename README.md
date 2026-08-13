# agent-app-project

Control repo for a three-tier system developed primarily through AI coding agents.
It holds the one thing that cannot live inside any single product repo: the interface
between them.

| Repo | Submodule path | Contents | Deploy cadence |
| --- | --- | --- | --- |
| [`agent-app-project`](https://github.com/Paggio/agent-app-project) | — | contracts, change briefs, cross-cutting docs, orchestration | n/a |
| [`chatbot-backend`](https://github.com/Paggio/chatbot-backend) | `backend/` | API service | per merge |
| [`frontend`](https://github.com/Paggio/frontend) | `frontend/` | web client | per merge |
| [`infra`](https://github.com/Paggio/infra) | `infra/` | IaC | reviewed, gated |

## Clone

```bash
git clone --recurse-submodules git@github.com:Paggio/agent-app-project.git
# or, after a plain clone:
git submodule update --init --recursive
```

## Two workflows

**Single-repo change (~80% of work).** Work inside the product repo. Nothing from the
sibling repos enters context.

```bash
cd backend   # or frontend, infra
claude
```

**Cross-repo change.** Plan and freeze the contract here, then fan out.

```bash
claude
# 1. plan      → changes/NNNN-<slug>/BRIEF.md + per-repo slices
# 2. freeze    → edit contracts/, commit; that commit is the freeze point
# 3. fan out   → ./scripts/fanout.sh NNNN-<slug>
# 4. review    → three independently green PRs
# 5. merge     → dependency order, then ./scripts/lock.sh && commit repos.lock
```

Never overlap steps 2 and 3.

## Where things live

- `concept.md` — the reasoning behind this layout.
- `docs/init/` — the executable playbook: how to re-create all four repos from zero.
- `docs/adr/` — decisions and their accepted costs.
- `CLAUDE.md` — additive agent context. Never load-bearing; every product repo is
  self-describing in isolation.

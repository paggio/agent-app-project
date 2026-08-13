# Control repo — agent-app-project

Three INDEPENDENT projects, vendored as submodules. Each has its own git history, CI,
deploy cadence and CLAUDE.md. This file is extra context only — never assume a
sub-repo session can see it.

## Hard rules

- NEVER edit code inside `backend/`, `frontend/`, `infra/` from this session.
  Implementation happens in a session started inside that repo, or via
  `scripts/fanout.sh`. Here you plan and write contracts.
- Submodules land in detached HEAD. Before ANY commit inside one:
  `git -C <repo> switch -c <branch>` first. Verify with `git -C <repo> status`.
- `contracts/` is owned here and only here. Product repos consume, never edit.
- Contract changes are sequential and single-session; implementation is parallel.
  Never both at once.
- After merging a change, run `./scripts/lock.sh` and commit `repos.lock`.

## Layout

- `contracts/`     frozen interfaces (HTTP, events, infra outputs)
- `changes/NNNN-*/` one directory per cross-repo feature
- `docs/adr/`      cross-cutting decisions
- `docs/init/`     how this structure is built and re-created
- `repos.lock`     the SHA triple known to work together

## Submodules

| Path | Remote |
| --- | --- |
| `backend/` | `Paggio/chatbot-backend` |
| `frontend/` | `Paggio/frontend` |
| `infra/` | `Paggio/infra` |

## Commands

- `./scripts/new-change.sh <slug>`    scaffold `changes/NNNN-<slug>/`
- `./scripts/fanout.sh <change-dir>`  dispatch a change to all three repos
- `./scripts/lock.sh`                 refresh `repos.lock` from submodule SHAs

# Control repo — agent-app-project

Three INDEPENDENT projects, vendored as submodules. Each has its own git history, CI,
deploy cadence and CLAUDE.md. This file is extra context only — never assume a
sub-repo session can see it.

## Hard rules

- NEVER edit code inside `chatbot-backend/`, `frontend/`, `infra/` from this session.
  Implementation happens in a session started inside that repo, or via
  `scripts/fanout.sh`. Here you plan and write contracts.
- Submodules land in detached HEAD. Before ANY commit inside one:
  `git -C <repo> switch -c <branch>` first. Verify with `git -C <repo> status`.
- `contracts/` is owned here and only here. Product repos consume, never edit.
- Contract changes are sequential and single-session; implementation is parallel.
  Never both at once.
- After merging a change, run `./scripts/lock.sh` and commit `repos.lock`.
- Smoke assertions are owned here, like contracts. A product repo never edits one to
  make its slice pass — a failing assertion means fix the cause, or change the criterion
  here on purpose.
- "Three PRs exist" is not shipped. A change is shipped when the repos have been deployed
  together and the smoke suite passed. See `docs/adr/0002`.

## Layout

- `contracts/`     frozen interfaces (HTTP, events, infra outputs)
- `changes/NNNN-*/` one directory per cross-repo feature
  - `change.yaml`  the machine-readable half: slices, freeze SHA, deploy flags
  - `smoke.yaml`   the acceptance criteria as executable steps, each with an `owner`
  - `runs/`        deploy evidence from iterate.sh (gitignored)
- `stack/`         the joined local stack — every repo in one compose project
- `smoke/`         `baseline.yaml`, the cross-repo regression suite
- `docs/adr/`      cross-cutting decisions
- `docs/init/`     how this structure is built and re-created
- `repos.lock`     the SHA triple known to work together

## Submodules

| Path | Remote |
| --- | --- |
| `chatbot-backend/` | `Paggio/chatbot-backend` |
| `frontend/` | `Paggio/frontend` |
| `infra/` | `Paggio/infra` |

## Commands

`make help` lists everything. The ones that matter:

- stack:   `make up down restart ps logs health` — every repo together on one origin
- poke:    `make chat MSG="hi"`, `make open`, `make rebuild SVC=backend`
- assert:  `make smoke`, `make verify CHANGE=<dir>`, `make iterate CHANGE=<dir>`
- across:  `make repos` (branch/SHA vs `repos.lock`), `make prs`, `make lock`, `make check`

Each product repo has its own `make up` that brings up THAT repo alone. `make up` here
brings them up together, which is the only arrangement where the seams are real.

Change lifecycle:

- `./scripts/new-change.sh <slug>`    scaffold `changes/NNNN-<slug>/`
- `./scripts/iterate.sh <change>`     the whole loop: dispatch, deploy, smoke, repair
- `./scripts/lock.sh`                 refresh `repos.lock` from submodule SHAs

Underneath `iterate.sh`, usable on their own:

- `./scripts/verify.sh <change>`      deploy and assert, no agents involved
- `./scripts/fanout.sh <change>`      dispatch slices only
- `./scripts/stack.sh up|down|logs`   drive the joined stack by hand
- `./scripts/smoke.py <suite>...`     run assertions against a running stack
- `./scripts/manifest.py <dir>`       read or validate a change.yaml

The fast inner loop while iterating: `./scripts/verify.sh <change> --keep-up`, then
`./scripts/stack.sh rebuild backend` and re-run smoke, instead of a full cold cycle.

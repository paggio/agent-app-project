# Control repo — agent-app-project

Three INDEPENDENT projects vendored as submodules, each with its own git history, CI,
deploy cadence and CLAUDE.md. This file is additive context — never assume a sub-repo
session can see it.

## Which lane am I in?

First yes wins. Never run two lanes in one session, and never plan, freeze and implement
in one pass.

| The work | Lane | Do this |
| --- | --- | --- |
| One repo, no interface change | solo | Not here — `cd <repo> && claude`. That repo's CI fails if the work turns out to touch contract surface; come back for lane 2 if it does. |
| An interface between repos changes, nothing else | contract | `freeze-contract` to decide a new interface, `align-contract` to promote one that already works |
| Two or more repos must change together | cross-repo | `plan-cross-repo-change` → a contract pass → `/ship <change>` |
| …and it must reach AWS | deploy | the above, plus `deploy-to-aws` |

## Hard rules

- NEVER edit inside `chatbot-backend/`, `frontend/`, `infra/` from here. Implementation
  happens in a session started inside that repo, or via `./scripts/fanout.sh`.
- `contracts/` is owned here and only here. Product repos vendor it and verify against it;
  they never edit it.
- Smoke assertions are owned here too. A failing assertion means fix the cause, or change
  the criterion here on purpose — never in a product repo.
- Submodules land in detached HEAD. `git -C <repo> switch -c <branch>` before ANY commit
  inside one.
- The freeze point is the commit that lands `contracts/` alone. Its SHA goes in that
  change's `change.yaml` as `freeze_sha`. Nowhere else — nothing reads anywhere else.
- "Three PRs exist" is not shipped. Shipped means deployed together with the smoke suite
  passing. See `docs/adr/0002`.
- Every variable a smoke suite interpolates is declared in `stack/dev.env`. Never export
  one by hand.
- Exit 1 = the thing under test failed. Exit 2 = the harness refused. See `docs/adr/0003`.
- After a human merges: `./scripts/lock.sh`, commit `repos.lock`, and promote the durable
  smoke steps into `smoke/baseline.yaml`.

## Layout

- `contracts/`      the interfaces. `openapi.yaml` and `infra-outputs.yaml` are real;
                    `events/` is still a skeleton.
- `changes/NNNN-*/` `change.yaml` is the machine half — slices, `freeze_sha`, deploy flags,
                    environment. `smoke.yaml` is the criteria as steps, each `owner`ed.
- `stack/`          the joined local stack. `dev.env` is one source for the stack and the
                    suites; the real environment always wins.
- `smoke/baseline.yaml`  the cross-repo regression suite
- `docs/adr/`       decisions and their accepted costs — read before proposing a redesign
- `repos.lock`      the SHA triple known to work together

## Commands

`make help` lists everything; every script takes `--help`.

- `make up down ps logs health` — all three repos on one origin. A product repo's own
  `make up` brings up that repo alone; only this arrangement makes the seams real.
- `make smoke` · `make verify CHANGE=<dir>` · `make iterate CHANGE=<dir>`
- `make repos lock prs check check-docs` — state across the repos
- `./scripts/new-change.sh <slug>` scaffolds · `manifest.py <dir> --validate` is the ship
  gate and names what to fix · `harvest-contract.py --diff` is contract versus served

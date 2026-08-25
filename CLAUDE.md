# Control repo — agent-app-project

Three INDEPENDENT projects vendored as submodules, each with its own git history, CI,
deploy cadence and CLAUDE.md. This file is additive context — never assume a sub-repo
session can see it.

## Which lane am I in?

| The work | Do this |
| --- | --- |
| One repo, no interface change | Not here — `cd <repo> && claude`. That repo's CI fails if the work turns out to touch contract surface; come back for `/ship` if it does. |
| Two or more repos, or any change to `contracts/` | `/ship "<what you want>"` — one command: plan artifact, contract freeze, dispatch, iterate, smoke, pull requests. |
| The product PRs are merged and this repo is behind | `/realign` — bump the submodules, re-check the contract against what is served, re-run the baseline, promote the durable steps. |

Never run two lanes in one session.

## Hard rules

- NEVER edit inside `chatbot-backend/`, `frontend/`, `infra/` from here. Implementation
  happens in a session started inside that repo, or via the dispatch `/ship` runs.
- `contracts/` is owned here and only here. Product repos vendor it and verify against it;
  they never edit it.
- Smoke assertions are owned here too. A failing assertion means fix the cause, or change
  the criterion here on purpose — never in a product repo.
- Submodules land in detached HEAD. `git -C <repo> switch -c <branch>` before ANY commit
  inside one.
- Comments: concise, non-invasive, sparse. If I want deeper understanding I will ask
  Claude Code directly rather than read comments.
- The freeze point is the commit that lands `contracts/` alone. Its SHA goes in that
  change's `change.yaml` as `freeze_sha`. Nowhere else — nothing reads anywhere else.
- "Three PRs exist" is not shipped. Shipped means deployed together with the smoke suite
  passing. See `docs/adr/0002`.
- Every variable a smoke suite interpolates is declared in `stack/dev.env`. Never export
  one by hand.
- Exit 1 = the thing under test failed. Exit 2 = the harness refused. See `docs/adr/0003`.

## Layout

- `contracts/`      the interfaces — `openapi.yaml`, `infra-outputs.yaml`, and the
                    normative prose neither can hold, in `README.md`
- `changes/NNNN-*/` `change.yaml` is the machine half — slices, `freeze_sha`, deploy flags.
                    `smoke.yaml` is the acceptance criteria as steps, each `owner`ed.
- `stack/`          the joined local stack. `dev.env` is one source for the stack and the
                    suites; the real environment always wins.
- `smoke/baseline.yaml`  the cross-repo regression suite
- `docs/adr/`       decisions and their accepted costs — read before proposing a redesign
- `docs/infra-interface.md`  what this repo requires of `infra/`
- `repos.lock`      the SHA triple known to work together

## Commands

`make help` lists the hand tools — `up down ps logs health smoke check`, and `verify` /
`iterate` for driving one phase by hand. They are for looking at the running system.
`/ship` and `/realign` are how work gets done.

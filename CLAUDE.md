# Control repo — agent-app-project

INDEPENDENT product repos vendored as submodules (`.gitmodules` is the list), each with its
own git history, CI, deploy cadence and CLAUDE.md. This file is additive context — never
assume a sub-repo session can see it.

## Which lane am I in?

| The work | Do this |
| --- | --- |
| One repo, no interface change | Not here — `cd <repo> && claude`. That repo's CI fails if the work turns out to touch contract surface; come back for `/ship` if it does. |
| Two or more repos, any change to `contracts/`, or a new repo you explicitly ask for | `/ship "<what you want>"` — one command: plan artifact, (new repo,) contract freeze, dispatch, iterate, smoke, pull requests. |
| A change is in flight — PRs open, nothing merged — and the result is not what you asked for | `/ship-correct <change>: <what is wrong>` — turn the objection into a failing assertion, route it to the repo answerable, run the loop. |
| Same window, and you now want a different requirement | `/ship-iterate <change>: <what to change>` — amend the brief, the criteria and the slices, then run the loop again against the same branches. |
| The product PRs are merged and this repo is behind | `/realign` — bump the submodules, re-check the contract against what is served, re-run the baseline, promote the durable steps. |

Never run two lanes in one session.

## Hard rules

- NEVER edit inside a submodule from here (any path in `.gitmodules`). Implementation
  happens in a session inside that repo, or via `/ship`'s dispatch.
- `contracts/` is owned here and only here. Product repos vendor it, verify against it, never edit it.
- Smoke assertions are owned here too. A failing assertion means fix the cause, or change
  the criterion here on purpose — never in a product repo.
- Harness fixes go in the ONE open `harness/` PR (the retro's, or opened from `origin/main` if none). Never slip one into a change.
- Never commit inside a submodule while it is on `main`, and never assume which ref it is
  on: `git -C <repo> switch -c <branch>` first, every time. `git submodule update` leaves
  a detached HEAD, `/realign` leaves `main`, and a commit on either is a commit in the
  wrong place.
- The freeze point is the commit landing `contracts/` alone; its SHA goes in `change.yaml` as `freeze_sha`, nowhere else.
- "Three PRs exist" is not shipped: shipped means deployed together with the smoke suite
  passing — `/dev-push` on the PR, then on the `/realign` PR — the lane runs both, and asks for review only once they are green. `docs/adr/0002`, `0018`.
- Docs move with the code, here and in each repo: a slice whose code changed and docs did not fails verify. `docs/adr/0019`.
- Every variable a smoke suite interpolates is declared in `stack/dev.env`. Never export one by hand.
- Exit 1 = the thing under test failed. Exit 2 = the harness refused. See `docs/adr/0003`.
- NEVER run `docker compose config` on `stack/compose.yml` or paste its output — it inlines
  `env_file` and prints the real AWS credentials in `stack/secrets.env`. Use `make config`.
- Ignore `TODO.md` — it is a personal ideas dump, not something you must maintain/populate/read into.
- Concise EVERYWHERE, and REPLIES TO ME MOST OF ALL: lead with the result, no preamble, no
  narration, no recap. Same for comments, docs, briefs, commit messages. Verbosity is the
  failure, not the fix — if I want depth I will ask. One exception: the step-schema header
  in `changes/0000-example-change/smoke.yaml`, which `check-docs.py` requires kept complete.

## Layout

- `contracts/`  the interfaces, plus the normative prose `README.md` neither spec can hold
- `changes/NNNN-*/`  `change.yaml` is the machine half — slices, freeze, `jobs:`;
                     `smoke.yaml` is the criteria as steps, each `owner`ed — routes a failure
- `stack/`  the joined local stack; `dev.env` committed config, `secrets.env` the secrets
- `smoke/baseline.yaml`  the cross-repo regression suite
- `docs/adr/`  decisions and their accepted costs — read before proposing a redesign
- `docs/infra-interface.md`  what this repo requires of `infra/`
- `repos.lock`  the submodule SHAs known to work together; `templates/product-repo/` a new repo's scaffold

## Commands

`make help` lists the hand tools for looking at the running system. `/ship`,
`/ship-correct`, `/ship-iterate` and `/realign` are how work gets done. Deploys run only in
CI, started by the lanes (`scripts/dev-push.sh`) once `make login && make push-gh-creds` has run; `make dev-down` when idle.

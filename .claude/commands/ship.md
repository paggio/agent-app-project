---
description: Take a cross-repo change from an idea to open pull requests — plan, freeze the contract, dispatch the slices, iterate to green, smoke, open the PRs.
argument-hint: <what you want, in your own words — or an existing NNNN-slug>
---

Ship this:

> $ARGUMENTS

This is the whole cross-repo lane. Five phases, in order, in this one invocation. Nothing
here is optional and nothing here is done by hand twice: each phase ends at a gate that
either passes or names what to fix.

Shipping does not mean pull requests exist. It means the repos were deployed together and
the acceptance criteria held through the origin a browser would use. See `docs/adr/0002`.

If that names a directory that already exists under `changes/`, start at the phase it has
reached. Otherwise it is a request in prose, and phase 1 turns it into the artifact.

Throughout, `<change>` means the `NNNN-<slug>` directory name — the one you scaffold in
phase 1, or the one you were given.

## 1 — Plan

`./scripts/new-change.sh <slug>` scaffolds `changes/NNNN-<slug>/`. Then, before writing:
read `docs/adr/` and the sibling repos' `docs/architecture.md`. Do not fill a gap with an
assumption — an unstated assumption becomes three divergent implementations.

Produce four things:

- **`BRIEF.md`** — why, the acceptance criteria, what is explicitly out of scope. The
  criteria are the oracle: write them as statements that can fail. A criterion that cannot
  fail is not one. State the out-of-scope items with their reason, so the next reader knows
  it was a decision.
- **`smoke.yaml`** — those same criteria, executable. Write them **now**, while planning,
  for two reasons: they are dispatched to the implementing agents, so each one knows what
  it will be judged on before it starts; and a criterion nobody can express as a step was
  usually never checkable. Every step needs an `owner` — the repo answerable for it. That
  field is what routes a failure back to one agent with the request, the response and the
  container log attached. Guess it and a failing backend sends a frontend agent chasing
  something it cannot fix.
- **one slice file per repo touched** — `<submodule-path>.md`. Each is read by an agent
  working alone inside that repo, which cannot see this one. State what changes, which
  contract entries it depends on, and how it is verified. Say nothing about another repo's
  internals. Delete the slices that do not apply and prune `slices:` to match.
- **`change.yaml`** — slices, deploy flags, the smoke file and base. Set `smoke.e2e: true`
  when a criterion can only be proved in a browser.

## 2 — Freeze the contract

If no interface between repos moves, skip to phase 3.

Edit `contracts/` — additive wherever possible, because the repos deploy independently and
production will run mismatched versions. Then **commit `contracts/` alone**, with nothing
else in the diff, and record that commit as `freeze_sha` in `change.yaml`. That commit is
the freeze point; `fanout.sh` extracts `contracts/` at exactly that SHA and gives the
slices nothing else, so the freeze is a tree rather than a promise.

`contracts/README.md` § "Changing a contract" is the normative version, including the case
where the shape already exists and you are promoting it with `harvest-contract.py`.

Do not implement anything in this phase. The ordering — freeze, then dispatch — is what
this whole structure is for, and phase 3 is the gate that enforces it.

## 3 — Gate

```
./scripts/manifest.py changes/<change> --validate
```

Exit 0, or exit 2 naming what to fix. It checks the slices against their files in both
directions, that `freeze_sha` is a real commit and an ancestor of HEAD, that `contracts/`
is clean, that `BRIEF.md` and `STATUS.md` carry no template placeholders, and that every
smoke step has an `owner` **and every slice has at least one step it is answerable for**.

Fix what it names. Do not work around it. The one thing it cannot judge is whether the
acceptance criteria are any good — read them yourself.

## 4 — Iterate to green

```
./scripts/iterate.sh <change>
```

One command, and the only one you need. **It takes tens of minutes** — it runs a full
agent session per slice, then builds and brings up every repo. Start it in the background
so it outlives your own turn; a loop killed mid-attempt reports `unattributable` with no
assertion evidence, which is the harness being honest about a run that did not finish, not
a result about the change. It dispatches a `claude -p` per slice, each with
its working directory inside the real product repo so that repo's own `CLAUDE.md`, settings,
skills, hooks and gates apply; brings every repo up as one stack on one network; runs the
baseline suite and the change's suite through the single origin; and on failure sends the
failing assertion plus that service's container log back to the repo named in the step's
`owner`. Bounded, then it stops.

`--max-attempts N` · `--no-repair` for one pass and a report · `--verify-only` to skip
dispatch and just assert what is checked out · `--keep-up` to leave the stack running.

**If the change deploys** (`deploy.infra: true`): read `docs/infra-interface.md` first.
The environment must be named in `change.yaml` and must be one you meant; `prod` is not in
the allowlist and adding it is a reviewed commit here. The same suite is asserted twice,
local then deployed, from one file — `local` and `remote` are the only tags and untagged
runs in both. The attempt budget is 1, because an attempt is a real `terraform apply`.
`--plan-only` shows what an apply would do; `--no-infra` stays local and can only ever
report `verified-local`.

## 5 — Pull requests, and the report

`iterate.sh` runs `./scripts/prs.sh --create <change>` itself on a green outcome, so the
PR URLs in `runs/<ts>/prs.json` are checked facts rather than an agent's claim. It is
idempotent — a slice that already opened its own PR keeps it.

Then read `changes/<change>/runs/<ts>/report.md` and report:

- the outcome **and the assertion count beside it**. A report cannot say `verified` above
  an empty count; if the count looks thin, say so.
- per repo: branch, PR link, and the status the session ended with — `pr` and `status` are
  fields in `attempt-*/fanout.json`, not prose to be parsed.
- which assertions failed, with what. When the change deployed, say which pass each
  failure came from.

Route on the outcome:

| Outcome | What it means, and what to do |
| --- | --- |
| `verified` | Deployed and asserted, locally and remotely. Nothing to fix. |
| `verified-local` | Passed locally; **no remote environment was touched**. Not shippable for a change that is supposed to deploy. |
| `contract-gap` | A slice reported it cannot be built against the frozen contract, and named the gap. Do NOT patch around it: go back to phase 2, re-freeze, update `freeze_sha`, re-run. |
| `failed` | Read `runs/<ts>/attempt-*/failure-*.md` — that is exactly what the agents were given. Decide whether the implementation is wrong (re-run with more attempts) or the assertion is wrong (fix it here, never in a product repo). |
| `blocked` | A precondition was unmet, so nothing was dispatched and nothing deployed. There is no deploy evidence to read. Fix what the dispatcher named. |
| `unattributable` | The failure could not be pinned on a slice. Check `verify.json`'s `fault`: `harness` means it is this repo's bug. |

**Do not merge anything.** Merging is a human decision, in dependency order — the repo
whose change is backward compatible on its own goes first. Record that order in `STATUS.md`.

Once a human has merged, the next step is `/realign`.

ARGUMENTS: $ARGUMENTS

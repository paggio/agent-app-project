---
name: plan-cross-repo-change
description: Planning a feature that spans backend, frontend or infra. Use when writing a change brief, splitting work across repos, or scoping anything that touches more than one repo.
---

Produce `changes/NNNN-<slug>/` — a brief plus one slice file per repo. Plan only:
no implementation, no contract edits in the same pass.

## Order of work

1. `./scripts/new-change.sh <slug>` to scaffold the directory.
2. Read `docs/product/` and `docs/adr/` before proposing anything.
3. Interview the human about the parts that are actually hard. Do not fill gaps with
   assumptions — an unstated assumption becomes three divergent implementations.
4. Write `BRIEF.md`: why, acceptance criteria, out of scope, contract changes needed.
5. Write `smoke.yaml` — the acceptance criteria as executable steps. See below.
6. Write one slice file per repo touched. Delete the ones that are not, and prune
   `slices:` in `change.yaml` to match. Set `deploy.infra` if this needs a real infra
   deploy.
7. Stop. The human reviews and edits by hand — this is where their judgement is worth
   the most.

## Acceptance criteria are the oracle

Write them as checkable statements, not aspirations. Each must map to a test, a
metric, or a manual verification step someone can actually perform. If a criterion
cannot fail, it is not a criterion.

## Then write them again, as smoke steps

`smoke.yaml` is those criteria in executable form. After the slices land, the control
repo deploys all the repos together and runs it against the single origin — that suite
is the only check that can fail on the seam between repos, since each repo's own gates
only ever prove that repo is consistent with itself.

Write the steps NOW, while planning, for two reasons. They are dispatched to the
implementing agents, so each one knows what it will be judged on before it starts. And a
criterion that nobody can express as a step is usually a criterion that was never
checkable — better to discover that here than after three repos have implemented it.

Every step needs an `owner`: the repo answerable for it. That field routes a failure back
to one agent with the request, the response and its container log attached. Guess it, and
a failing backend sends a frontend agent chasing something it cannot fix.

## Slice files

Each slice is read by an agent working alone inside that repo, which cannot see this
repo unless it is passed in. A slice therefore states what changes, which contract
entries it depends on, and how it is verified — and nothing about the other repos'
internals.

## Then

Freezing the contract is a separate step: see the `freeze-contract` skill. Never
plan and freeze in one pass, and never freeze and implement in one pass. Record the
freeze commit as `freeze_sha` in `change.yaml` — `fanout.sh` refuses to dispatch
without it.

Shipping is a third step: `./scripts/iterate.sh <change>`, or the `/ship` command.

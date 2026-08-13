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
5. Write one slice file per repo touched. Delete the ones that are not.
6. Stop. The human reviews and edits by hand — this is where their judgement is worth
   the most.

## Acceptance criteria are the oracle

Write them as checkable statements, not aspirations. Each must map to a test, a
metric, or a manual verification step someone can actually perform. If a criterion
cannot fail, it is not a criterion.

## Slice files

Each slice is read by an agent working alone inside that repo, which cannot see this
repo unless it is passed in. A slice therefore states what changes, which contract
entries it depends on, and how it is verified — and nothing about the other repos'
internals.

## Then

Freezing the contract is a separate step: see the `freeze-contract` skill. Never
plan and freeze in one pass, and never freeze and implement in one pass.

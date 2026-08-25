# 0008 — The control repo publishes the vendored contract; consumers never copy it

**Status:** accepted
**Date:** 2026-08-21
**Relation to 0001:** completes it. ADR 0001 said `contracts/` is edited here and only
here, and that product repos "vendor a read-only copy". It never said who puts the copy
there.

## Context

ADR 0001 left a gap that took a real change to expose. Each product repo carries
`contracts/openapi.yaml`, its own CI verifies its implementation against **that copy**, and
each repo forbids editing it — `Edit(./contracts/**)` in `.claude/settings.json`, plus
"NEVER edit it here" in its `CLAUDE.md`. Meanwhile the freeze happens in the control repo,
and the dispatch handed each slice the frozen tree at `changes/*/runs/*/contracts`.

So a slice implementing a frozen contract found its own vendored copy stale, and had no
sanctioned way to fix it. Change 0002 ran that experiment by accident, and the two repos
resolved the contradiction in **opposite directions**:

- `frontend` re-vendored, byte-identical. It had no choice: its `make contract` regenerates
  `wire.generated.ts` *from* the vendored spec and typechecks against it, so vendoring is
  load-bearing there.
- `chatbot-backend` did not, and said why: writes to that path are denied. Its own
  `check_contract.py` is one-directional — it walks the contract and asks whether the app
  honours it, never whether the app applies something the contract omits — so `make
  contract` printed `OK` with the app requiring a session and the vendored promise saying it
  did not.

**The correct engineering action was the one that violated the stated rule.** A repair pass
then dispatched twice against a slice that could not comply, and the second attempt spent a
full agent session to report the deadlock back rather than fix it.

Adding "re-vendor it in the slice" to the dispatch prompt — which is what was tried first —
makes the instruction and the deny rule contradict each other on purpose. That is the
failure mode ADR 0001 exists to prevent, applied to the harness rather than the interface.

## Decision

**`contracts/` has one author and one publisher, and both are the control repo.** The
dispatch copies the frozen specs into each slice repo's `contracts/` before launching its
agent, from the tree extracted at `freeze_sha` rather than from the working copy.

- `scripts/vendor-contracts.sh` is the only sanctioned writer. `fanout.sh` calls it;
  `--check` reports drift without writing.
- Product repos remain consumers and keep their deny rules. They no longer need an
  exception, because they no longer need to write there — the contradiction is dissolved
  rather than carved out.
- The slice **commits** the published copy with the rest of its work, so the promise travels
  with the pull request and the repo's CI verifies against the contract it was built for.
- `verify.sh` still compares them in preflight. Its meaning changes: it no longer catches a
  slice that forgot, it catches a slice that *edited* the copy, or a publish that did not
  run.
- Only the machine-checked specs are published. `contracts/README.md` is untouched.

## Consequences

A frozen contract reaches every consumer that verifies against it, mechanically, before any
code is written against it. The one gate that could catch a stale vendored copy is the one
in the repo that can see both trees, which is this one.

Accepted costs:

- **The dispatch now writes into a submodule.** Narrowly — two files under `contracts/`, by
  one script, from a git-extracted tree — but it is a real widening of what the control
  repo touches, and `CLAUDE.md`'s "NEVER edit inside a submodule" now has a mechanism-shaped
  exception. The `no-subrepo-edits.sh` hook deliberately still blocks an ad-hoc `cp` into
  that path: the script is the route, and a hand-written copy is still a mistake.
- **A slice that does not commit the published copy leaves the submodule dirty**, and its PR
  then omits the promise it was built against. The prompt says to commit it; nothing forces
  it. Preflight passes either way, because it compares what is on disk.
- **Publishing from the freeze means a slice can be handed a contract older than the working
  copy.** That is the point — it is the same tree the slice is judged against — but a reader
  comparing the submodule to `contracts/` mid-change will see a difference that is correct.
- **`check_contract.py` being one-directional is untouched by this**, and it is the deeper
  hole: a product repo cannot detect its own implementation running ahead of its published
  promise. Fixing it is sub-repo work, and it is the natural next change.

## Alternatives considered

- **Keep asking the slice to re-vendor, and carve an exception into each product repo's
  deny rules.** Rejected: three settings files to change, in three repos the control session
  may not write to, to permit an edit that no product repo has any business making. It also
  leaves the vendored copy authored in two places.
- **Have the slice run a sync target in its own repo** (`make contract-sync`, which the
  frontend has). Rejected as the primary mechanism: the backend has no such target, adding
  one is sub-repo work, and that is the chicken-and-egg the deadlock is made of. Worth
  adding per repo as a convenience, not as the guarantee.
- **Drop the vendored copies and have each repo read `contracts/` from the control repo.**
  Cleanest in principle and rejected by ADR 0001's own constraint: CI clones each product
  repo on its own, and a developer may clone only one. A copy in the tree is what makes the
  repo self-describing.
- **Let the loop fail and leave it to a human.** What happened. It cost two dispatched
  sessions to report a contradiction the harness created.

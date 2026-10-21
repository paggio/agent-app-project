# 0019 — Documentation moves with the code, as an owned assertion

**Status:** accepted
**Date:** 2026-10-21

## Context

The user's standing request: keep documentation current, here and in each repo, and make the
harness enforce it. Nothing did. A slice could change a repo's behaviour, pass every gate and
open a pull request whose `README.md`, `CLAUDE.md` and `docs/architecture.md` still described
the old system — and the next agent dispatched into that repo reads those first.

## Decision

1. **`verify.sh` runs `docs-currency:<repo>` per slice**, via `scripts/docs-currency.py`:
   the files changed on the slice's HEAD since its merge-base with `origin/main`. Code changed
   and no doc did is a failed assertion owned by that repo. Docs are `README.md` at any depth,
   `CLAUDE.md`, and `docs/`. The vendored `contracts/` counts as neither side; a repo with no
   changes passes.
2. **It routes like a smoke step.** `docs-currency.json` has `smoke.json`'s shape, so its
   failures land in `owners_failing` and in that repo's repair brief. The failure is deferred
   to the end of the run, so one brief carries docs and smoke together.
3. **No `origin/main` is a refusal** (`fault: harness`), never a silent pass. docs/adr/0003.
4. The dispatch prompt and the slice template say so up front.

## Consequences

- A stale doc becomes a repair pass, not a reviewer's catch.
- **Accepted cost: it checks that a doc moved, not that it is right.** A one-word README edit
  satisfies it. The bar is "someone looked"; correctness stays with review.
- **Accepted cost: a pure refactor with nothing to document still has to touch a doc.** No
  opt-out, because an opt-out is the path every slice would take.
- **Accepted cost: the control repo's own docs are not gated here** — they are prose this
  repo already holds to its scripts through `check-docs.py`.
- Committed changes only: an uncommitted doc edit does not count, as it would not reach the PR.

## Alternatives considered

- A check in each product repo's CI — four copies of one rule, each editable by the agent it
  judges.
- Mapping code paths to the doc that describes them — precise, and a table nobody keeps.
- A note in the prompt only — the state this replaces.

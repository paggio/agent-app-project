# 0012 — Correcting a change in flight is its own lane, and the objection becomes an assertion

**Status:** accepted
**Date:** 2026-09-02
**Relation to 0010:** extends it. Three lanes becomes four, along the same boundary: 0010
split "I have changed my mind" out of `/ship`; this splits out "the result is not what I
asked for". The thesis — one entry point per state, and no prose a mechanism does not hold
to account — is why the fourth exists rather than an argument against it.

## Context

`/ship` ends with the pull requests open and nothing merged, and `docs/adr/0010` gave the
window a lane for the case where the requirement itself moved. It left the more common case
uncovered: the requirement did not move, and what was built is not it.

That case had no lane and two homes in the prose. `concept.md`'s "When it does not go
cleanly" described the loop's non-green outcomes and asked the reader "is the
implementation wrong, or is the assertion wrong?", while "It went green and you still do
not like it" described a green run the reader disliked and asked them to choose between
three procedures — write a criterion, go work in the submodule by hand, or re-freeze the
contract — with the note that "picking wrong is what turns a small objection into an
afternoon". The two sections were the same defect arriving at two times, and both handed
the triage to the person with the least evidence for it.

Everything that triage needs is already mechanical. Whether a criterion exists is a fact
about `smoke.yaml`. Whether it is strong enough to fail is a fact `make verify` establishes
in one pass without dispatching anything. Which repo is answerable is `owners_failing` in
`verify.json`, computed from the `owner` field that exists for exactly this purpose. Asking
a human to guess all three, in prose, is the arrangement `docs/adr/0005` was written
against.

The middle option was also the worst one on offer. "Go and fix it by hand in the submodule"
leaves the change's record describing something nobody asserted, and it was recommended
because the loop had no way to dispatch one slice: `iterate.sh` dispatched every slice on
its first attempt, so a one-line frontend correction bought a fresh backend session too.
The workaround was documented instead of the flag.

## Decision

**`/ship-correct <change>: <what is wrong>` is a fourth lane**, and **the objection becomes
a failing assertion before anything is rebuilt.**

1. It refuses in the two states that are not its own, mechanically: the loop has never
   asserted anything — no `verify.json` under any run — in which case `/ship` resumes; and
   any pull request merged, in which case it is a new change after `/realign`. It does
   **not** require an open pull request the way `/ship-iterate` does, because `iterate.sh`
   opens one on a green outcome only, and a `failed` run is the commonest thing to arrive
   here with. Requiring one would have sent every non-green outcome back to `/ship`, which
   is the lane it just came from.
2. **The lane does the triage, not the user.** The objection is one sentence; the lane
   settles which of three states produced it — nothing asserts it, a step asserts it and
   passes, a step asserts it and already fails — from `smoke.yaml` and `make verify`.
3. **A step that does not fail has not captured the objection.** The phase does not end
   until one fails against what is already built. A criterion is never weakened to match
   what was built; a step that passes while the criterion it claims to carry is unmet is
   strengthened.
4. Routing comes from `owners_failing`, and `iterate.sh` gains `--only a,b` so the first
   dispatch can be narrowed to the repo that evidence names. Repair passes ignore it and
   follow the evidence, which by then outranks the caller's guess. Every verify still
   asserts the whole suite.
5. It re-freezes only when the objection is the interface itself, in place, superseding the
   previous `freeze_sha` — and then `--only` is dropped, because every slice is rebuilt
   against the new tree.
6. Like every lane, it ends with `harness-retro`, and `check-docs.py`'s
   `AGENT_DISPATCHERS` names it.

## Consequences

The two prose sections collapse into one lane, and the triage that was a paragraph of
advice becomes a phase with an oracle. A correction now leaves the same evidence a change
does: a step in `smoke.yaml` that failed and then passed, and a slice brief saying what was
wrong. The criterion outlives the conversation, which is the only reason the suite exists
rather than a screenshot.

Accepted costs:

- **Four lanes, and one more boundary a reader can get wrong.** `/ship-correct` and
  `/ship-iterate` share the merge boundary and differ on whether the requirement moved —
  which is a judgement, unlike the merge boundary itself. Mitigated by both lanes stating
  the distinction in their first paragraph, and by the wrong choice being cheap: an
  amendment run as a correction produces a step that will not fail, which is the signal to
  switch. Their entry conditions differ too — `/ship-iterate` needs an open pull request to
  amend, `/ship-correct` needs only a run that asserted something — and that asymmetry is
  the price of `failed` having a lane at all.
- **`--only` lets a caller narrow a dispatch on a guess.** The guess is checked one step
  later — the suite runs whole, and a failure outside the dispatched slice is routed by
  `owners_failing` on the repair pass. But where there is no repair pass there is nothing
  to correct it: `--no-repair`, and the attempt budget of 1 that a change deploying infra
  gets by default, both turn a wrong `--only` into `failed` about the change. Named in the
  flag's help and in the lane; `report.md` and `STATUS.md` both record the restriction, so
  a green line is never read as evidence about a slice nothing dispatched.
- **A change directory can now record two different reasons for a second run.** `STATUS.md`
  carries which, under `## Corrected, …` against `/ship-iterate`'s `## Amended, …`, because
  a diff of `smoke.yaml` shows a step arriving and never why. Both spellings live in the
  lanes, not in a template: nothing validates them, so they are a convention held by two
  files.
- **The refusals are prose, not code.** Both preconditions are facts (`prs.sh --list`
  against `prs.json`), and `docs/adr/0010` already recorded that `prs.sh` has no per-change
  read-only mode, so the merged check remains two commands and an inference. Unchanged
  here, and the same retro's business.
- **One more command file loaded on invocation, and one more thing `check-docs.py` must
  hold to reality.** Small; the alternative was a third reading of `/ship`.

## Alternatives considered

- **Leave it in `/ship`, which already resumes a change directory.** The status quo, and
  rejected for `docs/adr/0010`'s reason: `/ship`'s phases are numbered for a change that
  does not exist yet, phase 1 scaffolds and phase 2 freezes for the first time, and a
  procedure with two incompatible readings is the defect `docs/adr/0005` deleted four
  skills for.
- **Fold it into `/ship-iterate` and let one lane amend or correct.** Tempting, since the
  preconditions are identical and both end in the same loop. Rejected because the first
  phase is not the same instruction: amending starts at `BRIEF.md` and may drop a
  requirement, correcting must not touch the brief at all — the criteria were right. One
  file saying both is how an agent gets to choose which half it believes.
- **Keep the three-way triage and write it down better.** Rejected by this repo's own
  doctrine. The reader was being asked for two facts the harness already holds and one
  judgement it can make; better prose does not change who is answering.
- **Let the lane fix the implementation itself, here.** Rejected: the hook and the `deny`
  rules forbid writing in a product repo, and for the reason `docs/adr/0001` gives — an
  implementation written from here skips that repo's `CLAUDE.md`, its gates and its Stop
  hook, which is where "provably done" actually lives.

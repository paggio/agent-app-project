# 0009 — Every lane ends with a retrospective, and harness fixes arrive as pull requests

**Status:** accepted
**Date:** 2026-08-26
**Relation to 0005:** extends it. Still two commands; the retrospective is the last phase of
each, not a third entry point.

## Context

The thesis of this repo is that prose drifts and mechanisms do not — `docs/adr/0003`, then
`docs/adr/0005`. Every mechanism it has was added *after* a person noticed a defect.
`check-docs.py`'s checks each name one. `prs.sh` exists because a pull-request URL was
recorded verbatim and never fetched. `docs/adr/0005` exists because nine entry points had
grown for one activity and three documented guards turned out to be inert.

The noticing has never had an owner. It happened when the author re-read the repo with fresh
eyes, or when an outside agent was driven through the harness and its friction log was mined
afterwards. Between those, a lane that misled its agent misled it silently: the session
worked around the ambiguity, shipped the change, and the workaround left no trace anywhere.

The lane session is also the worst available grader of the lane. By the last phase its
context is the change rather than the machine that carried it, it has already normalised
whatever it worked around, and it has an obvious interest in the run reading as clean.

And the question a human actually asks at the end — *is this still coherent, here and in
whatever environment we claim to have deployed to?* — was answered nowhere. `report.md`
answers it for one run. Nothing joined that to the submodule pointers, the contract as
actually served, the pull requests as facts, and the gates as they stand now.

## Decision

**Each lane ends by dispatching a separate agent to grade it**: `.claude/agents/harness-retro.md`,
from `/ship` phase 6 and `/realign` step 7. Fresh context, and a subject that is the harness
rather than the feature.

1. It starts from mechanical evidence. `scripts/retro-evidence.sh` is read-only and gathers
   the same things in the same order every time: control repo, submodules against
   `repos.lock`, every attempt in the run, what reached a remote environment, the three
   gates re-run *now*, the stack, previous retros, and which proposals have already been
   decided.
2. **It always produces a state audit**, in which `not verified` is a first-class answer. A
   pass is never inferred from a silence.
3. It grades against seven fixed questions rather than an impression — including whether the
   effort was *proportionate*. Insisting five times on a minor rule is drift too, and no
   previous mechanism here could see it.
4. A finding becomes a proposal only against a four-line bar: the defect that actually
   happened, the evidence, the smallest change, and what it would have caught. Speculative
   checks are rejected by `check-docs.py`'s own stated doctrine.
5. What it proposes arrives as **at most one pull request** against this repo, on a
   `harness/` branch, merged by a human. It never writes in a product repo, never softens an
   assertion, never edits `contracts/`, never commits on `main`.
6. `retros/` is the memory. Friction recorded and tolerated once is proposable the second
   time it appears; a proposal closed unmerged does not come back without new evidence.
7. `check-docs.py` grows `AGENT_DISPATCHERS`: every lane listed there must name the agent.

## Consequences

The noticing has an owner and a cadence instead of depending on someone re-reading the repo.
The coherence question gets one grounded answer per lane. Harness changes become reviewable
diffs with their evidence attached, rather than edits slipped into a feature change by a
session that hit friction and fixed it on the way past.

Accepted costs:

- **The gate is a prompt.** The strongest available enforcement is `check-docs.py` asserting
  that both lanes still contain the instruction. A session that stops after phase 5 skips
  the retrospective and nothing fails. Wiring it into `iterate.sh` instead would cover one
  lane and only the phases inside the loop — and planning friction, the most expensive kind,
  happens before it. So: prose, held to the one thing prose can be held to.
- **Three of its four hard limits are prose.** "Never write in a product repo" is real:
  the `deny` rules and the `PreToolUse` hook in `.claude/settings.json` apply to the
  subagent as they do to any session here. "Never soften an assertion", "never edit
  `contracts/`" and "never commit on `main`" cannot be deny-ruled, because the control
  session legitimately does all three — that is what this repo is for. So they are held by
  instruction, by the diff being reviewed before it merges, and by nothing else.
  `docs/init/README.md` § "Where each new document goes" is explicit that prose is
  advisory, and the four limits should not be read as equally enforced.
- **A retrospective can be confidently wrong.** It reads this repo's doctrine and proposes
  against it; a plausible-but-wrong proposal costs more review than an obviously bad one.
  Mitigated by the four-line bar, the one-pull-request cap, and by a human merging.
- **One more agent session per lane.** Small beside `iterate.sh`, not free.
- **Pull-request pressure.** Once per lane is a rate at which "just merge it" becomes a
  habit. The single-open-`harness/`-PR rule and the empty-handed clean bill are what keep the
  count near zero when nothing is wrong. If retro pull requests start arriving every lane,
  that is the signal that the bar is set too low — and it is a signal this file expects.
- **It grades the harness that defines it**, and may propose edits to its own definition.
  Taken deliberately; the check on it is that it cannot merge.
- **`retros/` accumulates.** Dated markdown nobody prunes. It is load-bearing for exactly one
  mechanism, and should be pruned when it stops being read.

## Alternatives considered

- **Leave it to the human.** The status quo, and it worked at the rate a person re-reads
  their own repo. Every defect recorded in `docs/adr/0003` and `docs/adr/0005` was found late
  and by accident.
- **Have the lane session write its own retrospective.** Cheapest, and the grader has the
  most context. Rejected: it also has the least distance, and its context by then is the
  change rather than the machine.
- **A third command, run when someone wants a review.** Rejected by `docs/adr/0005` and by
  the reason this exists: a review that has to be remembered happens the third time it was
  needed.
- **Dispatch it from `iterate.sh` so it is mechanical.** Stronger where it applies and worth
  revisiting. Rejected for now: it reaches neither `/realign` nor the planning phases.
- **Let it commit its own fixes.** Rejected. Agents implement; humans decide. A harness that
  rewrites itself unattended removes the review step that keeps its prose honest.

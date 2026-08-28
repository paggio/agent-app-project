# 0010 — Amending a change in flight is its own lane, and merge is the boundary

**Status:** accepted
**Date:** 2026-08-27
**Relation to 0005:** amends it. Two commands becomes three. The thesis — one entry point
per activity, and no prose that a mechanism does not hold to account — is unchanged, and is
the reason the third exists rather than an argument against it.

## Context

`/ship` ends with pull requests open and nothing merged. That is deliberate: merging is a
human decision. It leaves a window, and the window is where people actually look at the
thing they asked for — which is where they change their mind.

Nothing covered that. `/ship` resumes an existing change directory, so re-running it was
possible, but its phases are written for a change that does not exist yet: phase 1 scaffolds
and writes a brief, phase 2 freezes a contract for the first time. Amending has a different
shape and two failure modes that a fresh change does not have:

- **A dropped requirement does not remove itself.** Its implementation is on the branch. An
  agent handed a brief that merely stops mentioning it leaves it there — they add, they do
  not subtract — and the slice file has to say "remove this" in words.
- **After a merge, amending is a lie.** The criteria in a merged change describe what is
  running. Editing them so they describe something else destroys the only record of what
  was decided and when, and `/realign` has already promoted some of those assertions into
  the baseline suite.

Change 0004 ran the whole procedure by hand and it was written up in `concept.md` as prose.
That is precisely the arrangement `docs/adr/0005` was written against: a documented sequence
with no mechanism holding anyone to it drifts, and the parts most likely to be skipped —
naming the dropped requirement, re-gating after it — are the parts that fail silently.

## Decision

**`/ship-iterate <change>: <instruction>` is a third lane**, and **merge is the boundary
between amending and starting again.**

1. It refuses in two mechanically checkable states rather than by judgement: no pull request
   yet (`/ship` resumes instead), and any pull request merged (a new change instead).
2. It amends in a fixed order — brief, criteria, slice files, status — because each is the
   input to the next, and because starting at the code is what produces a change whose
   record no longer matches it.
3. It re-freezes only if the interface moved, in place, superseding the previous
   `freeze_sha`. **Additive-by-default is suspended before the first merge**: that rule
   exists for deploy skew, and nothing has deployed. This is stated as a decision because
   otherwise people contort a frozen-but-unmerged contract to avoid a breakage that cannot
   happen yet.
4. It dispatches in full rather than verifying what is on disk, because the slice briefs
   themselves changed and each agent has to read the new one.
5. Images reach the slice agents as **files under `changes/<change>/evidence/`**, named in
   the slice file. `fanout.sh` dispatches text and adds the change directory to each
   session, so a path resolves and a pasted image does not.
6. Like every lane, it ends with `harness-retro`. `check-docs.py`'s `AGENT_DISPATCHERS`
   names it, so a lane that stops grading itself fails a gate rather than going quiet.

## Consequences

The window between "the criteria were met" and "somebody looked at it" has a lane, and the
two mistakes that window produces are refused mechanically instead of being written down and
hoped for.

Accepted costs:

- **Three commands, and a boundary a reader can get wrong.** `/ship` still resumes an
  unfinished change, so "which one?" is a real question. It is answered by a fact rather
  than a feeling — whether a pull request exists — and both wrong answers are refusals with
  the right lane named, but it is one more thing to know.
- **A change directory can now describe something other than what its first run built.**
  `STATUS.md` carries the amendment for that reason; a diff of `BRIEF.md` shows what moved
  but never why, and why is the part a later reader needs.
- **`prs.sh` has no per-change read-only mode**, so the merged check is "a URL in
  `prs.json` that `--list` no longer shows". That is two commands and an inference where
  one command should answer it. Recorded rather than fixed here: the lane is what needed
  deciding, and a flag on `prs.sh` is a retro's business.
- **The suspension in §3 is a sharp edge.** It is correct and it is narrow, and it stops
  being correct the instant the first pull request merges — at which point the lane refuses
  anyway, which is the mitigation.

## Alternatives considered

- **Extend `/ship` with an amendment branch.** Rejected: it doubles the length of the file
  every session already loads, and the branch would sit inside a document whose phases are
  numbered for the other case. `docs/adr/0005` deleted four skills for being reference
  wearing a procedure's clothes; a procedure with two incompatible readings is the same
  defect earlier.
- **Always open a new change.** Honest and much simpler, and rejected because it makes the
  cheap case expensive: a dropped column becomes a directory, a freeze and a fresh set of
  branches while the old ones are still open, and two changes then describe one shipped
  thing.
- **Let the loop notice the brief changed and re-dispatch itself.** Rejected for
  `docs/adr/0002`'s reason: agents implement, they do not decide whether the change is done
  — and this is the one decision that is unambiguously the human's.

---
description: Correct a change in flight — the loop has run, nothing has merged — when the result is not what was asked for. Turns the objection into a failing assertion, routes it to the repo answerable, and re-runs the loop.
argument-hint: "<change>: <what is wrong and should be corrected>"
---

Correct this:

> $ARGUMENTS

`<change>` is the directory under `changes/`. Everything after the colon is the objection —
what you looked at and what is wrong with it, in your own words.

**This lane is for "the criteria were right and the result is not."** The requirement has
not moved. If what you want is a *different* requirement — a new one, a dropped one — that
is `/ship-iterate`, and the difference decides the lane: here the build is wrong, there the
brief is.

You state the objection. **This lane does the triage** — whether the criterion is missing,
too weak, or already failing, and which repo is answerable. Do not ask the user which.

## Refuse early, mechanically

Both checks before anything else. `find changes/<change>/runs -name 'verify*.json'` is
whether anything has ever been asserted — a loop run writes `verify.json` under
`attempt-*/`, a standalone `make verify` writes it beside the run directory, a
`dev-push.sh` run downloads `verify-remote.json` into `dev-push-<id>/`, and any counts;
`./scripts/prs.sh --list` against the most recent `runs/<ts>/prs.json` is whether anything
has merged.

- **Nothing has ever been asserted** — that `find` comes back empty. Then nothing was built
  and there is nothing to object to: `/ship <change>` resumes at the phase it reached.
- **A pull request already merged** — a URL in `prs.json` that `--list` no longer shows.
  Then the criteria describe what is running and some of them are in `smoke/baseline.yaml`
  already. Correcting it is a new change; `/realign` first if this repo is behind.

**An open pull request is not required.** A `failed` run opens none — `iterate.sh` creates
them on a green outcome only — and that run is the commonest thing to arrive here with. It
is the same objection as a green run you dislike, minus the part where nobody was watching.

From here, keep a running note of anything that does not go smoothly. Phase 6 consumes it.

## 1 — Turn the objection into an assertion that fails

The objection is a sentence. Nothing routes a sentence. Read `BRIEF.md` and `smoke.yaml`
and settle which of four it is — the answer is in those two files, not in a question to
the user:

- **Nothing asserts it.** The criterion is missing, and it is missing *here*. Write the
  step in `changes/<change>/smoke.yaml`, with the `owner` of the repo answerable for it.
- **A step asserts it and passes.** Then the step is weaker than the criterion it claims to
  carry. Strengthen it — assert the value, not the status code. Never the other way round:
  a step is never weakened to match what was built.
- **A step asserts it and already fails.** Nothing to write. It is routable as it stands.
  This shape needs a step that *actually fails* under `make verify`. An outstanding item
  only a slice brief requires is not it — nothing asserts a brief.
- **Nothing is wrong.** "I am not sure there is anything to correct; check the overall
  correctness" is an assessment, not an objection, and it is a legitimate arrival here.
  Then the honest phase 1 writes no step at all: `make verify` is the assessment.

Then watch it fail against what is already built:

```
make verify CHANGE=<change>
```

Dispatches nothing; asserts what is checked out. It is strict about the branch on purpose —
it refuses unless each slice repo is on `feat/<change>`, because asserting against code
this change did not write is a pass that means nothing.

**A step that does not fail here has not captured the objection.** Go back and write the
one that does. This is the whole of the phase: a dislike that never becomes an assertion is
one the next change silently re-breaks, and the criteria are supposed to outlive the
conversation that produced them.

That rule is about a *stated defect*. Under the fourth shape a green suite IS the answer —
never manufacture a failing step to satisfy it, because a criterion nobody chose is worse
than none. Report the count and stop.

`owners_failing` in the `verify.json` that run just wrote — the path is in `make verify`'s
own output, `changes/<change>/runs/<ts>/verify.json` — now names the repo answerable.

**A red `/dev-push` routes the same way**, from `verify-remote.json` rather than
`verify.json`: `dev-push.sh` prints its path, and for a run someone else started,
`gh run download <id> -R Paggio/agent-app-project -n dev-push-evidence`. A failure only
the deployed origin shows is still an assertion — tag the step `remote` if it cannot hold
locally — and it is watched failing with `./scripts/dev-push.sh <change>`, not
`make verify`. `fault: harness` there is this repo's, including an expired session. That
is the routing, and it came from evidence rather than from a guess. Intersect it with the
change's slices: a failing owner with no slice file cannot be dispatched, and `--only`
refuses a name that is not a slice.

**On a green run `owners_failing` is empty and routes nothing.** Anything still outstanding
is then a slice-brief item, and the only oracle for one is the slice's own self-report: read
`reason` in the last run's `fanout.json` for every repo that did not report `ok`, dispatch
on that, and say in the report that the routing came from a brief rather than from an
assertion.

**A screenshot cannot be dispatched.** `fanout.sh` sends text, so an image pasted into this
session does not cross that boundary — save it under `changes/<change>/evidence/` and name
the path in the slice file in phase 3. The dispatch adds the change directory to every
slice session, so the path resolves and the agent opens it itself. Say in words what is
wrong with it as well; a path with no sentence is a puzzle. That applies whether or not the
objection is assertable — most of them are, and the screenshot is just how you noticed.

**Assertable, but not by the suite.** Between "write a step" and "no step is possible" sits
the objection no HTTP client can see — plumbing, layout, a rule about this repo's own files.
0006's credential defect was one: the loop must run with no credentials, so no step could
prove the judge reaches AWS, and the criterion was still assertable. **A check in
`scripts/check-docs.py` is the assertion then** — its doctrine is that every check names a
defect that actually happened, and a correction is exactly that. Write it before the fix and
watch it fail with `./scripts/check-docs.py`, the same way a step is watched with
`make verify`.

Then say in the report **which oracle it was**, because `verify.json`'s assertion count does
not include a gate, and a reader takes that count for the whole of the evidence.

If it cannot be expressed as a step **at all** — it is purely how something looks, or its
oracle needs credentials the loop must not require — the evidence file is the whole of the
brief, and say so in the report: an unassertable criterion is a hole the suite cannot cover,
and the next change will not know about it.

## 2 — Re-freeze, only if the interface is what is wrong

Skip unless the objection is about the interface itself — a field of the wrong shape, a
status that cannot express the case. Then it is `/ship` phase 2 again: edit `contracts/`,
**commit it alone**, put that SHA in `change.yaml` as `freeze_sha`. Every slice is rebuilt
against the new tree, so drop `--only` in phase 4.

**Additive-by-default does not bind here.** Nothing has merged or deployed, so a
frozen-but-unmerged contract can be reshaped freely. The window closes at the first merge.

A contract change costs two consumer pull requests. That is the question to ask before
making it — not whether it would be tidier.

## 3 — Say what to correct, in the slice file

The old implementation is on the branch and **agents add rather than subtract**, so a slice
brief that merely stops mentioning the wrong behaviour leaves it there. Write what to
remove or replace, explicitly, in the slice file of the repo `owners_failing` named. Then
re-read that slice whole, the way its agent does: where the correction reverses something
the old text required, say so at the TOP, before the old text is reached.

Then `STATUS.md` — a section headed exactly `## Corrected, <YYYY-MM-DD> — /ship-correct`,
with one line on what was wrong and one on what the criterion turned out to be. The
heading is spelled here because every previous second run invented its own, and
`STATUS.md` is the one file that has to be readable across changes. A diff of
`smoke.yaml` shows a step arriving and never why.

## 4 — Gate, then the loop

```
./scripts/manifest.py changes/<change> --validate
```

Exit 0, or exit 2 naming what to fix. It refuses a smoke step with no `owner` and a slice
with no step it is answerable for — which is what a hand-written correction produces most
often.

```
./scripts/iterate.sh <change> --only <the answerable repo, if it is a slice>
```

`--only` restricts the **first** dispatch; repair passes follow the evidence wherever it
leads. Use it whenever one repo is answerable — a one-line frontend correction should not
buy a fresh backend session. Drop it when more than one repo is answerable, or when phase 2
moved the freeze.

**With no repair pass there is nothing to correct a wrong `--only`.** That is `--no-repair`
or `--max-attempts 1` — drop `--only` there, since a single pass into the wrong repo reports
`failed` about the change. A change that deploys goes back through `/ship` phase 5b once the
loop is green: the loop never touches `dev`, so a remote objection is only settled there.

The branches already exist, so each session continues its own work and the open pull
requests update rather than multiply. `prs.sh --create` is idempotent and keeps the URLs.

**It takes tens of minutes.** Start it where it will outlive the turn.

## 5 — Report

Read `changes/<change>/runs/<ts>/report.md` and route on the outcome as `/ship` phase 5
does — same table, same rule that an assertion is fixed here and never in a product repo —
with one exception: its `failed` row sends the reader to this lane, and you are already in
it. Then say, and keep it short:

- the outcome **with its assertion count beside it**, and which assertion is the new one;
- what the correction turned out to be: a missing criterion, a weak one, or an
  implementation that never matched a criterion that was always there;
- anything the objection asked for that no step can assert.

Then, for the user, exactly one next step:

| Where you are | Next |
| --- | --- |
| Still not what you asked for | `/ship-correct` again — the assertion from this pass stays |
| Right, but you now want something different | `/ship-iterate <change>: …` |
| Right | A human merges, in the order `STATUS.md` records. Then `/realign` |

**Do not merge.** Still a human decision.

## 6 — The retrospective

Dispatch the `harness-retro` agent, as every lane does. Give it the lane
(`ship-correct`), the change, the run directory, the outcome, and the friction log —
including which of the three shapes phase 1 turned out to be, because a criterion that was
missing at plan time is a finding about `/ship`, not about this run. Print its report under
yours, unedited, and act on nothing in it yourself.

ARGUMENTS: $ARGUMENTS

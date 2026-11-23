Amend a change that is already in flight — pull requests open, nothing merged — and run the
loop again against them.

```
/ship-iterate <change>: <what to change>
```

`<change>` is the directory under `changes/`. Everything after the colon is the instruction:
new requirements, dropped ones, a screenshot to match. It is a change of mind, not a bug
report — for "the criteria were right and the result is not", the lane is `/ship-correct`,
which turns the objection into a failing assertion instead of rewriting the brief.

## Refuse early, mechanically

Both checks before anything else. `./scripts/prs.sh --list` shows what is open; the change's
`runs/<ts>/prs.json` shows what was opened for it.

- **No pull request for a slice yet** — nothing to amend. `/ship <change>` resumes at the
  phase it reached. This bar is higher than `/ship-correct`'s on purpose: that lane needs
  only a run that asserted something, because a `failed` run opens no pull request and is
  the commonest thing to arrive there with. Here there is no built thing to amend *toward*
  — the brief is still the only description of it, and editing it is just planning.
- **A pull request already merged** — a URL in `prs.json` that `--list` no longer shows.
  Then this is a NEW change, not an amendment: those criteria describe what is running, and
  rewriting them makes the record lie about what was decided. `docs/adr/0010`.

## Pasted images do not reach the agents

`fanout.sh` dispatches text. An image pasted into this session cannot cross that boundary.
Save it under `changes/<change>/evidence/` and name the path in the slice file — the
dispatch adds the change directory to every slice session, so the agent opens it itself.
Say in words what is wrong with it as well; a path with no sentence is a puzzle.

## 1 — Amend, in this order

Each is the input to the next. Never start with code, never with a product repo.

1. **`BRIEF.md`** — the criteria, as you now want them. Name what you dropped under
   "Out of scope" with its reason: the slice agents read that section, and a requirement
   deleted without being named there is one an agent helpfully puts back.
2. **`smoke.yaml`** — the same criteria as steps. Delete what encoded the old requirement,
   add what encodes the new. Criteria and steps drift the moment you edit one alone.
   A new criterion no step can express takes `/ship-correct` § 1 "Assertable, but not by
   the suite" unchanged: a `check-docs.py` check, or name it unasserted in `STATUS.md` and
   the report. Not the docs-currency gate — it diffs the whole branch against
   `origin/main`, so a branch that already moved a doc passes it before the amendment lands.
3. **The slice files** — and say what to **remove**, explicitly. The old implementation is
   sitting on the branch; a brief that merely stops mentioning it leaves it there. A purely
   additive amendment is a normal shape: say "Nothing is removed" rather than leaving the
   question unanswered. Then re-read the slice whole, the way the agent does — where the
   amendment reverses something the old text forbade absolutely, say so at the TOP, before
   the old text is reached. A later section contradicting an earlier "out of scope" is how
   an agent gets to choose which one it believes. Prune `slices:` in `change.yaml` if a repo
   has dropped out.
4. **`STATUS.md`** — a section headed exactly `## Amended, <YYYY-MM-DD> — /ship-iterate`,
   saying what changed and why. It is the record that this change had a second version,
   and the next reader cannot reconstruct it from a diff. `/ship-correct` writes
   `## Corrected, …` in the same place; the two spellings are what distinguish an
   amendment from a repair after the fact.

Keep a friction log from here, as `/ship` does. Phase 5 consumes it.

## 2 — Re-freeze, only if the interface moved

Skip if it did not. Otherwise exactly `/ship` phase 2: edit `contracts/`, commit it alone,
put that SHA in `change.yaml` as `freeze_sha`. The old freeze is superseded, not reconciled.

**Additive-by-default does not bind here.** That rule exists for deploy skew, and nothing
has merged or deployed. A frozen-but-unmerged contract can be reshaped freely — a field
removed, the version left where it is. The window closes at the first merge.

## 3 — Gate

```
./scripts/manifest.py changes/<change> --validate
```

Exit 0, or exit 2 naming what to fix. It refuses a slice with no step it owns, which is what
a dropped requirement produces when it carried a repo's only one.

## 4 — Iterate

```
./scripts/iterate.sh <change> --only <every slice whose brief changed>
```

Dispatch, not `--verify-only`: each agent whose brief changed has to read the new one. A
slice whose brief did not change has nothing to read, so it is not dispatched; repair
passes still follow `owners_failing`, and every verify asserts the whole suite. The branches already exist, so each session continues its own work rather than
starting over, and the open pull requests update as the branches move. `prs.sh --create` is
idempotent and keeps the existing URLs.

Read `runs/<ts>/report.md` and route on the outcome exactly as `/ship` phase 5 does — same
table, same rule that an assertion is fixed here and never in a product repo. Report the
outcome with its assertion count beside it, and say which of the criteria are new.

**Do not merge.** Still a human decision, still in the dependency order `STATUS.md` records.

## 5 — The retrospective

Dispatch the `harness-retro` agent, as every lane does. Give it the lane (`ship-iterate`),
the change, the run directory, the outcome, and the friction log — including anything about
amending that was awkward, which is the part only this lane sees. Print its report under
yours, unedited, and act on nothing in it yourself.

ARGUMENTS: $ARGUMENTS

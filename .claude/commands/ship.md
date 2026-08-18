---
description: Fan out a planned change to the product repos, deploy it, smoke it, and report.
argument-hint: <change-dir-name, e.g. 0042-csv-export>
---

Ship the change `$1`.

Shipping means the slices are implemented, deployed together, and asserted against —
not that three PRs exist. `./scripts/iterate.sh` does the whole loop and is the only
thing you need to run; everything below is about checking it is safe to start and
reading what comes back.

## Preconditions — check all of these first, and STOP if any fails

1. `changes/$1/change.yaml` validates: `./scripts/manifest.py changes/$1 --validate`.
2. `changes/$1/BRIEF.md` exists and its acceptance criteria are filled in.
3. `change.yaml` names a `freeze_sha`, and that commit is already on `main` here.
   (`fanout.sh` enforces this too — it refuses to dispatch without it.)
4. `changes/$1/smoke.yaml` has at least one step, and every step has an `owner`.
   A change with criteria but no steps is a change nobody checks; write the steps
   before shipping, not after.
5. The working tree is clean; `contracts/` has no uncommitted edits.
6. Docker is running — the loop deploys.

## Steps

1. Run `./scripts/iterate.sh $1`.

   It dispatches every slice in parallel, brings all the repos up as one stack, runs
   the smoke suite through the single origin, and on failure sends the failing
   assertion plus container logs back to the repo named in that step's `owner` — up to
   2 attempts by default. Add `--max-attempts N` for more, `--no-repair` for one pass
   and a report, `--verify-only` to skip dispatch and just check what is on disk.

2. Read `changes/$1/runs/<ts>/report.md` and report to the human:
   - the outcome: `verified`, `failed`, `contract-gap` or `unattributable`
   - per repo: branch, PR link, and the OK / FAIL line the session ended with
     (in `attempt-*/fanout.json`)
   - the smoke result — which assertions passed, and which failed with what

3. If the outcome is `contract-gap`: do NOT patch around it. A slice reported that it
   cannot be built against the frozen contract. Surface it as a new contract-freeze
   pass (see the `freeze-contract` skill), then re-freeze, update `freeze_sha`, re-run.

4. If the outcome is `failed`: read the briefs at `runs/<ts>/attempt-*/failure-*.md` —
   that is exactly what the agents were given. Decide whether the implementation is
   wrong (re-run with more attempts) or the assertion is wrong (fix it here, in the
   control repo — never in a product repo).

5. If the outcome is `unattributable`: the failure happened before any owned assertion
   ran, so it is a harness or environment problem rather than a slice problem. Read
   `runs/<ts>/attempt-*/verify.json` and the container logs beside it.

6. Do not merge anything. Merging is a human decision, in dependency order.

## After a human merges

- `./scripts/lock.sh` and commit `repos.lock`.
- Promote the smoke steps worth keeping forever from `changes/$1/smoke.yaml` into
  `smoke/baseline.yaml`, so the next change cannot silently break this one.

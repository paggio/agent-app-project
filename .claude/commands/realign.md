---
description: Bring the control repo back in line after product-repo merges — bump the submodules, re-check the contracts against what is served, re-run the baseline suite, promote the durable smoke steps.
argument-hint: "[NNNN-slug of the change that just merged, if there was one]"
---

Realign after a merge.

If a change was named, it is the one whose durable smoke steps get promoted in step 5:
> $ARGUMENTS

This is the other half of the cross-repo lane, and the lane a single-repo deploy needs on
its own. Its job is to make the four repos agree again and to prove they still work
together — because a product repo's own CI can only ever prove that repo is consistent
with itself.

## The ordering rule, first

**Merge, then `lock.sh`, then bump the pointers.** Never the other way round.
`lock.sh` records whatever commit each submodule currently has checked out; run it while a
submodule is still on a feature branch and `repos.lock` names unmerged commits — and if the
product repo squash-merged, those SHAs no longer exist on any branch. The lock then pins a
pin that cannot be checked out, which is worse than a stale lock because it looks
authoritative. The same argument forbids `git add`ing a submodule path early, and forbids
`git add -A` at the root, which sweeps every pointer in as a side effect.

So: confirm the PRs are merged before doing anything here. `./scripts/prs.sh --list` shows
them.

## First — are these instructions current?

```
git fetch -q origin && git merge-base --is-ancestor origin/main HEAD && git branch --show-current
```

This file was loaded from whatever the root had checked out. Carry on only if that prints
`main` or `chore/realign-<change>`. Anything else — a non-zero exit, a `feat/` branch — means
stop and tell the user to `git switch main && git pull --ff-only` and run `/realign` again;
a failing `chore/realign-` branch is behind a harness merge, so merge `origin/main` into it
first. Do not switch and carry on: the instructions already loaded are that branch's. On
2026-10-09 the root sat on a merged `feat/0007-dev-environment` whose copy of this file
predated `0d97eb1`, and the lane started a `dev` apply nobody wanted
(`retros/20261012T083322Z-realign-0007-dev-environment.md`).

## 0 — Is there anything to realign?

```
make repos
```

If all three submodules already **match** `repos.lock` and no change was named, nothing
product-side moved: this is what a merged harness pull request leaves behind, and by
`docs/adr/0009` that is the most frequent merge this repo sees. Steps 1, 4 and 5 then have
no input — there is nothing to bump, nothing to pin, no change directory to promote from.
Say so and go to step 7. Do not create a branch, do not commit, do not open a pull
request: an empty bump commit names the same triple the lock already names.

Steps 2 and 3 are the seam check and they are not optional on that basis alone. Run them
unless you can show a diff proving nothing the stack, the baseline or `contracts/` reads
has moved — `git diff --stat <last realign>..HEAD -- contracts/ smoke/ stack/ repos.lock
chatbot-backend frontend infra changes/` empty is that proof. Then their result is
**`not verified`, with that diff quoted**, and never a pass. The last lane that asserted
the seam is the last one that ran them; say which it was.

And from here on, keep a running note of anything that does not go smoothly — step 7 consumes
it, and by then you will have stopped noticing.

## 1 — Bring each submodule to its merged main

```
for r in chatbot-backend chatbot-eval frontend infra; do
  git -C "$r" switch main && git -C "$r" pull --ff-only
done
make repos
```

`make repos` prints branch, SHA, how each compares to `repos.lock`, and how many files are
uncommitted in it. Do **not** use `git submodule update --remote --merge`: it yanks a
checked-out submodule back and discards in-flight commits.

**Read the `uncommitted` column before the loop, not after.** Unmerged work is not only a
branch: `git switch` carries a dirty file to `main` rather than refusing. Anything but
`clean` means stop for that repo, name the file, leave it. This repo's own `git status`
cannot tell you — a moved pointer and a dirty submodule both print ` M <repo>`.

## 2 — Is the contract still true?

```
make up
./scripts/harvest-contract.py --diff
```

The draft is taken from the running service, not from reading source. Findings are
classified by what they would do to a consumer, and the direction decides: a required field
added to a *request* breaks callers, the same field added to a *response* is harmless; a
field removed from a *response* breaks consumers, removed from a *request* it does not.

- **Agrees, or additive only** — nothing to do. Note it and move on.
- **Declared by the implementation, never observed** — a status read off `/openapi.json`,
  which is not evidence the service ever returns it. Do not promise it on that basis: probe
  the running service first, and check `contracts/README.md` does not already promise
  something else for that case.
- **Anything BREAKING** — stop. Do not write. The default answer is expand-and-contract:
  add the new shape alongside the old, migrate every consumer, remove the old in a later
  change. `--accept-breaking` exists only for the case where you have established that
  nothing consumes the old shape yet.
- **Something real was built and now needs to become a promise** — `--write` drafts it in,
  then **review the draft; that is the step that matters**. Generated specs carry the
  implementation's vocabulary: rewrite `operationId` (FastAPI emits `chat_v1_chat_post`;
  write `postChat`), rewrite `summary`/`description` for someone who does not have the
  implementation in front of them, and **delete surface that should not be public** —
  everything served gets harvested, and an endpoint being reachable is not a decision to
  promise it forever. Your wording survives the next harvest; structure does not. Then
  commit `contracts/` alone: that commit is a freeze point like any other.

## 2b — Publish the contract into every consumer, not just the slices

```
./scripts/vendor-contracts.sh --check
```

`fanout.sh` publishes the freeze with `--repos "$TARGETS"` — **the slices only**
(`scripts/fanout.sh:112`), and nothing else publishes at all. A repo that vendors
`contracts/openapi.yaml` and was not a slice keeps verifying against last month's promise,
and `[vendored-contracts]` then fails for everyone. Making the four repos agree is this
lane's job, so the catch-up is too.

Exit 0 — nothing to do. Exit 1 names each stale copy; for each one:

```
git -C <repo> switch -c chore/vendor-contracts-<change>
./scripts/vendor-contracts.sh --repos <repo>
make -C <repo> contract-sync   # only if the repo has one — `make -C <repo> help`; frontend
                               # generates wire types FROM the spec, the others do not
make -C <repo> contract && make -C <repo> typecheck
git -C <repo> commit -am "chore: vendor the contract as of <change>"
```

then push and open its pull request. **This is the one sanctioned write into a submodule
this lane has:** `docs/adr/0008` makes this repo the publisher and `vendor-contracts.sh` the
only writer, and outside a dispatch there is no agent in that repo to commit what was
published. Editing the vendored file by hand is still a mistake and the hook still blocks it.

**Step 4 waits for it.** The ordering rule at the top covers this lane's own pull requests
too: pin a repo while your own unmerged commit for it is outstanding and you pin a SHA you
are about to supersede — the lock is wrong the hour it lands, and the lane has to be run a
second time to correct it. Stop here instead, say which pull request must merge, and resume
at step 4 once it has.

## 3 — Does the joined system still work?

```
make smoke
```

The baseline suite, through the single origin. If it fails, the seam is broken and the
`owner` on the failing step names the repo answerable. That is a slice or a session inside
that repo — never a fix here, and never a weakened assertion.

For a change that also needs the browser, `make e2e`.

## 4 — Pin it, in one commit

```
git switch -c chore/realign-<change>
./scripts/lock.sh
git add chatbot-backend chatbot-eval frontend infra repos.lock
git commit -m "chore: bump submodules for <change>"
```

Nothing is pinned while this lane still has unmerged work of its own outstanding (§ 2b).

**If `chore/realign-<change>` already exists, this is a second pass over that change.**
Switch to it rather than branching, add a commit, and comment on its open pull request —
one change gets one realign branch and one pull request. The commit message says why the
earlier pin stopped being right.

That commit contains the pointers and `repos.lock` and nothing else, and it is on a branch:
nothing lands on this repo's `main` except through a reviewed pull request. A bump is not
an exception — it is the commit that decides which four SHAs are believed to work together.

## 5 — Promote the durable smoke steps

If a change just merged, move the assertions from `changes/<change>/smoke.yaml` that are
worth keeping forever into `smoke/baseline.yaml`. This is how the loop stops re-breaking
what an earlier change fixed.

If the change's durable steps are already in the baseline — a second pass, or a promotion an
earlier lane did — there is nothing to promote. Say so; the rest of this step still runs.

Keep the baseline fast and keep it about the **seam**. Anything provable inside one repo
belongs in that repo's own suite, not here.

**Re-judge each tag rather than copying it.** A `local` tag records why the step could not
run against a deployed origin in *that change* — no deployed Phoenix, no credentials — and
the baseline is a different suite with a different reach. Carry the tag when the reason
still holds (it asserts a local value, a local-only service); drop it when the reason was
circumstantial (a session gate, an enum, a credential-leak check are true of any origin),
and say which you did and why in the commit message.

Then `make check`, and re-run the baseline **against a stack that was just rebuilt**:

```
make restart && make smoke
```

A second `make smoke` against the stack already up can only fail for a reason the first run
already caught. The restart is what asserts the promise, because `docs/adr/0011` says the
stack forgets everything on `down`: a promoted step that depends on something *produced*
rather than served fails here and nowhere else. Expect that of a change with `jobs:`
(`docs/adr/0014`) — its one-shot jobs run in the verify loop and never in the baseline, so
every step reading what a job produced is unpromotable. Then commit on the same branch.

**Close the change out in the same commit.** The `<!-- iterate:begin -->` block in
`changes/<change>/STATUS.md` is written by `iterate.sh` and records the *loop's* last
attempt, not the change's fate — a change whose last run failed for a blocker a human then
waived merges with `- **failed**` as its permanent record. Write under it what the merge
settled: the merged pull requests, the SHAs now in `repos.lock`, what was promoted. No other
lane knows this, and nothing else ever says the change shipped.

Then push it and open the pull request (`gh pr create`), and do not merge it. Say in the
body what moved, what the harvest said and what you did about it, and what you promoted.

## 5b — Deploy the pin, assert it where it runs, and evaluate it

```
./scripts/dev-push.sh --lock --pr <realign pr>
./scripts/dev-eval.sh --pr <realign pr>        # only once dev-push is verified
```

Both comment on the realign pull request (`/dev-push`, `/dev-eval`) rather than dispatching
the workflow, so the user can follow every deploy from the PR.

Every repo at this branch's gitlinks — the bump under review — deployed to `dev`, and the
baseline asserted through the CloudFront origin. **Not optional after a product merge:** a
squash merge mints new SHAs, so the images a PR's `/dev-push` verified are never the merged
ones. "Shipped" (`docs/adr/0002`) is this run, not the merge.

Exit 2 is a refusal — most often an expired session: `make login && make push-gh-creds`,
then again. Exit 1 is a red seam: the failing step's `owner` names the repo answerable, and
the fix is a session in that repo, then this lane again — never a weakened assertion here.

The eval runs `chatbot-eval` against what `dev` now runs. Exit 1 is a breached threshold or
an errored example: the merged code answers worse, and the eval report names where — a
session in `chatbot-backend` (or in `chatbot-eval`, if the eval itself is wrong), never a
threshold lowered here.

Put both verdicts and run URLs in the pull request body. The user is asked to review only
once both are green. Skip it only in the step-0 case where nothing product-side moved, and
say so. `dev` bills while it is up: say in the report that it is.

## 6 — Report

Say, in this order: which submodules moved and to what; whether the contract still matches
what is served, and what you did about it if not; the baseline result with its assertion
count, locally and against `dev` (5b), the eval verdict, and whether `dev` is still up; what was promoted into the baseline; and anything you deliberately left alone.

## 7 — The retrospective

Dispatch the `harness-retro` agent. This lane is where drift becomes visible — a contract
that had to be harvested, a promotion that was awkward to write, a submodule that was not
where the instructions assumed — and none of it is recorded anywhere unless something looks.

Give it, in the prompt:

- the lane (`realign`), the change if one was named, and what step 6 concluded;
- **the friction log** — the part only you have. What the harvest diff actually said and
  what you did about it, anything you had to work out rather than read, a step whose
  preconditions did not hold, anything you did by hand. "It went fine" is a claim it will
  check against the artifacts.

It audits the state this lane left behind, grades the harness against a fixed set of
questions, and opens at most one pull request here if something clears its bar. Print its
report under yours, unedited. Do not act on it yourself: a harness fix is reviewed and
merged like any other change, not applied on the way past.

ARGUMENTS: $ARGUMENTS

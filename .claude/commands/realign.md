---
description: Bring the control repo back in line after product-repo merges — bump the submodules, re-check the contracts against what is served, re-run the baseline suite, promote the durable smoke steps.
argument-hint: "[NNNN-slug of the change that just merged, if there was one]"
---

Realign after a merge.

This is the other half of the cross-repo lane, and the lane a single-repo deploy needs on
its own. Its job is to make the four repos agree again and to prove they still work
together — because a product repo's own CI can only ever prove that repo is consistent
with itself.

## The ordering rule, first

**Merge, then `lock.sh`, then bump the pointers.** Never the other way round.
`lock.sh` records whatever commit each submodule currently has checked out; run it while a
submodule is still on a feature branch and `repos.lock` names unmerged commits — and if the
product repo squash-merged, those SHAs no longer exist on any branch. The lock then pins a
triple that cannot be checked out, which is worse than a stale lock because it looks
authoritative. The same argument forbids `git add`ing a submodule path early, and forbids
`git add -A` at the root, which sweeps every pointer in as a side effect.

So: confirm the PRs are merged before doing anything here. `./scripts/prs.sh --list` shows
them.

## 1 — Bring each submodule to its merged main

```
for r in chatbot-backend frontend infra; do
  git -C "$r" switch main && git -C "$r" pull --ff-only
done
make repos
```

`make repos` prints branch, SHA and how each compares to `repos.lock`. Do **not** use
`git submodule update --remote --merge`: it yanks a checked-out submodule back and discards
in-flight commits. If a repo still has unmerged work, stop and say so rather than moving it.

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
./scripts/lock.sh
git add chatbot-backend frontend infra repos.lock
git commit -m "chore: bump submodules for <change>"
```

That commit contains the pointers and `repos.lock` and nothing else.

## 5 — Promote the durable smoke steps

If a change just merged, move the assertions from `changes/<change>/smoke.yaml` that are
worth keeping forever into `smoke/baseline.yaml`, carrying their tags across — a step
tagged `local` is tagged that way for a reason. This is how the loop stops re-breaking what
an earlier change fixed.

Keep the baseline fast and keep it about the **seam**. Anything provable inside one repo
belongs in that repo's own suite, not here. Then `make check` and commit.

## 6 — Report

Say, in this order: which submodules moved and to what; whether the contract still matches
what is served, and what you did about it if not; the baseline result with its assertion
count; what was promoted into the baseline; and anything you deliberately left alone.

ARGUMENTS: $1

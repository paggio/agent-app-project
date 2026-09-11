---
lane: realign
change: 0006-chatbot-eval
run: none
date: 2026-09-11
verdict: coherent-with-warnings
findings: 2 proposed, 5 recorded, 4 rejected
pr: https://github.com/Paggio/agent-app-project/pull/18
---

Second `/realign` invocation for 0006-chatbot-eval, run because the first one pinned
`frontend` at `d9b76a8` and then opened `paggio/frontend#7` against that same repo.

## State audit

- **Control repo** — `chore/realign-0006-chatbot-eval` at `aa89e20`, pushed, PR #20 open
  with four commits. Working tree carries only three submodule pointer lines, all of them
  dirty-worktree rather than moved SHA (below). `contracts/` 0 changed files against HEAD;
  last touched by the freeze `c0ff827`, contracts only.
- **contracts/ freeze** — `freeze_sha` in `changes/0006-chatbot-eval/change.yaml:8` only;
  `[freeze-sha-home]` green. Still quoted narratively in three prose files (R4 of
  `20260911T154844Z`, unchanged and still not worth a gate).
- **Submodules** — all four on `main` and all four matching `repos.lock`: `chatbot-backend
  7bf1af6`, `chatbot-eval 822de24`, `frontend 3dc80ec`, `infra 6eebe0a`. That is what
  `/realign` should leave, and it is the first lane in four to leave it. **Three of them
  still hold an uncommitted `.claude/settings.json`** — system defect, reported to the user.
- **Contract against what is served** — the lane's `harvest-contract.py --diff` (exit 0,
  nothing breaking, the same five never-returned 422s) is testimony: `/realign` writes no
  artifact (R1). What is on disk is still `runs/20260910T160833Z/attempt-1/harvest.log`
  from the preceding `/ship-correct`. `vendor-contracts.sh --check` **re-run from here:
  exit 0, every vendored copy matches** — that one is evidence, and it is the first clean
  result since the 0006 freeze.
- **Assertions** — `make smoke` **re-run from here: 69 passed, 0 failed**, against the
  warm stack. `smoke/baseline.yaml` holds 69 steps, so the count is the whole baseline. The
  lane's *cold*-stack run (`make down && make up`) is testimony; the number matches.
  Change-suite provenance: the 8 steps promoted by `66f1651` came from 0006's own
  `smoke.yaml`, the other 61 predate it. Not a thin count.
- **The cloud** — nothing reached a remote environment. `deploy.infra: false`,
  `infra.remote_asserted: false`, `environment: null`. `verified-local`, and no lane in this
  change claimed otherwise.
- **Pull requests** — #20 (this lane) and #18 (harness) confirmed OPEN via `gh`.
  `paggio/frontend#7` confirmed **MERGED at 16:19:48Z**, nine minutes before the re-pin
  commit `aa89e20` at 16:29:12Z — the ordering the second invocation existed to get right.
  No `prs.json`; `/realign` does not run `prs.sh --create`.
- **Gates, re-run now** — `check-docs.py` exit 0 (23/23 + 1 known warning on the lane's
  branch; 24/24 on this one), `test-hooks.py` exit 0 over 12 blocks and 6 allows, full
  `make check` green including all four product repos' lint and typecheck.
- **Stack** — nine services up and healthy. Standing note since 0004 R8, not new.

## Findings

### F1 — § 2b tells the lane to pin a repo while its own unmerged pull request for that repo is outstanding

- **Evidence:** the lane's first invocation ran `lock.sh` at step 4 with `frontend` at
  `d9b76a8`, then did the vendoring catch-up and opened `paggio/frontend#7` — pinning a SHA
  it was about to supersede, and forcing this second invocation and commit `aa89e20`. The
  fix proposed for that gap, § 2b of `.claude/commands/realign.md` on this branch, moved the
  catch-up *before* the lock but closed with "That pull request merges on its own and does
  not hold up step 4; say in the report that the repo is a commit ahead of `repos.lock`
  until it does" — which sanctions the same outcome in one sentence. The lane's own opening
  rule says merge → `lock.sh` → pointers and gives the reason ("the lock then pins a pin
  that cannot be checked out"); it reads as being about *other people's* pull requests
  throughout.
- **Judgement:** question 2 — an instruction contradicted by the rule three screens above
  it, in the section written to cure the class it reproduces. Second occurrence of an
  ordering defect that has now cost a whole extra lane invocation; the user named it
  ("why could I not merge `frontend#7` first and realign once?") and was right.
- **Disposition:** proposed. § 2b's closing paragraph stops at the pull request and resumes
  at step 4 once it merges; § 4 says nothing is pinned while this lane has unmerged work of
  its own. Would have caught: the first invocation would have handed back after § 2b, the
  user would have merged `frontend#7`, and one `lock.sh` would have pinned `3dc80ec`.

### F2 — a second pass over the same change has no shape, and § 4's literal command creates the wrong thing

- **Evidence:** `.claude/commands/realign.md` § 4 says `git switch -c
  chore/realign-<change>` unconditionally. The branch already existed and PR #20 was open,
  so the command as written either fails or — with a different name — opens a second realign
  pull request for one change. The lane decided by judgement to add a commit to the open
  branch, and was right, but nothing in the lane says so. § 5 has the mirror hole: it opens
  "If a change just merged, move the assertions…" and has no wording for a change whose
  steps the *previous invocation* already promoted; the lane read "nothing to do" by
  implication, and a reader could equally re-promote.
- **Judgement:** second occurrence of the class `20260903T091831Z-realign` F1/F2 named —
  "/realign had no wording for a run with nothing to bump, nothing to pin and nothing to
  promote". That fix added § 0 for the empty run; it does not cover the second pass, where
  there *is* something to pin. Two paragraphs in the steps that own each decision.
- **Disposition:** proposed. § 4 gains the second-pass branch rule; § 5 gains one sentence
  for an already-promoted change. Would have caught: the branch-or-not-branch decision the
  lane made from first principles, and the re-promotion a less careful reader would do.

## Recorded, not proposed

- **R1 — `/realign` still writes no run artifact. Fourth occurrence** (`20260902T130637Z`
  R3, `20260911T154844Z` R1, and this lane's friction log). Two audit lines above are the
  lane's testimony because of it: the harvest, and the cold-stack baseline. I could
  corroborate both only because the stack is still up — `make smoke` 69/0 and
  `vendor-contracts.sh --check` exit 0 are mine, the *cold* run is not. Unchanged reason for
  not proposing: the destination for a realign with no named change is a decision, not a
  diff.
- **R2 — `make repos` is still blind to a dirty submodule. Third occurrence** — the lane
  again ran a hand-written `git status --porcelain` loop before touching anything, and the
  same uncommitted `.claude/settings.json` is in three repos. The fix is F3 of
  `20260911T154844Z`, already on this branch and unmerged; nothing to add but the count.
- **R3 — the control repo's ` M <repo>` conflates a moved pointer with a dirty worktree**
  (friction 7: `MM frontend`). This is R2 seen from the root rather than a second defect,
  and the `uncommitted` column already on this branch is the answer to both.
- **R4 — four interdependent pull requests are open and nothing records the order.** #18
  (harness), #20 (this realign), and `paggio/frontend#7` which had to merge before #20's
  second pin was true. `prs.sh --list` shows PRs for a change's slices; it has no notion of
  a dependency between them, and the ordering lived only in the lane's prose to the user.
  Real, and the smallest honest fix is not obvious — a `depends_on` in `change.yaml` covers
  slice PRs, and neither #18 nor `frontend#7` is a slice. Recorded for the third
  retrospective to price.
- **R5 — the lane adopted an unmerged retro proposal as a practice, and that is the right
  line.** It ran `make down && make up && make smoke` (F2 of `20260911T154844Z`) without
  touching the diff on this branch. Running a check by hand is a lane's own judgement; only
  *applying* the harness fix would have been the violation `CLAUDE.md` forbids. The payoff
  is that F2 is now confirmed by a run — 69/0 on a genuinely cold stack proves the promoted
  steps do not depend on what 0006's `jobs:` produced.

## Rejected

- **A gate that refuses `lock.sh` while a submodule has an open pull request.** It needs
  the network and `gh` in a script several lanes run offline, and the SHA it would have
  caught here was legitimately on `main` — the defect is a *pending newer* commit, which no
  local check can see. F1's prose sits where the actor is.
- **Making `prs.sh` model dependencies between pull requests (R4).** Two of the three PRs in
  this run were not slices of any change, so the data has no home in `change.yaml`. A
  redesign, not a fix.
- **Anything about the five never-returned 422s, the `[vendored-contracts]` warning, or the
  stack left up.** Each is an accepted cost recorded in an ADR or a standing note.
- **Re-raising `/realign`'s missing run artifact as a diff (R1).** Declined twice before on
  the same ground and no new evidence beyond the count.

## Not verified

- **The lane's cold-stack baseline and its harvest** — no artifact (R1). The warm re-run
  from here agrees with the count.
- **Product-repo remotes other than `paggio/frontend#7`**, which was fetched and is merged.
- **Anything requiring AWS credentials.** Nothing in this change reaches a remote
  environment by design, so there is no environment to assert.

---
lane: realign
change: 0006-chatbot-eval
run: none
date: 2026-09-11
verdict: coherent-with-warnings
findings: 4 proposed, 5 recorded, 4 rejected
pr: https://github.com/Paggio/agent-app-project/pull/18
---

## State audit

- **Control repo** — `chore/realign-0006-chatbot-eval` at `66f1651`, pushed, PR #20 open.
  Tree carries only the three submodule pointers (below); no stray file. `contracts/` 0
  changed files against HEAD, last touched by the freeze `c0ff827` (contracts only, 2 files).
- **contracts/ freeze** — `freeze_sha` in `changes/0006-chatbot-eval/change.yaml` only;
  `[freeze-sha-home]` green. The SHA is also quoted in three prose files — see R4.
- **Submodules** — `chatbot-backend 7bf1af6` and `chatbot-eval 822de24` on `main`, matching
  `repos.lock`; `infra 6eebe0a` on `main`, matching. **`frontend` is on
  `chore/vendor-contracts-0006` at `b77d8ee`, one commit ahead of the lock's `d9b76a8`** —
  `/realign` is supposed to leave `main`. **All three moved repos hold an uncommitted
  `.claude/settings.json`**, carried onto `main` by step 1's switch loop. Both are system
  defects, reported to the user; see F3 and R5.
- **Contract against what is served** — re-checked in this lane per the lane's report, but
  **not verified from here**: `/realign` writes no artifact (R1). The newest harvest on disk
  is `changes/0006-chatbot-eval/runs/20260910T160833Z/attempt-1/harvest.log` from the
  preceding `/ship-correct` — exit 0, five declared-never-observed 422s, nothing breaking.
- **Assertions** — the baseline's 69/0 is the lane's testimony, not an artifact (R1). What is
  on disk is the change's last run: 91 passed, 0 failed, 28 of them from
  `changes/0006-chatbot-eval/smoke.yaml`. That is not a thin count. The promotion commit
  `66f1651` adds 97 lines and 8 steps to `smoke/baseline.yaml`, 61 + 8 = 69 consistent.
- **The cloud** — nothing. `deploy.infra: false`, `infra.remote_asserted: false`,
  `environment: null`. `verified-local`, and no lane in this change ever claimed otherwise.
- **Pull requests** — `#20` and `#18` confirmed open via `gh`. `paggio/frontend#7` is the
  lane's claim; not fetched from here. No `prs.json` exists for this lane — `/realign` does
  not run `prs.sh --create`.
- **Gates, re-run now** — `check-docs.py` exit 0 (23/23 on the lane's branch, 24/24 with this
  branch's extra check), `manifest.py --validate` exit 0, `test-hooks.py` exit 0 over 12
  blocks and 6 allows, and full `make check` green including all four product repos' lint and
  typecheck. First clean `make check` in four lanes, and it is clean only because the lane
  hand-vendored the contract into `frontend` — F1.
- **Stack** — all nine services up and healthy, the two application containers 6 minutes old.
  Standing note since retro 0004 R8, not new.

## Findings

### F1 — a contract freeze reaches the slices and no one else, and no lane owns the catch-up

- **Evidence:** `scripts/fanout.sh:112` publishes with `--repos "$TARGETS"`, the slices only;
  `grep -rn vendor-contracts .claude scripts Makefile docs` shows `fanout.sh` as its sole
  caller and no lane file naming it at all. `frontend` vendors `contracts/openapi.yaml` and
  was not a slice of 0006, so the `c0ff827` freeze never reached it and
  `check-docs.py:562 [vendored-contracts]` failed for every session on every branch from the
  freeze onward. The lane repaired it by hand: branch, `vendor-contracts.sh --repos frontend`,
  `make contract-sync`, `make contract`, `make typecheck`, commit, push, PR #7 — five steps
  and a judgement about which target regenerates `wire.generated.ts`, none of it written down.
  Third occurrence: `20260827T153500Z-ship-iterate-0004` R2, `20260907T150124Z-ship-iterate-0006`
  F1 (which narrowed the *gate* and left the *publish* gap untouched).
- **Judgement:** `docs/adr/0008` decides that "a frozen contract reaches every consumer that
  verifies against it, mechanically". The implementation delivers that to slices only, so the
  ADR's own decision is what is unmet — this is not an argument with it. The detector exists
  and has fired three times with nothing to route to.
- **Disposition:** proposed. `/realign` § 2b: `vendor-contracts.sh --check`, and on exit 1 the
  exact per-repo sequence, with the ADR 0008 sanction for the commit stated so the next lane
  does not have to re-derive it under time pressure.

### F2 — § 5's second `make smoke` runs against the stack that is already up, so it could not fail

- **Evidence:** `.claude/commands/realign.md` § 5 — "`make smoke` again — the promoted steps
  have only ever run against the stack that is up, and the baseline's job is to pass on the
  next one too". It names the risk and then prescribes the run that cannot see it. Friction
  log 8: 69/69 twice, same stack both times. The stack that was up carried two eval runs'
  Phoenix dataset, experiments and eval-account threads, produced by
  `changes/0006-chatbot-eval/change.yaml`'s two `jobs:`; `docs/adr/0011` says none of it
  survives `down`. 21 of 0006's 28 steps read exactly that state.
- **Judgement:** question 1 — a gate that could not have failed on this run. `make restart`
  already exists (`Makefile:49`) and costs one stack cycle at the end of a lane. § 5 also
  never mentions `jobs:`: `docs/adr/0014` landed *during* 0006 and no lane was updated, so
  0006 was the first change with jobs and this the first realign after it. The lane got the
  promotion right by reading `change.yaml` and reasoning, with no help from the harness.
- **Disposition:** proposed. § 5 prescribes `make restart && make smoke` and names the
  job-dependent step as the thing it catches.

### F3 — `make repos` cannot see a dirty submodule, and step 1's stop condition depends on seeing one

- **Evidence:** `Makefile:155` printed four columns and none of them was `uncommitted`, while
  `.claude/commands/realign.md` § 1 says "If a repo still has unmerged work, stop and say so
  rather than moving it" and then hands you `make repos` as the instrument. `git switch main`
  carries a dirty file across instead of refusing, and the control repo's `git status` prints
  ` M <repo>` identically for a moved pointer and a dirty worktree. Result on this run: an
  uncommitted `.claude/settings.json` in three product repos rode onto `main`, which is the
  state this lane ended in. `retro-evidence.sh` § 2 already computes the column, so the lane's
  own evidence bundle could see what the lane's own tool could not.
- **Judgement:** a mechanism, four lines, in the tool the lane is already told to read.
- **Disposition:** proposed. `uncommitted` column on `make repos` (`clean` or `N file(s)`),
  and § 1 says anything but `clean` stops that repo.

### F4 — a merged, green change records `- **failed**` as its permanent outcome, forever

- **Evidence:** `git show origin/main:changes/0006-chatbot-eval/STATUS.md:48` —
  `- **failed** — 20260910T160833Z, 1 attempt(s)` — while that run's
  `verify.json` says `"status": "pass"` with 91 assertions and 0 failures, and every product
  PR merged. The block is machine-written by `iterate.sh` from the *loop's* outcome (the
  slice self-reported `failed` over a settings-file blocker needing a human), and no lane
  revisits it after the merge. `2fdbecb`'s own message records the same class a second time:
  "third lane in which the run's record was left uncommitted, and no lane tells you to commit
  it" — it fixed the block by hand on 09-07, and two `/ship-correct` runs overwrote it again.
- **Judgement:** question 7. `CLAUDE.md` says "'Three PRs exist' is not shipped: shipped means
  deployed together with the smoke suite passing", and `/realign` is the lane that establishes
  it — and the only one that knows the merge happened. Nothing in it writes that down.
- **Disposition:** proposed, as one paragraph inside § 5's existing commit rather than a new
  step: write what the merge settled under the `iterate:` block.

## Recorded, not proposed

- **R1 — `/realign` still writes no run artifact, third occurrence.** It re-runs two oracles,
  the harvest and the baseline, and neither leaves a file. `20260902T130637Z-realign-0005` R3
  recorded it on the grounds that the evidence was re-derivable while the stack was up; the
  lane's friction log 7 recorded it a second time on the same grounds. It is now costing the
  audit directly: two of this retro's audit lines are the lane's testimony rather than
  evidence. The fix is small on the surface (`--json`, `tee`) and not small underneath — a
  realign with no named change has nowhere to write, and `changes/*/runs/` is gitignored. That
  destination is a decision, not a diff, which is the only reason it is not in this PR.
- **R2 — `CLAUDE.md`'s "NEVER edit inside a submodule from here" has no written exception.**
  `docs/adr/0008` carved a mechanism-shaped one for `vendor-contracts.sh` and recorded it as
  an accepted cost; the hard rule never picked it up, so the lane committed inside `frontend`
  while unsure whether it was allowed (friction 3). It was: the script wrote, the hook
  correctly did not fire, and ADR 0008 § Consequences names exactly this. F1 puts the sanction
  where the actor reads it. A clause in `CLAUDE.md` is the user's own edit to make.
- **R3 — the five declared-never-observed 422s were re-read and re-decided for the fifth lane.**
  `20260902T130637Z-realign-0005` F3's fix is merged and working — the section is headed
  correctly and the footer says a declaration is not behaviour. The recurring cost is inherent
  to harvesting a live spec, and suppressing it would hide a real change to the served
  surface. Nothing to do.
- **R4 — `c0ff827` is quoted in `BRIEF.md`, `STATUS.md` and `chatbot-eval.md` as well as
  `change.yaml`.** Second occurrence (`20260827T153500Z-ship-iterate-0004` R5, where a moved
  SHA bit). `[freeze-sha-home]` is green because it guards machine-read homes only, and all
  four strings agree today. Prose that repeats a fact is cheap until the fact moves; not worth
  a gate that would forbid quoting a SHA in a narrative.
- **R5 — the system defects this lane left are not harness diffs.** Three product repos dirty
  on `main`, one on a feature branch ahead of the lock with an unmerged PR. F3 removes the
  cause for the next run; the current state is the user's to clear, and this retrospective does
  not touch a product repo.

## Rejected

- **Make `fanout.sh` publish to all four repos at freeze time.** It would leave two repos the
  change never touched with a dirty worktree and no agent to commit it, and it contradicts
  ADR 0008's reason for publishing *from the freeze* into the repos being judged against it.
- **A check that a promoted baseline step is not job-dependent.** There is no machine-readable
  link from a step to the job whose output it reads. F2's cold restart is that oracle, and it
  is the one that already exists.
- **Exit non-zero from `make repos` on a dirty submodule.** It is an informational tool several
  lanes and the user run, and `/ship` legitimately runs with dirty submodules mid-change. A
  hard exit would block the lanes it exists to inform. The column is the whole fix.
- **Anything about the five 422s, the vendored `contracts/README.md` warning, or the stack
  left up.** Each is an accepted cost recorded in an ADR or a standing note, not a defect.

## Not verified

- **`paggio/frontend#7` and the state of the other product repos' remotes** — no fetch from
  here; the PR is the lane's claim.
- **The realign's own harvest and baseline runs** — see R1. Re-derivable only while this stack
  is up, and it is up.
- **Anything requiring AWS credentials.** Nothing in this change reaches a remote environment
  by design (`deploy.infra: false`), so there is no environment to assert.

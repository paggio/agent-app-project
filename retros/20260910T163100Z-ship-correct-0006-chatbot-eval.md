---
lane: ship-correct
change: 0006-chatbot-eval
run: changes/0006-chatbot-eval/runs/20260910T160833Z
date: 2026-09-10
verdict: coherent-with-warnings
findings: 2 proposed, 7 recorded, 4 rejected
pr: https://github.com/Paggio/agent-app-project/pull/18
---

## State audit

- **Control repo** — clean on `feat/0006-chatbot-eval` @ `1ca41e3`. The three ` M
  <submodule>` lines are dirty submodule *worktrees*, not moved pointers: `git submodule
  status` shows no `+` on any of them.
- **`contracts/` committed alone** — yes. `c0ff827` "contracts: freeze GET /v1/version for
  0006" touches `contracts/` only; 0 changed files against HEAD; `freeze_sha` is in
  `change.yaml` and nowhere else (`check-docs.py [freeze-sha-home]` green).
- **Submodules** — `chatbot-backend` `14dace1` and `chatbot-eval` `457fc4d` on
  `feat/0006-chatbot-eval`, both ahead of `repos.lock`: correct for `/ship-correct`.
  `frontend` `d9b76a8` and `infra` `6eebe0a` on `main`, matching the lock; neither is a
  slice. **Three carry an uncommitted `.claude/settings.json`** and `frontend`'s is on
  `main`, where CLAUDE.md forbids committing it.
- **Contract against what is served** — re-checked in this lane.
  `runs/20260910T160833Z/attempt-1/harvest.log`, stage `contract_harvest: pass`, carrying
  the same five "declared by the implementation, never observed" 422s as 0005 (F3 /
  20260902, accepted).
- **Assertions** — 91 passed, 0 failed, 28 of them from
  `changes/0006-chatbot-eval/smoke.yaml`; 2 of 2 declared `jobs:` ran and exited as
  declared. Not a thin count.
- **The cloud** — nothing reached a remote environment. `infra.remote_asserted: false`,
  `environment: null`, `deploy.infra: false` by design; `verified-local` is the ceiling and
  the lane claimed no more.
- **Pull requests** — **not verified.** No `prs.json` in either run: `iterate.sh` creates
  PRs on a green outcome only, so `prs.sh` never ran. `chatbot-eval` PR #1 is a slice
  *claim* in `fanout.json` that nothing fetched. Control-repo PR #19 is open.
- **Gates, re-run now** — on `feat/0006-chatbot-eval`: `check-docs.py` **exit 1**
  (`[vendored-contracts] frontend/contracts/openapi.yaml differs`) — the freeze-window
  state recorded as R2 / 20260826, see R6 below; `manifest.py --validate` exit 0;
  `test-hooks.py` exit 0 (12 blocks, 6 allows). On this retro branch, `make check` passes
  whole, including both product repos' lint and typecheck.
- **Stack** — still up (`proxy`, `phoenix`, stores 14 min; `backend`, `frontend` 2 min).
  A line, not a fix.

## Findings

### F1 — `/ship-correct` phase 1 had no shape for an assessment request, and the run was filed as "a step asserts it and already fails" with no failing step in it

- **Evidence:** the user's input was "I am not really sure that there is anything to
  correct; just check the overall correctness." `STATUS.md` § "Corrected, 2026-09-10" files
  it as "shape three of phase 1's triage… already asserted and already failing". No step
  asserts it: `grep -rn env.example changes/0006-chatbot-eval` hits `STATUS.md` and
  `chatbot-eval.md` only, never `smoke.yaml`, and `smoke.yaml` is untouched since `fe91e33`.
  Both `make verify` runs came back `"status": "pass"`, `"failed": 0`,
  `"owners_failing": []` (`runs/20260910T160658Z/verify.json`,
  `runs/20260910T160833Z/attempt-1/verify.json`). So the phase's own rule — "**A step that
  does not fail here has not captured the objection.** Go back and write the one that does"
  — pointed, read literally, at manufacturing a failing assertion for a change that is
  correct; and the routing the phase claims comes "from evidence rather than from a guess"
  (`owners_failing`) named nothing, while `--only chatbot-eval` was passed anyway from a
  slice-brief item.
- **Judgement:** the lane's triage is written as exhaustive over three (now four) shapes and
  all of them presume a defect. The correct action here was to write nothing, and the lane
  had no words for it, so the record reaches for the nearest shape and misstates what
  happened. The routing source in a green run is likewise undocumented: a slice-brief item
  is checked by the slice's own `SLICE-RESULT` self-report and by nothing else.
- **Disposition:** proposed. A fourth shape ("Nothing is wrong"), one sentence bounding the
  must-fail rule to a *stated* defect, one paragraph naming `fanout.json`'s `reason` as the
  routing when `owners_failing` is empty, and a clause on shape three requiring a step that
  actually fails. Prose, deliberately: no mechanism can decide that the user asked for an
  assessment, and the defect is in a triage list that was wrong, which is where the fix has
  to land.

### F2 — `stack/secrets.env` is gitignored only on the change branch, so `git add -A` on main — or on any retro branch — stages the real AWS credentials

- **Evidence:** the `.gitignore` line for it arrived inside `changes/0006-chatbot-eval`
  (`fe91e33`) and exists on that branch alone. On `origin/main`, and therefore on
  `harness/retro-20260903T091831Z` where this retrospective is written, `git check-ignore -v
  stack/secrets.env` → not ignored and `git add -A --dry-run` → `add 'stack/secrets.env'`.
  The user populated that file with real credentials during this lane. The file's own header
  says "stack/secrets.env is gitignored and NEVER committed", which is true on exactly one
  unmerged branch — protection claimed and not provided, §3 question 6.
- **Judgement:** the existing `.env` / `.env.*` rules do not match `secrets.env`. Every
  retrospective is required by its own § 5 to branch from `origin/main`, so the lane that
  is most likely to run a broad `git add` is the one with the least protection. One line.
- **Disposition:** proposed. Probe both directions, on this branch: without the rule
  `git add -A --dry-run` stages `stack/secrets.env`; with it, it does not, and
  `git check-ignore` reports `.gitignore:25`. Nothing else in the tree was mutated.

## Recorded, not proposed

- **R1 — `iterate.sh`'s three report defects reached a third occurrence while their fix sat
  unmerged.** `report.md` for this run still prints `failed for:chatbot-eval`, `PASS,
  butchatbot-eval never reported`, and a third line reading
  `verify: FAIL at unknown` under `verify: PASS` for a run where no stage failed. All
  three are fixed on PR #18 (`scripts/iterate.sh`, F1 / 20260909), unmerged since
  2026-09-03. Not re-proposed: the
  defect is merge latency, which is R3 / 20260827 and a human decision, not a diff.
- **R2 — nothing distinguishes a dirty submodule worktree from a moved pointer, and
  `verify.sh` asserted 91 steps over uncommitted code without recording it.** Three
  submodules carry an uncommitted `.claude/settings.json`; `git status` in the control repo
  shows ` M <submodule>` three times and a reader must run `git submodule status` per repo
  to tell dirt from a pointer. `verify.sh`'s preflight refuses a slice repo on the wrong
  branch because "asserting against code this change did not write is a pass that means
  nothing" — the same argument covers code no commit and no pull request carries, and it is
  not checked. First occurrence, so recorded: the fix is ~10 lines in the preflight loop
  that already notes lock divergence for the same epistemic reason, printing
  `note — <repo> has N uncommitted file(s)` and putting the counts in `verify.json`, which
  `retro-evidence.sh` already prints whole. Proposable on sight next lane.
- **R3 — the run record names no configuration, and the first pass ever obtained against a
  real provider is byte-identical to a credential-free one.** `runs/20260910T160658Z/
  verify.json` and `runs/20260910T160833Z/attempt-1/verify.json` differ in nothing;
  `docs/adr/0015` exists so that a result records what produced it, and one level up the
  result records nothing. The evidence does exist and nothing reads it: both job logs print
  `backend bedrock (eu.anthropic.claude-haiku-4-5-20251001-v1:0) image local-0.0.1` and
  `judge heuristic … prompt v1`. That is also how the friction log's claim of "a real judge
  in both jobs" is wrong — the judge was `heuristic` in all three job runs; only the backend
  was Bedrock. Not proposed because the honest fix is not obvious: `verify.sh` cannot
  resolve the effective `CHAT_MODEL` without reading `chatbot-backend/.env` through
  compose's `env_file:`, which CLAUDE.md and `docs/adr/0016` forbid, and recording a
  configuration that may be false is worse than recording none. The tractable version is to
  surface each job's own summary block — which already prints the configuration it observed
  — into `report.md`.
- **R4 — the harness has no vocabulary for "this item is human-only", so a slice that is
  complete but for an action no agent may take reports `failed` forever.** The slice brief
  (`chatbot-eval.md` § UNBLOCKED item 2, written into `4cb3aa0`) instructs the session to
  edit `.claude/settings.json`, which a session-level guard refuses categorically; the third
  dispatch spent a full session to report that for the third time
  (`attempt-1/fanout.json`: `"status": "failed"`, reason "session guard refuses an agent
  editing settings.json") over a suite passing 91/91. The change cannot reach
  `verified-local` while that item is open. Not proposed: a terminal `blocked` slice status
  is adjacent to `docs/adr/0002`'s outcome vocabulary and belongs to a human decision, and a
  gate that greps slice briefs for `settings.json` cannot tell an instruction from a
  warning. The cheap half — "an item only a human can do goes in `STATUS.md` § Blockers,
  never in a slice file" — is a sentence in `/ship-correct` phase 3 and is offered here
  rather than smuggled in beside F1.
- **R5 — fifth occurrence: nothing commits the run's record.** `iterate.sh` writes the
  outcome between the `iterate:` markers in `STATUS.md` and a human or the lane session
  commits it by hand, as in the four lanes before this one (`1ca41e3` did it again). Left
  recorded because the two lanes were already taught which branch to commit on (F2 /
  20260902) and the remaining gap is who runs `git commit`, which is the boundary
  `docs/adr/0009` puts at a human.
- **R6 — `check-docs.py [vendored-contracts]` still hard-fails through the freeze window,
  for a repo with nothing to do.** On `feat/0006-chatbot-eval` the only problem is
  `frontend/contracts/openapi.yaml differs`: `frontend` is on-lock, is not a slice, and
  nothing will vendor `GET /v1/version` into it until `/realign` runs. So `make check`
  cannot pass on the change branch for the life of the change — second occurrence of
  R2 / 20260826, half-fixed on PR #18 (which now warns instead of failing for *off-lock*
  repos). The fix is the same shape, guarded by a git question: if `contracts/` differs from
  `origin/main`, a stale vendored copy in a non-slice repo is expected and is a warning
  naming the change; on `main` the condition is false and full strictness returns. Not
  proposed only because #18 already rewrote this exact function and is unreviewed, and
  stacking a subtler exemption onto it raises the chance a hidden hole merges with it.
- **R7 — change 0006 carries 1,472 lines of harness change, and the hard rule that forbids
  that does not distinguish a change's own mechanism from a harness fix.** `git diff
  --stat origin/main HEAD -- scripts/ .claude/ Makefile docs/ CLAUDE.md concept.md` on the
  change branch: 24 files, including `scripts/check-docs.py` (+308), `scripts/verify.sh`
  (+126) and `scripts/manifest.py` (+139). Most of it is decided by `docs/adr/0014`, `0015`
  and `0016` and is the change's mechanism, not a fix slipped in — but CLAUDE.md says only
  "Harness fixes arrive as a PR from `harness-retro`… Never slip one into a change", which a
  reader either takes as violated or as inapplicable. The price is concrete: PR #18 and PR
  #19 both edit `check-docs.py`, `iterate.sh` and `retro-evidence.sh`, so the harness fixes
  from three retrospectives are behind a merge conflict with the change they were found in.

## Rejected

- **Declaring `CHAT_MODEL` in `stack/dev.env` so the run's configuration is committed.**
  `docs/adr/0006` accepted layer 3 on purpose — a submodule's own `.env` selecting `bedrock`
  for a developer who has credentials — and `smoke.yaml`'s `version-names-the-effective-
  chat-model` asserts the enum rather than the machine for exactly that reason. Declaring it
  here would remove a cost an ADR accepted. Argued in R3 instead.
- **A gate over slice briefs that mentions `.claude/settings.json`.** The defect is real and has
  happened three times, but the check would have to scope itself to in-flight changes (no in-flight
  change exists on a main-based branch, so it could not be exercised where it must be
  written) and a regex cannot tell "edit this" from "do not edit this". R4.
- **Promoting the `.env.example` requirement into a smoke step.** Nothing at the HTTP seam
  can see a file inside a repo; `smoke/baseline.yaml` describes the seam, not one repo's
  internals.
- **A stray-scratchpad guard.** A session wrote and removed a sibling scratchpad directory
  from a one-character error in its own session UUID (second occurrence of that shape). The
  path comes from the environment, not from anything in this repo, so there is nothing here
  to fix.

## Not verified

- **Any pull request's state.** No `prs.json` was written in either run, so PR #1 in
  `chatbot-eval` and the CI columns in `STATUS.md` are claims. `./scripts/prs.sh --list`
  against a green run is what would settle them.
- **Anything remote.** No AWS read was made from here: `deploy.infra` is `false` and there
  is no environment to assert. `make eval JUDGE=bedrock` is reported in `STATUS.md` as a
  person's oracle and I did not re-run it.
- **That the `stack/secrets.env` layering is effective.** The lane proved it by hand with a
  marker file and then deleted the marker; `check-docs.py [provider-credentials]` checks the
  wiring is *declared*, and nothing checks it arrives. Reproducing it needs credentials and
  Docker, and a `jobs:`-shaped one-shot that prints whether a variable arrived would be the
  standing assertion. Named here as the slice it would take.

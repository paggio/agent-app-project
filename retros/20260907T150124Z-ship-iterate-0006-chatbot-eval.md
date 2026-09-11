---
lane: ship-iterate
change: 0006-chatbot-eval
run: changes/0006-chatbot-eval/runs/20260907T143316Z
date: 2026-09-07
verdict: coherent-with-warnings
findings: 3 proposed, 9 recorded, 4 rejected
pr: https://github.com/Paggio/agent-app-project/pull/18
---

## State audit

- **Control repo** — `feat/0006-chatbot-eval` at `a42841f`, pushed. Tree **not clean**:
  `changes/0006-chatbot-eval/STATUS.md` plus the `chatbot-backend`/`chatbot-eval` pointers
  are modified and uncommitted — the green run's own record. The committed `STATUS.md`
  still says `failed — 20260907T140334Z`, so PR #19 records the failed run as the last
  outcome. See R4.
- **contracts/** — committed alone in `c0ff827` (0 files changed against HEAD); `freeze_sha`
  in `change.yaml` only, `[freeze-sha-home]` green.
- **Submodules** — `chatbot-backend` `14dace1` and `chatbot-eval` `bb8ac3e` on
  `feat/0006-chatbot-eval`, which is what this lane should leave; both differ from
  `repos.lock`, which is pre-amendment and correct until `/realign`. `frontend` `d9b76a8`
  and `infra` `6eebe0a` on `main`, matching the lock. No uncommitted files in any of the four.
- **Contract against what is served** — re-checked in this lane: `harvest.log` in
  attempt-1, `contract_harvest: pass`, with the same five declared-never-observed 422s the
  realign retro raised (F3, 20260902). Not a new drift.
- **Assertions** — 91 passed, 0 failed, 28 of them from `changes/0006-chatbot-eval/smoke.yaml`
  across 89 steps. `verified-local` over 28 own-suite assertions is not a thin count, and the
  five new criteria each passed on the first green attempt.
- **The cloud** — `deploy.infra: false`, `infra.remote_asserted: false`, `environment: null`.
  Nothing reached a remote environment, and `report.md`, `STATUS.md` and `verify.json` all
  say `verified-local` rather than shipped.
- **Pull requests** — facts, not claims: `prs.json` records three `existing` URLs
  (`agent-app-project#19`, `chatbot-backend#9`, `chatbot-eval#1`) and `gh` confirms #19 open
  with `docs` and `manifests` green.
- **Gates re-run now** — `check-docs.py` **exit 1** (`[vendored-contracts]`, F1);
  `manifest.py --validate` exit 0; `test-hooks.py` exit 0 over 12 blocks and 6 allows; each
  product repo's `lint`+`typecheck` pass (run individually, since `check-docs` aborts
  `make check` before the loop).
- **Stack** — all nine services up and healthy after the lane, which is retro 0004 R8's
  standing note rather than something new.

## Findings

### F1 — `check-docs.py [vendored-contracts]` fails on every branch a retrospective can stand on, and three of them could not publish a record

- **Evidence:** on `feat/0006-chatbot-eval`, `frontend/contracts/openapi.yaml` differs from
  the frozen `contracts/openapi.yaml` → exit 1. With `contracts/` set to
  `origin/main`'s copy (what a retro branch has), `chatbot-backend` and `chatbot-eval` differ
  instead → exit 1. Nothing else in `make check` fails: all four product gates pass. Recorded
  as R2 in `retros/20260827T153500Z-ship-iterate-0004…` ("the retrospective still cannot
  publish, and that is now the most expensive defect here") and never proposed; the
  `/ship`-`0006` retro hit it again and opened nothing. CI never sees it — `ci.yml` checks out
  with `submodules: false`, so PR #19 is green on the same tree.
- **Judgement:** the check compares one working tree against four repos that sit on both
  sides of one freeze, so during the freeze-to-merge window there is no branch on which it
  can pass. `verify.sh:334` already compares the same two files per **slice**, on every run,
  and routes a difference to the repo answerable for it — a stronger check with an owner.
- **Disposition:** proposed. A submodule that is off its `repos.lock` SHA is mid-change and
  is now reported as a warning naming the two SHAs; a submodule **at** its locked SHA is
  compared exactly as before. Probed both ways on the real tree: main-based contracts →
  `21 checks passed`; the same tree with `repos.lock` pointed at the slice SHAs → exit 1 for
  both repos.

### F2 — a captured null interpolated as the four characters `None`, and the unsatisfiable assertion was charged to `chatbot-eval` twice

- **Evidence:** `runs/20260907T140334Z/attempt-1/failure-chatbot-eval.md` —
  `expected: {"body_matches": "\"chat_model_id\":\\s*\"None\""}` against a body carrying
  `"chat_model_id":null`. `the-experiment-records-the-exact-model-that-answered` failed in
  both attempts, burning the whole budget and two repair sessions on a step no product repo
  could fix. `smoke.py:291` was `return str(scope[key])`; `extract()` also returns `None` for
  an absent header, cookie or JSON path, so the same silent stringification covered three
  ways of having no value. `changes/0006-chatbot-eval/BRIEF.md` §"A gap in the oracle"
  records the behaviour.
- **Judgement:** exactly the class `docs/adr/0003` decides — an assertion the harness cannot
  satisfy is a refusal (exit 2, `fault: harness`), not a failure attributed to a slice. The
  file already reasons this way for the never-bound capture (`CascadeSkip`) and for a missing
  fixture, and `verify.sh:518` already routes exit 2 to "fix it here, not in a product repo".
- **Disposition:** proposed. `NullCapture` raised from `interpolate`, caught in `run_step`,
  `die()` naming the step, the capture and the two ways to write the criterion instead.
  Probed against a local server returning `{"chat_model_id": null}`: before → `FAIL`,
  `owners_failing: ["chatbot-eval"]`, exit 1; after → exit 2 with the refusal, and a suite
  capturing a non-null value still passes.

### F3 — `scripts/dev-env.sh` fills in nothing under zsh and returns 0, so every hand probe in two lanes ran against an empty environment

- **Evidence:** `zsh -c '. ./scripts/dev-env.sh; echo $SIGNUP_CODE'` → empty,
  `DEV_ENV_DEFAULTED` empty, `rc=0`; the same line under bash fills 24 names.
  `${BASH_SOURCE[0]}` is empty in zsh, so the root resolved to the parent of the cwd and
  layer 2 was silently absent. Second occurrence: found in the `/ship`-`0006` retro (F1) and
  paid again here as a `bash -c` wrapper per probe. The user's shell is zsh, and `CLAUDE.md`
  tells everyone these variables are never exported by hand.
- **Judgement:** a silent wrong answer indistinguishable from a clean environment, in the
  one script whose whole purpose is that nobody has to remember the variables. Two lines of
  cause; the fix is smaller than the workaround.
- **Disposition:** proposed. `${BASH_SOURCE[0]:-$0}` for the root, `eval "[ -z \"\${$_key+x}\" ]"`
  in place of bash-only indirect expansion, and a refusal (`return 2`) when the default
  `stack/dev.env` is missing. Verified byte-identical `name=value` output under bash and zsh,
  the `+x` property preserved (an explicitly empty `SIGNUP_CODE` stays empty and unrecorded),
  layer 1 still winning, layer 3's allowlist unchanged, and the refusal firing in both shells
  when the root is wrong.

## Recorded, not proposed

- **R1 — the two new gates ignore the `export ` prefix `dev-env.sh` honours, so a shadowing declaration is invisible to both.**
  Probed:
  `export BACKEND_IMAGE_TAG=local-9.9.9` prepended to `stack/dev.env` → both checks silent,
  loader resolves `local-9.9.9`, every other reader and every human sees line 170's
  `local-0.0.1`. Same with `export SIGNUP_CODE=letmein-wrong`. `dev-env.sh:81` strips the
  prefix and its header documents it as part of the grammar; `_env_keys` in `check-docs.py`
  strips it too, so the file already contains the correct reader. This is the *other half* of
  the divergence this lane fixed (first-wins vs last-wins) and it is three lines — held back
  only to keep this pull request at three findings. Proposable now on the evidence above.
- **R2 — the submodule-write hook blocks a command that only *mentions* a submodule path, third occurrence, and its message never names the workaround.**
  A python patch script
  with `chatbot-eval/…` in a comment or a string on the same line as `patch`/`cp`/`rm` trips
  `WRITERS ∧ SUBPATH` within one segment. The hook's own comment says to widen it only for a
  real miss, so the matcher should stay; what is missing is one line in the block message
  telling the agent to write the script to a file outside the submodule and run that — the
  detour all three occurrences discovered by hand.
- **R3 — `report.md` says "all slices reported OK" for an `--only` run in which one slice was never dispatched.**
  `iterate.sh:456` writes that string unconditionally; the green run's
  `fanout.json` contains one repo. The restriction *is* recorded twice (`report.md`
  "first dispatch restricted to (`--only`): chatbot-eval", `STATUS.md` "first dispatch:
  chatbot-eval (`--only`)"), so a reader who reads the artifact cannot conclude the backend
  was re-dispatched — which is why this is a record, not a proposal. The `--only` decision
  itself was sound: both failures were control-repo defects and the backend's brief says no
  change is required.
- **R4 — no lane says to commit the run's own record, so a green outcome lives only in the working tree.**
  `STATUS.md`'s `verified-local` block and two submodule pointer bumps are
  uncommitted; the committed record says `failed`. `/realign` names exactly what to commit
  and onto what (`realign.md` §4, from retro 20260902 F2); `/ship-iterate` §4 says only
  "read `report.md` and route on the outcome", and `/ship` says nothing after the freeze.
  Third appearance of R11 (20260827). A one-line addition to each lane would close it; it is
  a sentence rather than a mechanism, which is why it waits behind F1–F3.
- **R5 — ADR 0015 versions the *reported* build identity, not the image.** The backend
  container in the joined stack is `chatbot-backend:dev` while `/v1/version` reports
  `image_tag: local-0.0.1`; the docker tag is set in the product repo's compose file, which
  this repo may not edit. Phoenix can tell two builds apart, `docker images` cannot. Not in
  the ADR's accepted-costs list, and worth a line there or a slice in the next backend change.
  `stack/compose.yml:35` still says "locally this is `dev`", which is now false.
- **R6 — the run needed `CHAT_MODEL=echo` exported by hand, fifth occurrence of the expired-credential misroute.**
  `STATUS.md` records it: without it the stack resolves
  `bedrock` from `chatbot-backend/.env`, 44 `ExpiredTokenException`s were charged to
  `chatbot-eval`, which cannot fix a credential in another repo's gitignored file. The
  obvious fix is forbidden by design — `[env-layers]` refuses a name declared in both
  `stack/dev.env` and `chatbot-backend/.env`, and `docs/adr/0006` makes layer 3 deliberately
  authoritative for `CHAT_MODEL`. So the fix is attribution, not configuration: a preflight
  that reads a credential-expiry failure as `fault: harness` rather than as a slice fault.
  Note also that `CLAUDE.md`'s "Never export one by hand" reads as absolute while
  `dev-env.sh`'s own header advertises `CHAT_MODEL=echo ./scripts/iterate.sh …` as layer 1.
- **R7 — `contracts/README.md`'s "`git_sha` is null when nothing supplied it" has no assertion at the seam.**
  The lane added `GIT_SHA: ${BACKEND_GIT_SHA-}` to `stack/compose.yml`, the
  backend reported `git_sha: ""`, and nothing failed; it was caught by eye in a failure body
  and removed. The green run serves `git_sha: null`, so the state is correct today. Adding the
  step is a criterion, and a criterion is the human's to add — named here for whoever runs
  `/realign` and decides what gets promoted.
- **R8 — the `[image-tags]` bump half cannot fire for a newly introduced tag, and a second in-flight change rides on the first one's bump.**
  `was is not None and was == now` means
  `EVAL_IMAGE_TAG`, absent from `origin/main`, is ungated until 0006 merges; and once
  `BACKEND_IMAGE_TAG` differs from `main`, any *further* in-flight change with a backend
  slice passes without bumping. Both are structural to comparing against one baseline ref
  and neither has happened. Speculative today; the second one becomes real the first time two
  changes are in flight at once.
- **R9 — the backend slice was dispatched twice to do nothing, at a full agent session each.**
  Correct per `/ship-iterate` §4 ("the slice briefs changed and each agent has to read the new
  one") and it reported `ok` both times without touching the repo. Recorded as a cost, not a
  defect: the alternative — trusting a human's claim that a repo needs no work — is what
  `--verify-only` was rejected for in retro 20260827 R4.

## Rejected

- **Put the image-tag rule in `CLAUDE.md`, as the user suggested.** `CLAUDE.md` is at exactly
  60 lines and `[claude-md-size]` fails above it, so the line cannot be added without
  removing another; ADR 0015 §1 and §2 argue the rule belongs in a gate, and
  `docs/init/README.md` says a must-not-happen is a mechanism rather than prose. The lane's
  refusal was right, and mechanically forced.
- **`CHECK_DOCS_BASELINE_REF` as a test-only seam in a gate.** The right trade. The bump half
  cannot fire against a real `origin/main` until the variables exist there, and an unprobed
  gate is worse than none (`docs/init/README.md`). Grepped: nothing in the harness sets it, it
  defaults to `origin/main`, and the alternative was shipping half a gate nobody had seen fire.
- **Extending F1's exemption to an at-lock repo that carries `origin/main`'s contract rather than the freeze.**
  It would make `make check` pass during `/ship`'s freeze window too, and it would
  arm a failure on `main` the moment 0006 merges — re-blocking the harness for the same reason
  F1 exists. The residual is real and stated: on a change branch, an un-sliced repo's copy is
  behind the freeze and `[vendored-contracts]` still fails until `/realign` publishes.
- **Softening the `--only` accounting or the smoke suite's counts.** Nothing was softened and
  nothing needed to be: the seam assertion `the-backend-image-tag-is-a-version` caught a
  divergence the lane's own new gate had passed, which is the counted-evidence doctrine
  working against the person who added the gate.

## Not verified

- Anything remote. `deploy.infra: false`, no credentials used, no AWS read — `verified-local`
  is the honest ceiling and every artifact says so.
- `make check` as one invocation on the retro branch with the submodules present: this
  retrospective was written from a `git worktree`, where the submodule directories are empty
  and `[vendored-contracts]` self-skips. The three fixes were probed in the real tree, and
  each product repo's `lint`+`typecheck` was run there directly — all pass.
- The two one-shot jobs' internals. `jobs: {declared: 2, ran: 2, passed: 2}` is taken from
  `verify.json`; the eval's own numbers were not re-derived.
- `chatbot-backend#9` and `chatbot-eval#1` beyond the URLs and states `prs.json` and `gh`
  report; their CI was not read.

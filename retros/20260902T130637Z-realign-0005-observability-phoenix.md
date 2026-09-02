---
lane: realign
change: 0005-observability-phoenix
run: none
date: 2026-09-02
verdict: coherent-with-warnings
findings: 3 proposed, 6 recorded, 3 rejected
pr: https://github.com/Paggio/agent-app-project/pull/16
---

A realign leaves no run directory, so almost everything here was re-derived rather than
read: the harvest was re-run against the stack the lane left up, the four ids it probed were
probed again, and the baseline was run three times — twice on the lane's own branch and once
on `origin/main`.

The lane's judgement call was right and better evidenced than it claimed. The five `422`s
are not promisable: `GET/DELETE /v1/threads/{id}`, `GET /v1/documents/{id}` and
`GET /v1/documents/{id}/content` all answer **404** to a malformed id, authenticated,
re-verified here. What is wrong is that the tool called them "Additive — safe to promise",
and that 0003's `STATUS.md` turned that reading into a standing instruction — "**promote it
at `/realign`**" — which two realigns have now had to decline by hand.

The one thing the lane did not find: `make smoke` is **red on the tree it left**, and was
green when it ran. `smoke: 46 passed, 1 failed` — `register-a-trace-owner`, 409
`AUTH_EMAIL_TAKEN`. The cause is in the harness, not in the promotion.

## State audit

- **Control repo** — the lane left `chore/realign-0005` at `db71c33`, clean tree including
  submodule pointers. `main` is exactly `origin/main` (`5482a3e`): the two commits it
  admits to having put there were moved off and nothing was pushed. The split is right —
  `8d2070f` is `chatbot-backend` + `repos.lock` and nothing else, `db71c33` is
  `smoke/baseline.yaml` and nothing else.
- **`contracts/` committed alone** — untouched by this lane (`git diff origin/main...` shows
  three files, none of them under `contracts/`). The last commit touching it, `dfbb48f`, is
  `contracts/README.md` alone and is an ancestor of `main`; `changes/0005-observability-phoenix/change.yaml:8`
  carries it as `freeze_sha`. It also still has a second home — R2 below, fifth occurrence.
- **Submodules** — `chatbot-backend c76af44`, `frontend d9b76a8`, `infra 6eebe0a`, all on
  `main`, all clean. `c76af44` is the merge commit of chatbot-backend#8, `MERGED` at
  12:05:53Z, i.e. the bump followed the merge as the ordering rule requires. They match
  `repos.lock` **on the lane's branch**; against `origin/main` they are ahead, because the
  lock bump is in the unmerged #15. That is what an open realign looks like, not drift.
- **Contract against what is served** — re-checked in this lane and **re-checked again here**,
  against the running stack: five paths where the served spec declares a `422` the contract
  does not, nothing breaking, exit 0. Probed four of them with a session cookie and a
  malformed id: `404` on all four, which is what `contracts/README.md` § "Chats, ownership
  and titles" promises. The lane's decision not to promote is confirmed, not just believed.
- **Assertions** — 61 steps in the promoted baseline, 15 of them from 0005's own suite,
  0 failed **when run with a per-invocation run id** (verified here, on a warm stack, on the
  lane's branch). Run the way `make smoke` actually runs it: 46 passed, 1 failed, 14 not
  reached. F1. Not thin: the promoted block asserts the frozen `X-Trace-Id`, one HTTP span
  per request, the account and chat on the root span, and no credential anywhere in the
  project.
- **The cloud** — nothing reached a remote environment, and nothing in this lane claims one.
  `infra` did not move; the change that merged declares `deploy.infra: false` and its
  `verify.json` records `environment: null`, `remote_asserted: false`. `verified-local` is
  the whole of it.
- **Pull requests** — facts, not claims: agent-app-project#15 `OPEN`, `MERGEABLE`, two
  commits; chatbot-backend#8 `MERGED`; #13 and #14 merged. #15 was opened by hand — nothing
  in the harness opens a realign's pull request, and until this retro nothing told the lane
  to open one. F2.
- **Gates, re-run now against this branch** — `check-docs.py` exit 0, 16 checks, one known
  permanent warning; `test-hooks.py` exit 0 in both directions; `manifest.py
  changes/0005-observability-phoenix --validate` exit 0; `make check` exit 0 including both
  product repos' lint, format and typecheck, with the submodules on `main`.
- **The stack** — up, and left up by the lane. Fourth occurrence of R8/20260826; it is what
  made re-deriving the harvest and the 404 probes possible here, so it is noted rather than
  complained about.

## Findings

### F1 — `make smoke` passes a constant where every other caller passes a nonce, so the baseline is not re-runnable

- **Evidence:** `Makefile:98` was `SMOKE_RUN_ID=make`. `scripts/verify.sh:74` computes it
  from the run timestamp, and `scripts/smoke.py:131` calls it "the run nonce". The baseline
  namespaces every identity with it — `smoke-baseline-${SMOKE_RUN_ID}@auth.test` and four
  siblings. Observed on the lane's branch against the stack it left up:
  `smoke: 46 passed, 1 failed, 14 not reached`, `register-a-trace-owner`, `expected status
  201, got 409`, `AUTH_EMAIL_TAKEN`. The same suite, same stack, same second, with a unique
  run id: `smoke: 61 passed, 0 failed`. The fingerprint is on `main` too: three baseline
  steps carry `status: [201, 409]` with the comment "201 cold, 409 when a previous run left
  the volume behind" — assertions softened to survive a nonce that was not one.
- **Judgement:** the baseline is the cross-repo regression suite; a suite that only passes
  against a stack nobody has smoked yet is a suite that will be read as broken and then
  ignored. The lane ran `make smoke` once, cold, and was green; anyone running it a second
  time gets a red seam and a step name that points at a promotion which is not the cause.
- **Disposition:** proposed. `SMOKE_RUN_ID=make-$$$$` — the shell's pid, one per invocation.
  Probed both directions: red without it on the tree that has the promoted step, green with
  it, and green twice in a row on `origin/main` (45/45, 45/45) where the same constant is
  masked by those three `[201, 409]` steps. No assertion was touched.
  What it would have caught: this lane's own `make smoke`, and the three softenings.

### F2 — both lanes tell you to commit into the control repo and neither says onto what

- **Evidence:** `.claude/commands/realign.md` § 4 gave bare `git commit -m "chore: bump
  submodules for <change>"`, and § 5 ended "Then `make check` and commit". The lane followed
  it, put both commits on `main`, noticed `git log` showed `Merge pull request #11 from
  Paggio/chore/realign-0004`, and moved them onto a branch by hand. Nothing had been pushed.
  The same silence in `.claude/commands/ship.md` § 1–2 has a mechanical cost: `scripts/prs.sh`
  adds this repo to the pull requests it opens **only when it is already on
  `feat/<change>`** — the fix merged in #14 — and no command anywhere says to create that
  branch. A mechanism that fires only when the agent guesses right is the shape this repo
  keeps finding in its own guards.
- **Judgement:** a first occurrence of the commit-on-main defect, recovered by the lane at no
  cost but its own attention, and a second-order defect that is already live: #14's control-
  repo PR path is inert unless the lane happens to branch. Prose is the proportionate answer
  to the first — the rule has not been violated repeatedly, and a hook that refuses `git
  commit` on `main` is the escalation if it is.
- **Disposition:** proposed, as prose in the two places the lane reads at the moment it acts:
  § 4 opens with `git switch -c chore/realign-<change>`, § 5 ends with push and
  `gh pr create` and "do not merge it", and `ship.md` § 1 says to scaffold on
  `feat/<change>` and says why `prs.sh` cares.
  What it would have caught: two commits on `main` and the manual recovery; and the next
  `/ship` would get a control-repo pull request in `prs.json` without anyone guessing.

### F3 — the harvest called five statuses "safe to promise" that it has never seen the service return

- **Evidence:** `scripts/harvest-contract.py:240` classified any status in the served spec
  and not in the contract as `ADDITIVE`, printed under "Additive — safe to promise" as
  "returns undeclared status 422". The tool loads two specs and never calls the service, so
  "returns" is a claim it cannot support. All five are FastAPI's auto-declared `422` on an
  operation with a validated path parameter; `thread_id` and `document_id` are plain
  strings, so nothing can fail validation. Probed here with a session and a malformed id:
  `GET /v1/threads/{id}` 404, `DELETE /v1/threads/{id}` 404, `GET /v1/documents/{id}` 404,
  `GET /v1/documents/{id}/content` 404 — exactly the "four situations collapse to one
  indistinguishable answer" rule in `contracts/README.md`. The five have been reported the
  same way in every harvest since 0004, and
  `changes/0003-chats-rename-delete-history/STATUS.md:79-87` reads the classification back
  as an instruction: "promote it at `/realign` rather than re-freezing here". Two realigns
  have declined it by hand; the third would be entitled to follow the instruction.
- **Judgement:** `--write` merges the served spec wholesale, and `/realign` § 2 accepts that
  cost explicitly — "review the draft; that is the step that matters". The review is the
  compensating control, and the label is what the reviewer reads. A label that asserts
  behaviour the tool never observed is not a wording preference; it is the one input to the
  decision the ADR reserves for a human.
- **Disposition:** proposed. Status-only findings get their own kind and their own section —
  "Declared by the implementation, never observed" — reading "the served spec declares status
  422; the contract does not, and nothing here has seen it returned", with a footer saying
  to promise it only after seeing the service return it and only if `contracts/README.md`
  does not already promise something else. `--diff` exit codes are untouched (still 1 only
  on breaking), `--write` is untouched, and `/realign` § 2 gains the matching bullet so the
  command still describes what the tool prints.
  What it would have caught: 0003's standing instruction would never have been written, and
  the four lanes since would not each have had to re-derive the same 404.

## Recorded, not proposed

- **R1 — `CHAT_MODEL=echo` by hand, fourth lane running, and it has already cost an attempt.**
  Re-verified here: `. scripts/dev-env.sh` resolves `CHAT_MODEL=bedrock` from
  `chatbot-backend/.env` (layer 3, `SUBMODULE_ENV_DEFAULTED=CHAT_MODEL`), and those
  credentials are expired. R11/20260901 and R4/20260902 recorded it; 20260902 said the next
  occurrence should propose something. This is that occurrence and I am still not proposing
  a fix, for a reason that is not "not yet": the cheap fixes are legibility only. Printing
  the model and its layer at `make up` would shorten the diagnosis and remove nothing, and
  `stack/dev.env` cannot declare `CHAT_MODEL` at all — `check-docs.py [env-layers]` fails on
  exactly that overlap, which is docs/adr/0006 working. The thing that would actually remove
  the cost was named by 0003 and never decided: `docs/adr/0003` has `fault: harness` and
  `fault: slice` and nothing for `fault: environment`, so an expired upstream credential is
  charged to a slice and gets a repair session that cannot possibly succeed —
  `changes/0003-chats-rename-delete-history/STATUS.md` § "Two findings" says it spent one.
  That is an ADR-level decision, and this is the second retrospective asking for it.
- **R2 — the freeze SHA still has a second home.** `changes/0005-observability-phoenix/STATUS.md:5`
  carries all 40 characters; `CLAUDE.md` says `change.yaml` and "nowhere else";
  `check_freeze_sha_home` scans for one filename and not that one. Fifth occurrence
  (R5/20260826 → R7/20260901 → 20260902). They still agree, so still hypothetical, and
  20260826's reason stands: the rule and the scaffold contradict each other and a reviewer
  should decide which is right rather than let a check settle it. It has now survived five
  retrospectives, which is itself the argument for deciding it.
- **R3 — a realign produces no run artifact, so its evidence lives in a pull request body.**
  `/ship` writes `runs/<ts>/harvest.log`, `smoke.json`, `verify.json`. `/realign` re-runs the
  same two oracles and writes nothing; `retro-evidence.sh` § 4 says so out loud, pointing at
  the previous lane's harvest and warning that it is "from that run, not from now". Here it
  was recoverable because the stack was still up and I could re-run both. Not proposed: the
  only place a realign's evidence could go is a directory nothing reads or a commit message,
  and #15's body does carry the harvest result and the baseline count. Worth proposing the
  day a realign's answer cannot be re-derived.
- **R4 — promotion is copy-paste, and the collision it invites is real.** The lane renamed
  0005's `thread_id`/`account_id` captures to `trace_thread_id`/`trace_account_id` on the way
  in, correctly: `thread_id` is already captured 500 lines above in the baseline, and
  `smoke.py` runs the baseline and a change suite in one process with one variable table, so
  a verbatim paste would have silently rebound it. `--lint` validates each step's shape and
  never looks across steps. Two captures still overlap between the promoted baseline and
  0005's suite (`chat_trace`, `dev_trace`), harmlessly — both are re-captured before use.
  Not proposed: no collision has ever actually broken a run, and a lint that forbids reuse
  would fire on those two correct cases.
- **R5 — nothing checks that a promoted step kept its tags, or that the baseline's exit state
  is deliberate.** All 15 promoted steps kept `[local]` (verified by comparing both files
  step by step); a dropped tag would have opted them into a remote pass. Separately, the lane
  added `logout-the-dev-account` to make the jar's exit state a decision rather than an
  accident — 0004's suite opens with two anonymous refusals that were true only by luck of
  what the baseline happened to end with. Both are properties of a sequence, not of a step,
  and `--lint` cannot see either. Not proposed: neither has ever gone wrong, and the tag
  comparison is three lines a retrospective can run.
- **R6 — `/realign` still does not say what to do when no change is named.** The command says
  "If a change was named, it is the one whose durable smoke steps get promoted in step 5" and
  stops. The lane inferred `0005-observability-phoenix` from it being the change that had
  just merged, said so, and was right. Not proposed: the inference is obvious with one
  merged change and the honest rule for two — promote from each, oldest first — is a sentence
  nobody has needed yet. First occurrence.

## Rejected

- **A hook refusing `git commit` while the repo is on `main`.** It would have mechanised F2
  instead of describing it, and `docs/init/README.md` prefers exactly that. Rejected for
  now on proportion: one occurrence, self-corrected, nothing pushed, and the guard needs the
  target repo's current branch — which makes `test-hooks.py`'s static case list
  branch-dependent unless the prober builds throwaway repos. If a second lane commits onto
  `main`, this is the answer and the probe is worth building.
- **A `--lint` rule that a promoted registration step must accept `409`.** It would encode
  the workaround instead of removing the cause, and the cause is F1's one-line constant.
  With a real nonce the three existing `[201, 409]` steps could tighten back to `201`; that
  is a change to assertions and belongs to a human, not here.
- **Recording the resolved `CHAT_MODEL` and its layer in `verify.json` or at `make up`.**
  R1. It is five lines and it would help, but it removes nothing, and proposing it would let
  the ADR-level question — a `fault: environment` class — sit for a fourth lane behind a
  fix that looks like an answer.

## Not verified

- Anything in a remote environment. There is none: `infra` did not move, no environment is
  named, `remote_asserted` is false everywhere it appears.
- The out-of-band oracles from 0005 (`make phoenix-durability`, the backend's own tests, the
  log lines carrying the response's trace id). They are prose in `STATUS.md` and were not
  re-run here. Third retrospective saying so; R3/20260902.
- The fifth `422` path, `DELETE /v1/documents/{document_id}`. Four of the five were probed
  with a malformed id; the fifth was left alone rather than delete something on a live stack.
  Its operation shape is identical to the four.

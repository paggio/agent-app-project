---
lane: ship-correct
change: 0006-chatbot-eval
run: changes/0006-chatbot-eval/runs/20260909T161954Z
date: 2026-09-09
verdict: coherent-with-warnings
findings: 4 proposed, 8 recorded, 4 rejected
pr: https://github.com/Paggio/agent-app-project/pull/18
---

Two dispatches, `20260909T161037Z` and `20260909T161954Z`, same block both times. The suite
passed both times — 91 assertions, 28 from the change's own suite, 2 of 2 declared jobs — and
the loop reported `failed` because the dispatched slice reported `failed`. That is
`docs/adr/0003` declining to call a passing suite over an unfinished slice verified, and it
is the right call.

## State audit

- **Control repo** — clean tree on `feat/0006-chatbot-eval` at `91aeeaa`; 0 files differ
  from `contracts/` at HEAD. The freeze is `c0ff827`, which touched `contracts/README.md`
  and `contracts/openapi.yaml` and nothing else, and its SHA lives only in
  `change.yaml: freeze_sha` — `[freeze-sha-home]` passes on that branch.
- **Submodules** — `chatbot-backend` `14dace1` and `chatbot-eval` `21a8590` on
  `feat/0006-chatbot-eval`, both off `repos.lock` (`c76af44`, `f408b36`); `frontend`
  `d9b76a8` and `infra` `6eebe0a` on `main` and matching the lock. Correct for this lane:
  the lock bumps at `/realign`. No uncommitted file in any of the four.
- **Contract against what is served** — re-checked in this lane, before smoke, in both runs:
  `runs/20260909T161954Z/attempt-1/harvest.log`, stage `contract_harvest: pass`. It reports
  the same five statuses declared-but-never-observed as the last two runs (see R7).
- **Assertions** — 91 passed, 0 failed, 28 from `changes/0006-chatbot-eval/smoke.yaml`
  across 89 steps. Not thin, and the outcome was not `verified`, so nothing claims more
  than it holds.
- **The cloud** — `infra.remote_asserted: false`, `environment: null`,
  `deploy.infra: false`. Nothing reached a remote environment, and the run does not say it
  did: the outcome is `failed`, not `verified`.
- **Pull requests** — no `prs.json` in either run, because `iterate.sh` opens PRs on a green
  outcome only. `fanout.json` claimed `chatbot-eval` PR #1; checked with `gh` and it is a
  fact — OPEN on `feat/0006-chatbot-eval`. Also open and verified: `chatbot-backend` #9,
  this repo #19.
- **Gates, re-run now** — on `feat/0006-chatbot-eval`: `manifest.py --validate` exit 0,
  `test-hooks.py` exit 0, `check-docs.py` **exit 1** on
  `[vendored-contracts] frontend/contracts/openapi.yaml differs`, which is retro
  20260907's F1 and is fixed on this branch. On this branch (`origin/main`-based),
  `check-docs.py` exit 0 with two warnings and `make check` exit 0.
- **The joined stack** — up, nine services healthy, two minutes old at evidence time. Normal
  after `--keep-up`; `./scripts/stack.sh down` when finished.

## Findings

### F1 — `report.md` printed three verify lines for one attempt, two of them concatenated, and its contract-gap block records nothing at all

- **Evidence:** identical in both runs' `report.md`:
  `**Attempt 1 — dispatch:** failed for:chatbot-eval`,
  `**Attempt 1 — verify:** PASS, butchatbot-eval never reported a completed slice`, then
  `**Attempt 1 — verify:** FAIL at \`unknown\``. `iterate.sh` builds `FANOUT_FAILED` from
  `' '.join(...)` with no leading space, and the two `record` calls assume one. The third
  line is the fall-through: `verify.sh` returned 0, so `failed_stage` is `null`, so `$STAGE`
  is `unknown` — a stage that did not fail, printed under a line saying PASS. And "never
  reported a completed slice" is false: the slice reported, with a precise reason and a `pr`
  field, and the reason was reachable only from the log.
  Separately, and pre-existing: the contract-gap hard stop pipes its per-repo detail into
  `… | while IFS= read -r l; do record "$l"; done`. `record` appends to `SUMMARY` and the
  last stage of a bash pipeline is a subshell, so every one of those lines is discarded.
  Proved directly: `bash -c 'S=""; record(){ S="$S$1
  "; }; printf "a\nb\n" | while IFS= read -r l; do record "$l"; done; echo "[$S]"'` prints
  `[]`. A frozen-contract hard stop names neither the repo nor the gap in `report.md`.
- **Judgement:** clears the bar. Second occurrence of the class — retro 20260907 R3,
  "`report.md` says 'all slices reported OK' for an `--only` run in which one slice was never
  dispatched" — and `report.md` is the artifact `/ship-correct` phase 5 tells the reader to
  route on.
- **Disposition:** proposed. Spaces fixed; "never reported" → "did not report"; the
  fall-through prints `**Attempt N — routing:** no stage failed` when the verify passed;
  each non-`ok` repo's own `reason` is now recorded under the dispatch line; both
  `| while read … record` loops replaced with a here-string so they run in this shell.
- **What it would have caught:** the lane would have read the slice's reason
  ("`.env.example` still unshipped — settings.json edit denied by the session classifier")
  in `report.md` instead of opening `chatbot-eval.log`, and would not have had a line saying
  a stage failed when none did. Probed against this run's own `fanout.json`; the fixed lines
  render as intended.

### F2 — `/ship-correct` phase 1 has no shape for an objection that is assertable, but by a gate rather than by the suite

- **Evidence:** phase 1 offers three shapes, all of them steps in `smoke.yaml`, then
  `make verify` as the oracle and "**A step that does not fail here has not captured the
  objection.**" Its only escape hatch is "if it cannot be expressed as a step **at all** —
  it is purely how something looks". This objection was neither: it was a credential-plumbing
  defect, no HTTP client can see it, and the loop must run with no credentials
  (`BRIEF.md` § "A gap in the oracle"; ADR 0016 § Accepted costs, "It does not make
  `EVAL_JUDGE=bedrock` assertable in the loop"). The lane wrote a `check-docs.py` check
  instead, before the fix, and watched it fail on four counts — and none of that appears in
  `verify.json`'s 91.
- **Judgement:** clears the bar. Phase 1's own sentence declares the phase unfinished unless
  a step fails, so an agent following the text either invents a shape or softens the
  criterion into something HTTP-shaped. The mechanism it should point at already exists.
- **Disposition:** proposed — one paragraph in phase 1: a check in `scripts/check-docs.py`
  is the assertion when the oracle is not a request; write it before the fix, watch it fail
  with `./scripts/check-docs.py`, and say in the report which oracle it was, because
  `verify.json`'s count does not include a gate.
- **What it would have caught:** the lane's own uncertainty about whether a gate satisfies
  phase 1 — and the reverse risk, an agent with a plumbing objection reaching for a step
  that asserts something adjacent and HTTP-visible instead.
- **Deliberately not written:** the `jobs:` half. `docs/adr/0014` and `jobs:` do not exist
  on `origin/main` yet — they arrive with #19 — and `[dead-wiring]` correctly refused the
  citation when I tried it. Add that bullet after 0006 merges; see R5.

### F3 — the product-repo scaffold's `deny: Edit(./.env*)` globs the `.env.example` the same repo's `.gitignore` requires committed

- **Evidence:** `chatbot-eval/.claude/settings.json` denies `Edit(./.env*)`;
  `chatbot-eval/.gitignore` lines 5-7 are `.env`, `.env.*`, `!.env.example`. Same pair in
  `chatbot-backend` (whose `.env.example` was committed before the rule could bite) and in
  `frontend` (no `.env.example`, so the same block is still waiting); `infra` carries the
  `.gitignore` negation and no deny rule at all. The cost is in the record: two dispatches,
  `runs/20260909T161037Z/attempt-1/fanout.json` — "`.env.example` blocked by this repo's own
  deny rule `Edit(./.env*)`" — and `runs/20260909T161954Z/attempt-1/fanout.json` — the same
  item, now blocked one level up. Item 1 of the correction is still unshipped.
  `docs/init/README.md` § 2b tells the next person to copy the same settings file.
- **Judgement:** clears the bar for the harness half. Two committed files contradicting each
  other with the correct action on the forbidden side is `docs/adr/0008`'s shape, and the
  template that propagated it is a control-repo document.
- **Disposition:** proposed, as one paragraph in § 2 Step 2 where the shared template is
  defined — deny the real files by name, and check every `deny` pattern against that repo's
  own `.gitignore` negations before committing either. § 2b already says "same template as
  step 2", so it picks this up.
- **What it would have caught:** the `chatbot-eval` scaffold, written in this change's
  `/ship` lane, would have shipped a deny that does not match `.env.example`, and item 1
  would have been a one-line edit in the first dispatch instead of two dispatches and a
  hand-off to a human.
- **Not proposed as a gate:** see Rejected. And the three existing repos need a slice each —
  named in the report, not fixable from here.

### F4 — the retrospective still cannot clear its own gates: the ledger cannot see a lead that wraps, and `[dead-wiring]` reads `retros/` as live documentation

- **Evidence:** two halves, both hit while writing this file.
  `retro_findings.BULLET` is matched per line, so a bolded lead that wraps to a second line
  is invisible: `[retro-ledger]` refused this file with "declares 11 proposed+recorded
  finding(s) and scripts/retro_findings.py can see 10", and the five it could not see were
  R2, R3, R4, R5 and R7. `retros/README.md` requires a lead that stands alone, and a lead
  that stands alone does not fit an 88-column line — so the gate's only remedy was to write
  worse leads. Across the committed corpus the same blindness hides **seven** more:
  `R10 — the whole freeze is in contracts/README.md, which is deliberately never published`
  and `R3 — an agent that stops to wait for CI is no-result` (20260901), three in 20260827,
  one in 20260902-realign, and — exactly on point —
  `R7 — [dead-wiring] reads retros/ as live documentation` (20260902-ship-iterate).
  Which is the second half: `check-docs.py` `[dead-wiring]` failed this file for citing
  `docs/adr/0014`, an ADR that exists on `feat/0006-chatbot-eval` and not on `origin/main`,
  where § 5 requires this branch to stand.
- **Judgement:** clears the bar twice over. The ledger half is the third occurrence of the
  class the open pull request on this branch is named after (F1/20260903), and it is a defect
  in that fix's own mechanism. The `[dead-wiring]` half is the fifth occurrence of "the
  retrospective cannot clear its own § 5 gate" (R2/20260826, R2/20260827, F1/20260901,
  R7/20260902) and R7 spelled the three-line fix out and said the next retrospective should
  propose it on sight rather than degrade its own record again. I degraded mine, noticed, and
  am proposing it.
- **Disposition:** proposed. `retro_findings._unwrap()` joins a wrapped bullet lead before
  matching; `[dead-wiring]` skips `retros/` in the two path-existence loops and leaves it in
  `all_prose`, so the reverse-direction checks are untouched.
- **What it would have caught:** the seven leads listed above would have been in the § 7
  ledger I was handed — including the one that would have told me `[dead-wiring]` was already
  a known defect with a known fix, before I paid for it again. Both halves probed in both
  directions: without `_unwrap` the gate refuses this file and with it the corpus count rises
  in four files and falls in none; a bogus `docs/adr/0099` still fails `[dead-wiring]` in
  `docs/init/README.md` and is correctly silent in `retros/`. Every probe restored —
  `git status` carries only the intended edits.

## Recorded, not proposed

- **R1 — nothing commits the run's own record, fourth occurrence.** `iterate.sh`
  `update_status()` writes `failed` into `STATUS.md` and no lane says to commit it; `prs.sh`
  pushes the control repo but runs on a green outcome only, so a `failed` run leaves its own
  record dirty. Retro 20260827 R11, retro 20260907 R4, and committed by hand again here
  (`91aeeaa`). Proposable now and deliberately left: the honest mechanism is a machine commit
  into the control repo, which is a bigger decision than a retro should take unilaterally,
  and this pull request is already at three findings. The interim is one line —
  `git add changes/<change>/STATUS.md <slice-repos> && git commit`.
- **R2 — `[provider-credentials]`'s load-bearing clause is a substring test over the whole
  of `dev-env.sh`, so the file cannot document its own rule.** `if SECRETS_FILE in
  dev_env_sh` matches a comment as readily as a read. Measured: appending the comment line
  `# secrets.env` to `scripts/dev-env.sh` fails the gate. `dev-env.sh`'s header is exactly
  where "this file must not read `stack/secrets.env`, per ADR 0006" belongs, and it is the
  one place that cannot say it. Second occurrence of retro 20260826 F3's class, where
  `[commands]` false-positived on a URL path fragment and correct prose was rewritten to
  satisfy it. One-line fix: test only lines whose first non-space character is not `#`.
- **R3 — `STATUS.md` records the `failed` outcome and not the blocker, and § Blockers still
  says "None known at dispatch."** The run ended blocked on a permission with two exact
  hunks a human must apply in `chatbot-eval`, and that survives only in the lane's chat
  report and in `91aeeaa`'s commit message. `/ship-correct` phase 3 specifies the
  `## Corrected, <date>` heading and says nothing about an outstanding blocker; the
  `## Blockers` section is scaffolded and nothing fills it — the same shape as retro
  20260826 R6, the PR table column nothing fills.
- **R4 — `scripts/dev-env.sh`'s header claims the parser "handles `KEY=VALUE`, `#`
  comments, blank lines and an optional `export ` prefix".** It handles a whole-line comment
  only; a trailing one becomes part of the value, which is what
  `[dev-env-inline-comments]` now gates. The gate's message says the parser "does not strip
  comments" and the header says it handles them. The header's "NOT A SHELL" list — no
  quotes, no `$VAR`, no continuations — omits the one that bites.
- **R5 — a retrospective for a change that ATTACHES a submodule cannot have a clean
  `git status` on a main-based branch.** `origin/main` has three submodules and this change
  adds a fourth, so switching here leaves `chatbot-eval/` untracked and `chatbot-backend`'s
  pointer modified before I touch anything. Only the paths I edited were staged. The same
  topology means `make check` on this branch gates three repos, not four, and means a fix
  responding to a mechanism the in-flight change introduced cannot cite it —
  `[dead-wiring]` refused `docs/adr/0014` (see F2). Same family as retro 20260907 F1, which
  this pull request already fixes for `[vendored-contracts]`.
- **R6 — a harness fix was committed onto the change branch.** `74dbfe3`, "the jobs stage
  ran one of two jobs and reported a pass", is a `scripts/` fix inside
  `feat/0006-chatbot-eval`, against `CLAUDE.md`'s "Harness fixes arrive as a PR from
  `harness-retro`. Never slip one into a change." Recorded openly in `STATUS.md`, and the
  defect was blocking the run that found it, so the alternative was to stop shipping. Noted
  because the rule as written has no exception for "the mechanism under the run is broken",
  and something that happens anyway should be described rather than forbidden.
- **R7 — the harvest still calls five declared-but-never-observed 422s out, third run
  running.** `runs/20260909T161954Z/attempt-1/harvest.log`, the same five path/status pairs
  as retro 20260902's F3. Reported, never acted on, and it costs a paragraph of every
  failure brief the repair agents read.
- **R8 — nothing in the loop read `job-*.log` or `jobs.tsv` after the stage passed.** Both
  jobs' logs are captured per attempt in both runs and the report states only "2 of 2 ran
  exited as declared". That is the right summary and the evidence is worth keeping; noted
  only because it is the one class of evidence here that nothing downstream consumes.

## Rejected

- **`[dev-env-inline-comments]` as a speculative check.** Its own rationale block says "this
  is a live trap precisely because the file was just made terse" and names no defect that
  happened, which is the one thing `check-docs.py`'s header says disqualifies a check. But
  ADR 0016 § Decision 6 adopts it on purpose and gives that reason, and § 1 of my brief says
  a cost accepted on purpose is not a finding. Two limits worth the author's attention, in
  the report rather than a diff: it can only see `stack/dev.env`, and layer 3 —
  `chatbot-backend/.env`, gitignored, another repo's file, source of `CHAT_MODEL` — is where
  a trailing comment would misroute a stack failure to a product repo; and R4.
- **A gate comparing each submodule's `deny` patterns against its own `.gitignore`.** It
  would fail today for three repos and its only remedy is inside a product repo, which is
  precisely the shape retro 20260907 F1 identified and this pull request removes for
  `[vendored-contracts]`. A permanent red gate nobody standing here can clear teaches
  everyone to skip the gate.
- **Anything about the session-level guard on editing permission settings.** It is above the
  harness; no wording of a slice file can clear it, and the lane was right to stop after two
  dispatches rather than buy a third identical report.
- **"My gate was wrong on its first run" as a harness defect.** `[provider-credentials]`
  swept `CREDENTIAL_SHAPED` over a committed `dev.env` and flagged three `.test` identities
  the suites must interpolate; the author ran it, saw it, and narrowed it to a four-name
  `PROVIDER_SECRET`. That is the loop the memory note "confirm every gate blocks AND passes"
  asks for, working. Graded, and it is not a finding.

## Not verified

- **Nothing about a remote environment.** `deploy.infra: false` by design; no AWS read was
  attempted from here and none should be.
- **`make eval JUDGE=bedrock`, the objection's actual oracle.** It needs real credentials.
  `stack/secrets.env` is absent from this tree (correctly — it is gitignored), so the fix's
  end-to-end behaviour is the user's to confirm with `make creds` and one `make eval` run.
- **`[provider-credentials]` was verified as a gate, all five clauses.** Each was made to
  fail and restored exactly: template absent, template without `AWS_REGION`,
  `stack/secrets.env` un-gitignored, `dev-env.sh` naming the file, and the `eval` service
  losing its `env_file` entry. `git status --porcelain` was empty afterwards. That is the
  strongest single thing this lane produced.
- **`[dev-env-duplicates]`, `[env-layers]`, `check_suite_vars`, `[image-tags]`** — passing
  on both branches, not individually probed this lane.
- **The two hunks the eval repo needs** were read but not applied: this retrospective does
  not write inside a product repo.

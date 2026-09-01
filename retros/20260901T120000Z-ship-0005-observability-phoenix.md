---
lane: ship
change: 0005-observability-phoenix
run: changes/0005-observability-phoenix/runs/20260901T113130Z
date: 2026-09-01
verdict: coherent-with-warnings
findings: 3 proposed, 11 recorded, 4 rejected
pr: https://github.com/Paggio/agent-app-project/pull/PENDING
---

Four runs. The green one is honest — `verified-local`, 55 assertions, 10 from the change's
own suite, `remote_asserted: false` and a report that says so. The three before it are where
the harness has something to answer for, and two of the three failures were the harness
misreading its own evidence rather than the change being wrong.

The headline is `112951Z`: a backend 500 on `a-message-carries-a-trace-id` meant its
`capture` never bound, the next step's `${chat_trace}` hit `interpolate`'s `die()`, and the
run ended `fault: harness`, `outcome: unattributable`, `smoke.json` reporting
`passed: 0, failed: 0, steps: []`. A real product-repo failure was reclassified as a
control-repo bug, no brief was written for anyone, and the 45 assertions that had already
been judged were overwritten with zeros. Every suite that captures a value and reuses one
has that shape, `smoke/baseline.yaml` included.

And this retrospective is the first in three that can open a pull request, because
`make check` no longer fails on the branch it is required to branch from. That was a
two-line bug, not the design tension the 20260826 and 20260827 retros escalated.

## State audit

- **Control repo** — clean tree on `feat/0005-observability-phoenix` at `c5725c8`, submodule
  pointers included. `contracts/` last moved in `dfbb48f`, whose diff is
  `contracts/README.md` and nothing else, and it is an ancestor of HEAD.
- **Freeze recorded** — `change.yaml:8` has `dfbb48f8…`, and `STATUS.md:5` carries the same
  40 characters from the scaffold. Third occurrence of R5/20260826; they agree today.
- **Submodules** — `chatbot-backend` `3ceff45` on `feat/0005-observability-phoenix`, clean,
  ahead of `repos.lock` (`4a80a99`); `frontend` `d9b76a8` and `infra` `6eebe0a` on `main`,
  matching the lock. That is what `/ship` is supposed to leave.
- **Contract against what is served** — re-checked in this lane.
  `runs/20260901T113130Z/attempt-1/harvest.log`: additive only, the same five paths
  returning an undeclared `422` as 0004. No breaking drift.
- **Assertions** — 55 passed, 0 failed, 10 from the change's own suite. Not thin for its
  size: the header on two routes, the trace present in Phoenix, rooted at the HTTP span,
  the graph run nested under it, and the project registered. Six of the thirteen criteria
  are asserted outside the seam and the brief says so — see R9.
- **The cloud** — nothing reached a remote environment. `verify.json` records
  `environment: null` and `remote_asserted: false`, `deploy.infra` is `false`, and the
  report's label is `verified-local`. F1/20260826's fix is holding.
- **Pull requests** — chatbot-backend#8 is a fact in `prs.json`, written by `prs.sh --create`
  and confirmed here as `OPEN` with `static` and `integration` both `SUCCESS`.
  agent-app-project#13 is `OPEN` with `docs` and `manifests` both `SUCCESS` — but it is
  **not** in `prs.json`, because `prs.sh --create` iterates `$CHANGE_SLICES` only. It was
  opened by hand. See R8.
- **Gates, re-run now** — `check-docs.py` exit 0 (14 checks then, 15 with F3's,
  plus the one known permanent warning),
  `manifest.py --validate` exit 0, `test-hooks.py` exit 0 in both directions,
  `smoke.py --lint` clean. `make check` exit **1** on a branch off `origin/main` — that is
  F1 below, and it is fixed here.
- **The stack** — **up** after the lane finished. R8/20260826, second occurrence.
- **Not verified** — anything in a remote environment; there is none. The out-of-band
  results in `STATUS.md` § "Out-of-band checks" were not re-run here.

## Findings

### F1 — `make check` counted gitignored run evidence as a change, and failed on the only branch a retrospective may use

- **Evidence:** `Makefile:144` globs `changes/*/` off the filesystem. `changes/*/runs/` is
  gitignored, so a run leaves `changes/0005-observability-phoenix/` on disk on *every*
  branch, including one branched from `origin/main` where that change does not exist. On
  this branch, before the fix: `manifest: changes/0005-observability-phoenix/change.yaml not
  found — run ./scripts/new-change.sh`, `make: *** [check] Error 1`. Every other gate was
  green, including both product repos' lint and typecheck on their feature branches.
- **Judgement:** fourth occurrence of the class "the retrospective cannot clear its own § 5
  gate" — but not the same cause. R2/20260826 and R2/20260827 are the vendored-contracts
  freeze window, a design tension needing a human. This one is a shell glob reading
  gitignored evidence as source, with no ADR behind it and no decision to make. Leaving it
  recorded would strand a third consecutive retrospective's fixes on an unopened branch, and
  20260827 R3 measured what that costs.
- **Disposition:** proposed. `git ls-files --error-unmatch` decides which directories are
  changes; the glob only says which exist. Shown both ways: before, exit 1 naming 0005;
  after, the four tracked changes validate and 0005's evidence directory is skipped.
  A tracked change directory missing its `change.yaml` still fails, as it did.

### F2 — a cascading capture was reported as a malformed suite, and every result collected so far was overwritten with zeros

- **Evidence:** `runs/20260901T112951Z/attempt-1/smoke.json` is
  `{"ok": false, "error": "undefined variable ${chat_trace} …", "passed": 0, "failed": 0,
  "owners_failing": [], "failures": [], "steps": []}` — written by `smoke.py`'s `die()`
  over a run in which 45 baseline steps had already been judged and
  `a-message-carries-a-trace-id` had failed with a 500 owned by `chatbot-backend`.
  `verify.sh:409` maps exit 2 to `smoke: the suite is invalid — fix it here, not in a
  product repo`, `fault: harness`; `iterate.sh` recorded `outcome: unattributable` and
  wrote no failure brief. `smoke.py`'s own lint comment at line 244 says the fix for
  mid-run exit 2 was static checking — and static checking cannot see this case, because
  `${chat_trace}` *is* declared by an earlier step. Reproduced against a stand-in server:
  step fails 500, next step dies, exit 2, zeroed JSON.
- **Judgement:** ADR 0003's rule is "exit 1 means the thing under test failed, exit 2 means
  the harness refused". This is the rule applied correctly to a case the ADR did not
  separate out, not an argument with it: a capture that did not bind because its step
  returned a 500 is the thing under test failing. Nothing is weakened — the consequent step
  now **fails** and is routed, where before the whole run aborted.
- **Disposition:** proposed. `interpolate` raises `CascadeSkip` only for a name some
  *selected* step declares in `capture:`; `run_step` turns that into a failed step owned by
  its own `owner`, with a message naming the upstream cause. `die()` now writes the results
  it had instead of zeros. Shown four ways on the same suite: the cascade is exit 2 with
  `passed: 0` before and exit 1 with `passed: 1, failed: 2,
  owners_failing: ["chatbot-backend"]` after; a genuinely undeclared `${VAR}` is still
  refused by `--lint` at exit 2; a capture whose step was filtered out by `--only` is still
  exit 2, correctly, because it is a selection problem; and `die()` in that case now carries
  the one step that had passed. What it would have caught: `112951Z` would have been
  `outcome: failed`, `fault: slice`, `owners_failing: chatbot-backend`, with a brief
  containing the 500 — instead of a dead end blamed on this repo.

### F3 — the failure dump and the repair brief have covered six of nine services since 0004

- **Evidence:** `runs/20260901T111656Z/attempt-1/` holds six `.container.log` files for a
  nine-service stack. `scripts/stack.sh:23` — `SERVICES=(backend postgres redis frontend
  proxy)` — and `scripts/failure-brief.py:30` — `"chatbot-backend": {"primary":
  ["backend"], "supporting": ["postgres", "redis"]}` — are two hand-kept lists that 0004
  did not update when it added `opensearch` and `minio` to `stack/compose.yml`. So a
  knowledge-base failure produces no OpenSearch log at all, and would be briefed to the
  backend agent without one. This lane added `phoenix` to the first list and deliberately
  left 0004's gap alone rather than slipping a harness fix into a change — the right call,
  and it is why the gap is still here.
- **Judgement:** two lists claimed as evidence-gathering, silently partial for two changes,
  and `service-owner.sh:36` already states the doctrine they violate — "the join is the only
  file that can see both repos, so that is where ownership is declared; this reads it back
  rather than hardcoding a second copy". Fixing today's instance without a gate is what
  guarantees a third.
- **Disposition:** proposed. Both lists corrected, plus `check-docs.py [stack-services]`,
  which fails when a service in `stack/compose.yml` is missing from either. Shown failing
  first — it names `minio` and `opensearch` in both files, which is exactly 0004's omission
  — and passing after. Probed against 0005's own `stack/compose.yml`, where it names
  `phoenix` and `phoenix-db`; `stack/compose.yml` was restored byte-for-byte. Note for the
  reviewer: once 0005 merges this gate will require `opensearch`, `minio` and `phoenix-db`
  in `stack.sh` and `phoenix`/`phoenix-db` in `failure-brief.py`. That is the gate working.

## Recorded, not proposed

- **R1 — the run lock stores the pid it never checks.** `iterate.sh:118-129`. The first run
  was killed externally mid-dispatch; the next refused with "Wait for it, or remove the
  directory if it is stale" over an `owner` file reading `pid=52975`. The lane ran `ps -p`
  and `rm -rf` by hand. The lock already holds the one fact that answers the question it
  asks a human. `kill -0` is the whole fix; the infra lock at `iterate.sh:90` has the same
  shape and has never bitten, so a reviewer should decide whether reclaiming a *remote*
  environment lock on a dead local pid is safe before both are changed together.
- **R2 — a refused run still leaves an empty run directory.** `RUN_ROOT` is created at
  `iterate.sh:80-82`, the run lock is taken at `:118`. `runs/20260901T111630Z/` is empty and in
  the evidence for no reason. Same fix site as R1.
- **R3 — an agent that stops to wait for CI is `no-result`, and the loop then drops a
  finished slice.** `runs/20260901T111656Z/attempt-1/fanout.json`:
  `"status": "no-result", "exit": 0`, `left_on_branch: {commits: 2, uncommitted: 0}`, over a
  log ending "CI is still running; the monitor will notify me when both checks land". The
  implementation was complete and passed everything on the next run with no further
  dispatch. F2/20260826's `left_on_branch` and its printed hint did their job — the lane
  says the message is what stopped it re-dispatching over finished work — but `iterate`
  still concluded "no evidence for chatbot-backend; dropping it from this repair pass" and
  the lane dead-ended on a change that was already done. The gap between "knows there are
  two commits on the branch" and "acts on it" is the residue.
- **R4 — `## Next` sends an `unattributable` run to briefs that were never written.**
  `iterate.sh:203` sits in an `else` covering `failed` and `unattributable` alike, so both
  reports say "Attempts exhausted with the assertions still failing… read the briefs at
  `attempt-*/failure-*.md`" — in `112951Z` no assertion ran and no brief exists, and the
  same report's own "What happened" says so two paragraphs earlier.
- **R5 — a dispatched slice's own stack broke the verify that followed it.** Second
  occurrence of R7/20260826, recorded there as proposable on sight.
  `runs/20260901T111656Z/attempt-1/verify.json`: `preflight: port 8000 already in use`,
  `fault: harness`. The holder was the `claude -p` session's own `make up` in
  chatbot-backend — backend, postgres, opensearch, minio and phoenix. Cleared by hand.
  Preflight refusing was right. Not proposed for the reason 20260826 gave and this lane
  did not change: tearing down a compose project the loop did not start can destroy
  something a human wanted running, and that is a decision, not a retro fix.
- **R6 — the STATUS.md PR column, filled with filler to clear a gate.** Second occurrence
  of R6/20260826. `manifest.py:215` refuses `<link>` at the phase-3 gate; the scaffold ships
  `<link>` in a column whose only fact — the PR URL — is produced in phase 5. The lane wrote
  "_opened by phase 5_". Not proposed only because it collides with R8: the right fix is
  `prs.sh --create` maintaining that table, which is R8's decision.
- **R7 — the freeze SHA's second home.** Third occurrence of R5/20260826.
  `STATUS.md:5` carries the literal SHA the scaffold asks for, next to `change.yaml:8`
  where CLAUDE.md says it lives and nothing else reads. They agree today, again.
- **R8 — this repo's half of the change is still opened by hand.** Second occurrence of
  R11/20260827. `prs.sh:77` iterates `$CHANGE_SLICES`; `--list` was taught about this repo
  and `--create` was not. The lane pushed the branch, opened #13 and committed
  `0005: record the control-repo PR` to write the URL into `STATUS.md` — so `prs.json`, the
  artifact the audit treats as fact, is missing half the change. 20260827 called the fix
  non-obvious because it puts a `git push` in a loop that touches no remote except through
  `prs.sh`; the lane's behaviour now answers the *shape* question and leaves the ADR one
  open.
- **R9 — a change's out-of-band oracle lands in `scripts/` and nothing runs it.** Criteria
  8 and 9 have no seam oracle: `smoke.py` speaks HTTP against a stack it did not start, so
  it can neither restart a container nor read stdout. The lane wrote a script, a Makefile
  target and a `## Out-of-band checks` table in `STATUS.md`, following 0004's precedent —
  a good answer, and nothing in the loop runs any of it, so the result is only as durable as
  the next person remembering. It also leaves a change-specific script in the shared
  `scripts/` directory forever. Whether a change may declare an out-of-band check that
  `verify.sh` runs and counts is a capability decision with an ADR's worth of consequence,
  and it is the third change to hit it. Same class as F2/20260827, and it should be decided
  rather than met again.
- **R10 — the whole freeze is in `contracts/README.md`, which is deliberately never
  published.** `vendor-contracts.sh:20` publishes `openapi.yaml` and `infra-outputs.yaml`
  only, on purpose. 0005's freeze — the `X-Trace-Id` promise — touches only
  `contracts/README.md`, so the slice saw it in the tree `fanout.sh` extracted at the freeze
  SHA (confirmed: `runs/20260901T105539Z/attempt-1/contracts/README.md`), and
  `chatbot-backend`'s CI verifies against a vendored copy that does not contain it. An
  accepted cost that had never carried a whole freeze before. No harm this time — the seam
  suite asserts the header — so proposing a gate on it would be the speculative check
  `check-docs.py` refuses. Recorded so the next occurrence is a second one.
- **R11 — expired AWS credentials present as a product 500.** `CHAT_MODEL` is deliberately
  undeclared in `stack/dev.env` so it falls through to `chatbot-backend/.env` (ADR 0006
  layer 3), which selects `bedrock`. In `112951Z` every model-bearing step returned 500 from
  `botocore ExpiredTokenException`, in the baseline as much as in this change's suite, and
  the repair loop would have sent that 500 to a backend agent as a brief. `CHAT_MODEL=echo`
  fixed it in one word, exactly as `stack/dev.env` says. The design is sound and documented;
  what is unrecorded is that an expired token is indistinguishable from a broken handler
  until somebody reads a container log. Not proposed: a preflight credential probe is a new
  network call in the loop, and the lane resolved it in one word.

## Rejected

- **`stack.sh`'s usage text addressed by line number** (`sed -n '2,13p' "$BASH_SOURCE"`,
  bumped by hand when `restart` was added). Real fragility, but it did not fail: the lane
  remembered. § 4 rejects a proposal whose defect is hypothetical.
- **A preflight that refuses when a slice repo's own compose project holds a port.** R5 —
  the destructive half is a decision.
- **A gate that every numbered criterion has a step.** Rejected twice before, and 0005 is
  the case that shows why: six of its thirteen criteria are correctly asserted elsewhere and
  the brief says where.
- **Anything in `contracts/` or a product repo, and the `X-Trace-Id` promise.** Frozen,
  implemented, additive, and it would cost two consumer pull requests to touch.

## Not verified

- Anything in a remote environment. `deploy.infra` is false and `remote_asserted` is false;
  `verified-local` is the whole of what this lane proved.
- The out-of-band results recorded in `STATUS.md` — the durability check and the log
  correlation. They are the lane's testimony, not re-run here.
- Whether a real dispatched session behaves differently under the F2 fix: the probe used a
  stand-in HTTP server, not `claude -p`.

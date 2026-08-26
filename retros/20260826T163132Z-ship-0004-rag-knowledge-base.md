---
lane: ship
change: 0004-rag-knowledge-base
run: changes/0004-rag-knowledge-base/runs/20260826T161953Z
date: 2026-08-26
verdict: coherent-with-warnings
findings: 3 proposed, 7 recorded, 4 rejected
pr: none — see "The retro lane could not clear its own gate"
---

Three runs, and the first two are where the harness has most to answer for. The green run
is honest about its evidence in prose and wrong about it in its label; the failed run
declared that a slice had produced nothing while four finished commits sat on its branch.
Both are recording defects rather than judgement defects — the loop looked in the right
places and then wrote down the wrong word.

Three fixes are committed here and **no pull request was opened**, because the retro lane's
own §5 gate cannot pass in the window it is required to run in. That is the first thing
below.

## The retro lane could not clear its own gate

`harness-retro` § 5 requires two things at once: branch from `origin/main`, and `make check`
green before opening anything. After a `/ship` that froze a contract, those two are in
direct conflict.

- On `harness/retro-20260826T163132Z`, branched from `origin/main` as instructed,
  `contracts/openapi.yaml` is at `version: 1.3.0`. The lane left `chatbot-backend` and
  `frontend` checked out on `feat/0004-rag-knowledge-base`, where the vendored copy is the
  frozen `1.4.0`.
- `check_vendored_contracts` (`scripts/check-docs.py:417`) compares those two and fails:
  `chatbot-backend/contracts/openapi.yaml differs from contracts/openapi.yaml`. `make check`
  exits 1.
- The same working tree with the same diff, evaluated where `contracts/` and the submodule
  checkouts agree, exits 0 — `make check` on `feat/0004-rag-knowledge-base` with all three
  script changes applied passes every gate including both product repos' lint and typecheck.

So the failure is not in the diff and not in the branch: it is the mid-flight state that
`/ship` is defined to produce and `/realign` is defined to end, read by a check that has no
notion of the window. Per § 2 and § 5 this is a system defect — reported, not fixed, and no
pull request opened. It is the same defect as R2 below, met a second time, by the
retrospective itself, on the first occasion the lane has ever run.

The branch carries the record and three fixes and is pushed but unopened. A human decides
whether the drift is acceptable at this point in the cycle, or whether R2 gets fixed first.

## State audit

- **Control repo** — clean tree on `feat/0004-rag-knowledge-base` at `2baf50c`; nothing
  uncommitted. `contracts/` last moved in `44e38bc`, whose diff is `contracts/README.md`
  and `contracts/openapi.yaml` and nothing else, and it is an ancestor of HEAD.
- **Freeze recorded once** — `changes/0004-rag-knowledge-base/change.yaml:12`. It also
  appears in that change's `STATUS.md:6`, under the `## Contract freeze` heading the
  template scaffolds; `check_freeze_sha_home` scans `BRIEF.md` only, so the second copy is
  unchecked. It matches today. See finding R5.
- **Submodules** — `chatbot-backend` at `dd98e24` and `frontend` at `948eb74`, both on
  `feat/0004-rag-knowledge-base`, both clean, both ahead of `repos.lock`; `infra` on `main`
  at `6eebe0a`, matching the lock. That is what `/ship` is supposed to leave behind.
- **Contract against what is served** — re-checked in this lane. `attempt-1/harvest.log`
  in all three runs: additive only, five paths returning an undeclared `422`. No breaking
  drift.
- **Assertions** — 61 passed, 0 failed, 25 of them from the change's own suite. Not thin:
  the change suite covers the session gate, the size and type refusals, the retrieval
  round trip, cross-account isolation, and deletion purging both storage and the index.
- **The cloud** — nothing reached a remote environment. `verify.json` records
  `infra.remote_asserted: false` and `environment: null`; `deploy.infra` is `false` and
  `infra/` has no deploy target. The run is local-only, and the label it was given said
  otherwise. That is finding F1.
- **Pull requests** — facts, not claims: `runs/20260826T161953Z/prs.json` records
  chatbot-backend#7 and frontend#6 as `existing`, written by `prs.sh --create` after it
  queried them. `fanout.json` from the failed run claimed `pr: null` for chatbot-backend
  and was wrong about that too.
- **Gates, re-run now** — `check-docs.py` exit 0 (14 checks, 1 known warning),
  `manifest.py --validate` exit 0, `test-hooks.py` exit 0 in both directions, `make check`
  green including both product repos' lint and typecheck on their feature branches.
- **The stack** — down.
- **Not verified** — nothing in a remote environment, because there is none; no AWS read
  was attempted.

## Findings

### F1 — `verified` was printed for a run that touched no environment, and `verified-local` was unreachable

- **Evidence:** `changes/0004-rag-knowledge-base/runs/20260826T161953Z/report.md` says
  `outcome: **verified**` above `infra deploy: no`, while
  `attempt-1/verify.json` says `"remote_asserted": false`. `/ship`'s own routing table
  defines `verified` as "Deployed and asserted, locally and remotely"; `docs/adr/0004`
  § Consequences says the same in the ADR that owns the word. `iterate.sh` gated
  `verified-local` on `[ "$CHANGE_DEPLOY_INFRA" = "1" ]`, so a change declaring no deploy
  target could not reach it under any flag. The change's own `change.yaml` predicted
  `verified-local` in a comment, and the lane then hand-wrote a whole
  `## What the green run does and does not say` section into `STATUS.md` to contradict the
  harness's label. A human writing prose to correct a machine-generated word is the defect.
- **Judgement:** this is the class `docs/adr/0003` exists to prevent, surviving in the
  outcome vocabulary itself — an outcome inferred from a condition that was never checked.
  No ADR accepted it; ADR 0004 states the opposite.
- **Disposition:** proposed. `iterate.sh` now decides on `remote_asserted` alone, and the
  report's `## Next` distinguishes "you skipped the remote pass" from "this change declares
  no deploy target, so this is its best outcome". Re-running the identical green run under
  the fix printed `verified-local`, exit 0, 61 assertions, both PRs still handled.

### F2 — a slice killed by the watchdog was recorded as `crashed`, and the work on its branch went unrecorded

- **Evidence:** `runs/20260826T151424Z/attempt-1/fanout.json` records chatbot-backend as
  `"status": "crashed", "exit": 143, "pr": null`; `fanout.log` shows
  `13638 Terminated: 15`; `chatbot-backend.log` is 0 bytes because `claude -p` writes at
  completion. `slice-result.py:60` defines a `timeout` status with the words a reader
  needs — and it never appeared, because `fanout.sh` wrote its marker *after* the kill
  (`kill -TERM -$pid && touch .timeout-$r`) while the parent's `wait` wakes the moment the
  child dies. The parent wins that race essentially always: it has to do nothing, the
  watchdog has to fork `touch`. What followed was each step behaving correctly on a false
  premise — `failure-brief.py` exit 3, "no evidence was captured", `iterate.sh` "No repo
  could be given evidence to repair from", run over. At that moment
  `git -C chatbot-backend log --oneline main..HEAD` showed **4 commits and a clean tree**:
  the slice was finished. Recovery was a human hunch, which the harness suggested nowhere.
- **Judgement:** a defined protection that could not fire (`timeout`), plus a dead end that
  reports "produced nothing" without ever asking what was produced. Reproduced verbatim:
  `fanout.sh` with a stand-in `claude` and `--timeout-s 3` yields
  `crashed (agent exited 143)` before the fix and
  `timeout … left 4 commit(s) on feat/0004-rag-knowledge-base (0 uncommitted)` after.
- **Disposition:** proposed. The marker is written before the signal and paired with a
  non-zero exit on collection (so a slice that finished before its watchdog woke is not
  mislabelled); any slice that did not report `ok` gets `left_on_branch` in `fanout.json`,
  a printed hint from `fanout.sh`, and — where a human actually lands — a line in
  `report.md` at the "no evidence" dead end.

### R1 — `smoke.py` cannot express a multipart request, and that shaped the frozen contract

- **Evidence:** `scripts/smoke.py:56` — `STEP_KEYS` has `body` and `form`, no `files`. The
  lane designed `POST /v1/documents` to take a UTF-8 `content` field in a JSON body partly
  because a multipart upload could not be seeded at the seam at all, which would have made
  retrieval, citations and delete-purges-the-index unassertable. That decision is recorded
  in `BRIEF.md` and defensible on its own merits; what is not fine is that a limit of the
  oracle reached the interface between three repos.
- **Judgement:** meets the bar on defect and evidence. Fails it on "the smallest change":
  the fix is a new capability in the one script whose readability is why it is trusted as
  the oracle, and the prior question — should the seam suite be able to assert a file
  upload at all — is a human decision worth an ADR line, not a diff smuggled in by a retro.
- **Disposition:** recorded. Named here so the next lane that meets it can propose it as a
  second occurrence, with this retro as the citation.

### R2 — `check-docs.py [vendored-contracts]` hard-fails for the whole freeze-to-dispatch window

- **Evidence:** `scripts/check-docs.py:417` compares each submodule's vendored
  `openapi.yaml` byte-for-byte against `contracts/openapi.yaml` and `fail()`s on a
  difference. `docs/adr/0008` makes `fanout.sh`/`vendor-contracts.sh` the publisher, at
  dispatch — so between the phase-2 freeze commit and phase 4 the copies necessarily
  differ, and the state the check calls a failure is the state a freeze is *defined* to
  create. The lane read the error, decided it was expected, and ignored it. That is a
  blocking gate teaching a reader to ignore it, which `docs/adr/0003` names as worse than
  no gate.
  Second occurrence, immediately: it is what stopped `make check` on this retrospective's
  own branch and why no pull request was opened. See the top of this file.
- **Judgement:** real, repeatable, and now demonstrably costly — it blocks the lane whose
  whole job is to grade the harness. Not proposed **here** for one reason only: it is the
  check standing between this branch and a green `make check`, and a retrospective that
  fixes the gate blocking its own publication, in the pull request that publication would
  carry, is the shape of routing around a rule rather than clearing it. It needs a human
  decision. The shape worth trying: compare the vendored copy against `contracts/` at the
  change's `freeze_sha` as well as at HEAD, and downgrade to a named warning when it matches
  a freeze whose change has not yet merged.
- **Disposition:** recorded and escalated, with two occurrences on the record.

### F3 — `check-docs.py [commands]` false-positived on a URL path fragment, and correct prose was rewritten

- **Evidence:** it reported `contracts/README.md:171 names /content, which does not exist
  in .claude/commands/`. The text was `` `/content` ``, referring to
  `GET /v1/documents/{document_id}/content`. The escape hatch at
  `scripts/check-docs.py:465` only exempts a token the file also uses as `/{named}/`, and a
  path segment at the end of a path has no trailing slash. Exit 1, so it blocks, so the
  prose was reworded to satisfy it.
  Then it happened again, here: this very file failed the same check at line 131 for
  writing the finding down — `retros/…-ship-0004-rag-knowledge-base.md:131 names /content`.
  Two occurrences, the second one blocking the record of the first.
- **Judgement:** meets the bar on all four lines, and the second-occurrence rule applies
  without waiting. The alternative to fixing it was rewording correct prose to satisfy a
  broken check, which is the coercion the finding is about.
- **Disposition:** proposed. One more condition: a token that also appears in the file
  preceded by a path segment is a path, not a command. Shown blocking without the fix
  (`README.md:80 names /deploy` with a dead reference appended) and passing with it, and
  the appended line was removed again.

### R4 — `--verify-only` spends its full attempt budget on identical work

- **Evidence:** `runs/20260826T161636Z` used "2 of 2" attempts with dispatch skipped both
  times; `attempt-1/verify.json` and `attempt-2/verify.json` are identical down to
  `60 passed, 1 failed`. A failure brief was written for chatbot-backend that nothing
  consumed, and the report says "Attempts exhausted (2)" as though repair had been tried.
  Under `--verify-only` no code can change between attempts, so attempt 2 is identical by
  construction.
- **Judgement:** effort disproportionate to the risk, and a misleading line in the report.
  Smallest change: when `--verify-only` is set and `--max-attempts` was not given
  explicitly, the budget is 1.
- **Disposition:** recorded, proposable on second occurrence.

### R5 — the freeze SHA has a second home the gate does not scan

- **Evidence:** `CLAUDE.md` says the SHA goes in `change.yaml` as `freeze_sha` and
  "Nowhere else — nothing reads anywhere else". `changes/0000-example-change/STATUS.md`
  scaffolds `## Contract freeze / - SHA: <sha>`, and `check_freeze_sha_home`
  (`scripts/check-docs.py:69`) only looks at `BRIEF.md` — the shape of the defect it was
  written for, in the file it does not scan.
- **Judgement:** the two copies agree in 0004, so no drift has actually happened. Proposing
  on a hypothetical is what §4 rejects.
- **Disposition:** recorded. The rule and the scaffold contradict each other; a reviewer
  should decide which one is right rather than let a check settle it.

### R6 — the `STATUS.md` PR table is a column nothing fills, scaffolded with a value the gate refuses

- **Evidence:** `manifest.py:215` lists `<link>` in `PLACEHOLDERS` and refuses a change
  carrying one at the phase-3 gate; `changes/0000-example-change/STATUS.md:20-22` is
  scaffolded with exactly that in the PR column; `new-change.sh` substitutes `<slug>` and
  leaves `<link>` alone. The lane replaced the cells with prose and believed `prs.sh` fills
  them in phase 5 — `grep -n STATUS scripts/prs.sh` returns nothing. Nothing has ever
  filled that column; `prs.json` is where the checked fact lives.
- **Judgement:** a gate blocking on a value that cannot exist yet, guarding a table with no
  writer. Two candidate fixes, one prose and one mechanism: drop the placeholder from the
  template, or have `prs.sh --create` maintain the table the way `iterate.sh` maintains the
  verification block below it. The mechanism is the better answer and the larger diff.
- **Disposition:** recorded, proposable on second occurrence.

### R7 — a dispatched agent's own stack blocked the run that dispatched it, attributed to the harness

- **Evidence:** `runs/20260826T151424Z/attempt-1/verify.json` —
  `failed_stage: "preflight: port 8000 already in use"`, `fault: "harness"`. The holder was
  `chatbot-backend-backend-1`, the dispatched session's own `make up`, run because that
  repo's gates ask for it. Cleared by hand with `docker compose -p chatbot-backend down`.
  Nothing tears a slice's own stack down between dispatch and deploy.
- **Judgement:** preflight already names the holder and the remedy, so the cost was one
  manual command rather than a dead end, and `fault: harness` is arguably right — no
  product-repo agent can fix it. The structural fix (`fanout.sh` taking each slice repo's
  compose project down as its session returns) is a real proposal with a real risk of
  destroying something a human wanted running.
- **Disposition:** recorded, proposable on second occurrence.

### R8 — the loop leaves the stack up on a green early attempt, and says so as if the human asked for it

- **Evidence:** `iterate.sh` adds `--keep-up` whenever `ATTEMPT < MAX_ATTEMPTS`, so a green
  attempt 1 of 2 leaves the joined stack running; `verify.sh:146` then prints
  `stack left running (--keep-up)`, naming a flag the invocation did not pass, and
  `finish()` only mentions the stack when the human passed `--keep-up` themselves. A stack
  left up by one run is exactly what broke the preflight of another — see R7.
- **Judgement:** real, cheap to fix (say who asked for it, and say it on the way out), and
  the smaller half of a problem R7 owns.
- **Disposition:** recorded.

### R9 — a negative fixture that no longer trips its condition passes silently

- **Evidence:** `an-oversize-document-is-refused` sent 1372 bytes against
  `DOCUMENT_MAX_BYTES=2000` and a correct backend answered 201
  (`runs/20260826T161636Z/attempt-1/failure-chatbot-backend.md`). The lane fixed the
  fixture to 2589 bytes and wrote the trap into the fixture's own text. The nastier sibling
  is invisible: a fixture under the cap passes against a backend enforcing no limit at all.
- **Judgement:** rejected as a proposal. Nothing in `smoke.py` can know what condition a
  fixture was written to trip without the suite declaring it, and inventing that declaration
  on one occurrence is the speculative check `check-docs.py` refuses. The author's
  mitigation — the trap written into the fixture — is the right one.
- **Disposition:** rejected, recorded for the pattern.

### Rejected outright

- **Raising or lowering the 3600s slice budget.** The backend slice had committed
  everything before the watchdog fired; what failed was the recording, not the number. No
  evidence names a better one.
- **Adding `files:`/multipart to `smoke.py` in this pull request.** See R1 — a capability
  decision, not a retro fix.
- **Anything in `contracts/`, and anything inside a product repo.** Out of bounds by
  construction; the contract here is additive, frozen, and would cost two consumer pull
  requests to touch.

## Not verified

- Nothing in a remote environment. `deploy.infra` is false, `infra/` is an empty skeleton,
  `remote_asserted` is false, and no AWS credentials were used. A `verified-local` outcome
  is the whole of what this lane proved.
- The two pull requests' CI. `prs.json` records their URLs; nothing here fetched their
  check runs.
- Whether the dispatched sessions would still behave the same under the fixed `fanout.sh`:
  the probe used a stand-in for `claude -p`, not a real slice session.

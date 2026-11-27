---
lane: realign
change: 0009-governed-metrics-spoke
run: runs/dev-push-45865446411
date: 2026-11-26
verdict: coherent-with-warnings
findings: 2 proposed, 6 recorded, 2 rejected
pr: https://github.com/paggio/agent-app-project/pull/52
---

## State audit

- **Control repo** — `chore/realign-0009-governed-metrics-spoke` @ `954d09d` = origin = PR #51 head. Dirty: ` M .gitignore` (`tmp/`), not the lane's. `contracts/` unchanged since `9508c3f` (the 0009 freeze).
- **Submodules** — all six on `main`, matching `repos.lock` (`3be5404`, pointers + lock only).
- **Contract** — re-harvested in this lane per testimony (agrees; six framework 422s). Bundle shows only the 0009 run's harvest log; `/realign` writes no artifact. Not independently verified.
- **Assertions** — local 108/0 per testimony, no artifact. Remote 82/0, 0 from a change suite: the baseline alone. `smoke-remote.json` contains both promoted steps.
- **Cloud** — `runs/dev-push-45865446411`: `verified`, trigger `lock`, PR 51, `control_ref` 954d09d; every repo's built SHA = this branch's gitlink. `/dev-eval` 45867253513 passed on the same ref. Both commented on #51 by the lane. Dev since torn down (user's word).
- **Pull requests** — #51 open, head `954d09d` (fetched). Product PRs merged per testimony and the main SHAs.
- **Gates** — check-docs, manifest, test-hooks green now; `make check` green on this branch.
- **Stack** — local joined stack still up.

## Findings

### F1 — `dev-push.sh` commented `/dev-push` on #51 with a session a day expired; second occurrence
- **Evidence:** `runs/dev-push-45856708707` (refused, PR comment "refused before the remote pass began"), friction 4 (−1434 min). First: `retros/20261123T142020Z-ship-iterate-0009-governed-metrics-spoke.md` R1, which named the fix.
- **Judgement:** clears the bar. GitHub secrets are write-only; `push-gh-creds.sh` knows the expiry it pushed.
- **Disposition:** proposed — `scripts/gh-creds-fresh.sh`: `push-gh-creds.sh` records the expiry in the git dir; `dev-push.sh` and `dev-eval.sh` refuse (exit 2) under 30 min before commenting. Nothing recorded → warns, proceeds. Probed: stale record → exit 2 from both, no `gh` call; fresh → proceeds.

### F2 — realign's `STATUS.md` close-out never records the realign's own deploy and eval; third occurrence
- **Evidence:** `changes/0009-governed-metrics-spoke/STATUS.md` cites feat-branch runs 44498487651 / 45191545782 and "Dev is up and billing"; 45865446411 / 45867253513 appear nowhere, dev is down. `realign.md` § 5 orders the close-out "in the same commit" as the promotion, before § 5b exists. Prior: 0007 realign R2, 0008 realign R4.
- **Judgement:** a prose ordering defect, so the fix is prose.
- **Disposition:** proposed — § 5b: put both verdicts in STATUS.md too, commit, push (moves no gitlink).

## Recorded, not proposed

- **R1 — the "are these instructions current?" gate costs a human round trip (switch, re-type `/realign`).** Deliberate (0007 realign F1: the loaded file is the stale branch's). The lane could do the safe switch and ask only for re-invocation; first occurrence of the complaint.
- **R2 — `/realign`'s ARGUMENTS were a question; the lane inferred the change.** First occurrence.
- **R3 — promotion written before § 3's smoke, so the "before" baseline already held promoted steps.** Lane deviation; restart+smoke still ran, result 108/0.
- **R4 — `/realign` still writes no run artifact; local 108/0 and the harvest exist only in testimony.** Fifth occurrence (0008 realign R3). Needs a shape decision, not a line.
- **R5 — uncommitted `.gitignore` `tmp/` rides across branches.** Second occurrence (0009 ship-iterate R3). The user's tree, not the harness.
- **R6 — the remote count (82) alone cannot show a promotion landed.** Per-step results are in `run/smoke-remote.json` beside `verify-remote.json`; the lane grepped the log instead. Discoverability, one occurrence.

## Rejected

- **A STATUS.md "Merged" template (friction 7).** F2 states what goes in; a template is tidiness.
- **The six never-observed 422s, `[vendored-contracts]`, the stack left up.** Decided before.

## Not verified

- Local baseline 108/0 and the harvest result: no artifact (R4). Live AWS state: no credentials used.

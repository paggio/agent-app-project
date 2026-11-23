---
lane: ship-iterate
change: 0009-governed-metrics-spoke
run: changes/0009-governed-metrics-spoke/runs/20261123T135733Z
date: 2026-11-23
verdict: coherent-with-warnings
findings: 1 proposed, 3 recorded, 2 rejected
pr: https://github.com/paggio/agent-app-project/pull/48
---

## State audit
- **Control repo** — `feat/0009-governed-metrics-spoke` @ `dfc79e3`, even with origin. Uncommitted: `.gitignore` (`tmp/`, not the lane's amendment) and six gitlinks at the feat heads while HEAD keeps `repos.lock`'s (intended since `2b561c9`). `contracts/` untouched since `9508c3f` (11-17).
- **Submodules** — all six on `feat/0009-governed-metrics-spoke`, clean, off the lock as a `/ship-iterate` should leave them.
- **Contract against what is served** — re-harvested this run: the six known declared-never-observed 422s, nothing new. Not re-checked on dev.
- **Assertions** — local 142/0, 26 from the change suite. Remote 82/0, only 6 from the change suite (2 substantive; recorded in the 0009 ship retro as R9). Criterion 15 has no step.
- **Cloud** — `dev-push-45191545782` `verified`, deploy set = all six PR heads as they stand now. `45150648978` refused at the session step, no verdict; `45154679035` verified on the previous metrics-gateway head.
- **Pull requests** — `prs.json` fetched, seven existing PRs; fanout's claim matches.
- **Gates now** — check-docs 0 (vendored-contracts warning), manifest 0, test-hooks 0, `make check` 0.
- **Stack** — local stack up (15 containers); dev up and billing, per STATUS.md.

## Findings
### A docs-only criterion named the docs-currency gate as its oracle, and that gate could not fail on it
- **Evidence:** `BRIEF.md` criterion 15: "the slice's docs gate and the PR review are its oracle". `scripts/docs-currency.py` diffs `merge-base(HEAD, origin/main)..HEAD`; metrics-gateway's branch already held `README.md`, `CLAUDE.md`, `docs/architecture.md`, `docs/search.md` before `a8eb739`, so `docs-currency:metrics-gateway` was green before the amendment existed. `ship-iterate.md` § 1.2 assumes every criterion becomes a step; the doctrine for one that cannot lives only in `ship-correct.md` § 1. Second occurrence: `20261102T160806Z-ship-iterate-0008` R4 (criterion 24 asserted by nothing the loop reads).
- **Judgement:** clears the bar — happened twice in this lane, evidence is a file and a line, fix is one paragraph pointing at doctrine that already exists.
- **Disposition:** proposed — `ship-iterate.md` § 1.2 routes a stepless criterion to `/ship-correct`'s rule and says why docs-currency is not its oracle.

## Recorded, not proposed
- **R1 — `dev-push.sh` comments `/dev-push` without knowing the CI session is days stale.** Run `45150648978` refused at "The pushed session is still alive" (expired 2026-11-19); `make push-gh-creds` fixed it. CI fails fast at step 2 and `dev-push.sh` without `--no-wait` prints the fix; the lane chose `--no-wait`. GitHub secrets are write-only, so a local check needs `push-gh-creds.sh` to record the expiry it pushed. First occurrence of this shape.
- **R2 — a docs-only amendment cost a cold local verify (~40 min) and a full dev deploy (~40 min).** Both follow from rules: jobs force cold volumes (#44), and verified means the deploy set equals the PR heads (ADR 0018). A docs-only carry-over of the previous verdict is a change to ADR 0018, argued here, not diffed.
- **R3 — `.gitignore` carries an uncommitted `tmp/` on the change branch.** Not the lane's amendment; either the user's or a leftover from the 0009 ship retro's probing.

## Rejected
- **A `manifest --validate` check that every BRIEF criterion maps to a step.** Criteria are prose with no ids to map; it would refuse legitimate stepless criteria.
- **Anything about the six 422s, the `[vendored-contracts]` warning, or the stack left up.** Known and decided.

## Not verified
- Dev's live state (no AWS read, ADR 0018). Product-repo PR CI for `a8eb739` beyond STATUS.md's ☑. Whether `docs/how-it-works.md` meets criterion 15 — that is PR review's.

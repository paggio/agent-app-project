---
lane: ship-iterate
change: 0008-call-centre-hub-and-spoke
run: changes/0008-call-centre-hub-and-spoke/runs/20261102T155712Z
date: 2026-11-02
verdict: coherent-with-warnings
findings: 2 proposed, 5 recorded, 2 rejected
pr: https://github.com/paggio/agent-app-project/pull/37
---

## State audit
- **Control repo:** on `feat/0008-call-centre-hub-and-spoke` at `3abfc10`; tracked tree clean except the four gitlinks (feat heads, uncommitted on purpose) and untracked `.kube/` (gitignored by #37, not on this branch). `contracts/` untouched since the freeze `8a0b003`; `freeze_sha` only in `change.yaml`.
- **Submodules:** all four on `feat/0008-…`, 0 uncommitted, each head equal to `origin/feat/0008-…`; off `repos.lock`, as `/ship-iterate` should leave them.
- **Contract against served:** `runs/20261102T155712Z/attempt-1/harvest.log` passes; the six declared-never-observed 422s again.
- **Assertions:** local 120/0, 43 from the change suite; remote 77/0, 17 from the change suite.
- **Cloud:** `dev-push-41477228117/run/verify-remote.json` `verified`; its deploy set equals all four feat heads, which equal the PR heads. Criteria 21–23 are `local`-tagged, so dev never asserted them (R3). Dev left up on purpose.
- **Pull requests:** `prs.json` records #36 and the four product PRs as existing; backend #10 head re-fetched = `2182d09`.
- **Gates:** `check-docs` 29/0 (1 warning), `manifest --validate` 0, `test-hooks` 0, re-run now.
- **Stack:** local stack up (12 containers, healthy).

## Findings
### F1 — a stopped Docker daemon was reported `unattributable`, `fault: harness`, and overwrote STATUS.md's verified record
- **Evidence:** `runs/20261102T095346Z/attempt-1/verify.json` `"failed_stage": "preflight: docker daemon unreachable", "fault": "harness"`; its `report.md` says "Fix it in this repo" and "Attempts exhausted with the assertions still failing" after 1 of 2 attempts and 0 assertions; the lane had to `git checkout` STATUS.md.
- **Judgement:** a machine precondition read as a harness bug, and a run that asserted nothing replaced the record of one that did. #37 already added `fault: environment`; this preflight did not use it.
- **Disposition:** proposed — `verify.sh` preflight fails with `fault: environment`; `iterate.sh` maps an ownerless `environment` fault to `blocked`; `update_status` leaves STATUS.md alone on `blocked`; `ship.md`'s outcome table follows. Probed with `DOCKER_HOST=unix:///nonexistent.sock iterate.sh 0007-dev-environment --verify-only`: before, `unattributable` and STATUS.md rewritten; after, `blocked`, "STATUS.md left as it was".

### F2 — `/ship-iterate` § 4 says "full dispatch" and the lane routed around it with `--only`, third occurrence
- **Evidence:** `runs/20261102T153724Z/report.md` "first dispatch restricted to (`--only`): chatbot-backend"; friction log item 4. Earlier: `20260907T150124Z-ship-iterate-0006` R9 (backend dispatched twice to do nothing), `20260924T111021Z-ship-iterate-0007` R1 (slice re-dispatched whose brief said nothing changes).
- **Judgement:** the instruction buys a full agent session per unchanged slice, and the last two lanes either paid it or ignored it.
- **Disposition:** proposed — § 4 now says `--only <every slice whose brief changed>`; repair passes still follow `owners_failing`, and every verify asserts the whole suite.

## Recorded, not proposed
- **R1 — an amended criterion contradicted a baseline step, and a repair session was spent finding it.** Criterion 22 (chat root is CHAIN) against `the-graph-run-is-nested-under-it`; the backend agent said "control-repo criteria must change" in attempt 2 (`attempt-2/fanout.json`). First occurrence; nothing mechanical can detect semantic contradiction, and a sentence in § 1 would be the fix if it recurs.
- **R2 — a slice saying "control-repo criteria must change" is recorded as `failed`, not as its own outcome.** Same evidence. Analogous to `contract-gap`, but first occurrence.
- **R3 — every Phoenix step is `local`, so dev's Phoenix (criteria 21–23) is asserted only by hand.** Lane verified via `kubectl exec` and the API-key secret. The remote suite has no Phoenix credential; first time it hid a criterion.
- **R4 — criterion 24 (generated Mermaid diagram) is asserted only by a backend test that nothing in the loop reads.** Second occurrence of `20261023T112356Z-ship-0008` R1 (product PR CI not read before verified); a redesign of what "verified" reads, not a small fix.
- **R5 — `with-aws.sh` refused fresh hand-pasted keys because `AWS_CREDENTIAL_EXPIRATION` was stale.** `make login` fixed it; first occurrence.

## Rejected
- **`python3 scripts/check-docs.py` fails with no `yaml`.** The shebang and `make check` work; invoking it another way is not a harness defect.
- **The live Phoenix probe before writing steps as a new rule.** Already user memory; it worked.

## Not verified
- Dev's live state (no AWS read, per ADR 0018); product-repo PR CI for the four heads.

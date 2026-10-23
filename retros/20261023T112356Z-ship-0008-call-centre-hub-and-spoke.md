---
lane: ship
change: 0008-call-centre-hub-and-spoke
run: changes/0008-call-centre-hub-and-spoke/runs/20261023T110730Z
date: 2026-10-23
verdict: coherent-with-warnings
findings: 2 proposed, 9 recorded, 4 rejected
pr: pending
---

## State audit

- **Control repo** — on `feat/0008-call-centre-hub-and-spoke` @ `76c5e23`, = origin. Only ` M` gitlinks (submodules on feat heads); HEAD's gitlinks = `repos.lock`. `contracts/` last touched by `8a0b003` (contracts only), = `freeze_sha`, an ancestor of HEAD.
- **Submodules** — all four on `feat/0008-…`, local = origin, 0 uncommitted. Correct for `/ship`.
- **Contract against served** — harvested locally in `20261023T110730Z`: 0 gaps, 6 declared-never-observed 422s (the standing set plus `GET /v1/calls/{id}`). Not re-checked against dev.
- **Assertions** — local 116/0, 39 from the change suite; remote 77/0, 17 from the change suite.
- **Cloud** — `dev-push-39944596388/verify-remote.json`: `verified`, deploy set = the four PR heads as they stand. Earlier four red passes superseded.
- **Pull requests** — fetched: all four product PRs open at the deployed SHAs. **chatbot-backend#10 CI is red** (`integration`: `pull access denied for minio/minio`, both pushes, 2026-10-21 and 10-23). Others green.
- **Gates** — `check-docs` 29/0 (1 expected mid-change warning), `manifest --validate` 0, `test-hooks` 0, `make check` 0.
- **Stack** — joined local stack up (12 containers). `dev` up and billing.

## Findings

### F1 — an expired provider session was routed to `chatbot-eval` as a slice fault and burned a repair dispatch, sixth occurrence
- **Evidence:** `runs/20261021T124022Z/attempt-1/verify.json` — `fault: slice`, `owners_failing: [chatbot-eval]`, `configuration.chat_model: bedrock`; `backend.container.log` has 29 × `UnrecognizedClientException … security token … invalid`. Attempt-2 `fanout.json`: the eval agent answered "creds expired 2026-10-12 … Run make login". Same signature (`ExpiredTokenException`) in container logs of 0002, 0003, 0005, 0006 runs. `docs/adr/0017` § Accepted costs: "If it bites again *with* the reporting in place, the answer is a `fault: environment` class". Prior record: `20260907T150124Z-ship-iterate-0006` R6.
- **Judgement:** clears the bar; the ADR already decided the shape.
- **Change:** `verify.sh` finish(): after the failure dump, a slice fault whose container logs show `UnrecognizedClientException|ExpiredTokenException` becomes `fault: environment` with no owners; `iterate.sh` reports it as unattributable and dispatches nothing. One line each in `ship.md`'s outcome table and ADR 0017.
- **Would have caught:** probed against the recorded dumps — `0008/20261021T124022Z/attempt-1`, `0006/20260903T134830Z/attempt-1`, `0005/20260901T112951Z/attempt-1` all flip to `environment`; 0008's genuine failures (`20261021T134210Z/attempt-2`, `20261021T134644Z`) stay `slice`.
- **Disposition:** proposed.

### F2 — a slice reported its own gate broken and `report.md` said "all slices reported OK"
- **Evidence:** `runs/20261023T110730Z/attempt-1/fanout.json` chatbot-backend reason: "gate.sh is broken (exits 0 early) and needs a manual fix." `report.md` there: "all slices reported OK", 0 mentions of `gate.sh`; the friction log does not mention it either. Same pattern: infra's "Bootstrap re-apply needed" (`20261021T124022Z/attempt-1`) and eval's "creds expired" (attempt-2) reached no report. The defect is real: `chatbot-backend/.claude/hooks/gate.sh` @ `3e6f6d3` (on PR #10's branch) exits 0 at line 16, before ruff/mypy/pytest.
- **Judgement:** evidence produced and never read (Q4).
- **Change:** `iterate.sh` prints one line per slice — repo, status, summary — under each dispatch line.
- **Would have caught:** `report.md` for `20261023T110730Z` would carry the `gate.sh is broken` line the lane read.
- **Disposition:** proposed.

## Recorded, not proposed

- **R1 — nothing reads product-repo PR CI before the lane declares verified.** chatbot-backend#10 `integration` red on both pushes (external `minio/minio` pull denial); `STATUS.md` CI column all ☐. First occurrence.
- **R2 — `git commit -a` swept four feat-branch gitlinks into the control branch; only CI's `deploy-set.py` refused, ~1 min later.** Caught by a mechanism; cost small. First occurrence.
- **R3 — `make creds` says "bedrock: ready" for an expired session.** It checks names, not validity; F1 covers the cost. ADR 0017 forbids reading the values here.
- **R4 — `new-change.sh` scaffolds no `chatbot-eval.md` slice template.** First occurrence.
- **R5 — two more hand-kept service lists (`stack.sh`, `failure-brief.py` SERVICES) edited on the change branch.** `check-docs` caught both, so the gate works; they ride in the change PR, not a harness PR.
- **R6 — a killed `iterate.sh` reports "died before reporting (exit 0)".** Misleading after a deliberate kill.
- **R7 — attempts share a warm stack (`--keep-up` between attempts), which a suite author read as ADR 0011's "forgets everything".** By design; prose could say so.
- **R8 — `iterate.sh --only` help does not say whether the first dispatch carries the previous run's failure brief.**
- **R9 — `BUDGET_EMAIL` needed by `make dev-bootstrap` is undocumented in the lane.**

## Rejected

- **A local gate for compose ≠ k8s seams (IAM, probe shape).** Three ~20-min red applies, but `docs/adr/0004` accepts "a green run is not an infrastructure audit"; the fix was in the briefs.
- **The auto-mode classifier refusing `gh pr merge` on #35.** Previously rejected (`20261012T083322Z-realign-0007`); permission setup, not harness.
- **A `now` variable in `smoke.py`.** The workaround held; no defect.
- **Anything about the 422s, the `[vendored-contracts]` warning, or the stack left up.** Standing, previously decided.

## Not verified

- Live `dev` state and cost — needs AWS credentials.
- `iterate.sh` changes end-to-end — exercising it dispatches agents; the snippets were probed against recorded run dirs instead.

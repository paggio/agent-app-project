---
lane: realign
change: 0008-call-centre-hub-and-spoke
run: none
date: 2026-11-05
verdict: coherent-with-warnings
findings: 2 proposed, 5 recorded, 3 rejected
pr: none
---

## State audit

- **Control repo:** clean on `chore/realign-0008-call-centre-hub-and-spoke` @ `34f62bf`; `contracts/` unchanged since the freeze `8a0b003` (contracts only), `freeze_sha` in `change.yaml:6` only.
- **Submodules:** all four on `main` at `479e591`/`97fb443`/`888fa0f`/`1e3202f`, matching `repos.lock`, 0 uncommitted — what `/realign` should leave.
- **Contract against what is served:** re-run by this retro, `harvest-contract.py --diff` against `localhost:8000` exit 0; the same six framework 422s, nothing else.
- **Assertions:** remote 76/0 (`runs/dev-push-42053598184/run/verify-remote.json`), 0 from a change suite, as expected for a realign. Local 103/0 is the lane's claim; no file records it.
- **The cloud:** `/dev-push` 42053598184 `verified`, trigger ref `34f62bf` = PR #40 head, every repo built at its gitlink, gitlinks = the lock. `/dev-eval` 42055304392 passed (PR comment). Both started by the lane as PR comments, per `realign.md` § 5b. `dev` is up and billing.
- **Pull requests:** PR #40 open, body carries both verdicts and run URLs (fetched). Product PRs merged per `STATUS.md`; not re-fetched.
- **Gates:** `check-docs` (30 passed, 1 known warning), `manifest --validate`, `test-hooks` green now; `make check` exit 0 on this branch.

## Findings

### F1 — `retro-evidence.sh` § 4 showed a realign's stale feat-branch deploy as "latest", because `/realign`'s `dev-push --lock` lands in `runs/` and a named change made the bundle read `changes/<change>/runs/`
- **Evidence:** bundle § 4 printed `changes/0008-…/runs/dev-push-41817426510` (backend `2182d09d8889`, `feat/0008…`, "= local feat head") as the remote pass. The realign's actual pass is `runs/dev-push-42053598184` (backend `479e59105f75`, `from: gitlink`), which the bundle never mentioned. `scripts/dev-push.sh:14` says `--lock` lands in `runs/`; `retro-evidence.sh:284` picked the change dir whenever `--change` was given. And `from: gitlink` entries were printed with no comparison at all.
- **Judgement:** the bundle is the retro's only grounded claim about the cloud, and in this run it pointed at the pre-merge images — exactly the "stale deploy read as shipped" § 2 asks the retro to catch, but inverted: it hid the right one.
- **Disposition:** proposed — `realign` reads `runs/`; each `gitlink` entry is compared with `HEAD:<repo>` (`= this branch's gitlink` / `≠ … not the pin under review`). Run on `origin/main` it prints `≠` for all four (main still pins the pre-bump SHAs); on the realign branch the gitlinks equal the deployed SHAs.

### F2 — the retro agent asks whether `/realign` "left `/dev-push` to the user", while `realign.md` § 5b tells the lane to run it
- **Evidence:** `.claude/agents/harness-retro.md:74` vs `.claude/commands/realign.md` § 5b (`dev-push.sh --lock --pr`, `dev-eval.sh --pr`, "The user is asked to review only once both are green"). PR #33 moved the deploy to the lane; the retro line predates it.
- **Judgement:** a retro following its own audit line would grade a correct lane as having overstepped.
- **Disposition:** proposed — one line, aligned with § 5b.

## Recorded, not proposed

- **R1 — nothing states or checks that `SMOKE_RUN_ID` is alphanumeric, and promoted 0008 steps build `CALL-SMOKE${SMOKE_RUN_ID}` against `^CALL-[0-9A-Za-z]{6,48}$`.** `make smoke`'s `make-<pid>` made the worker refuse every smoke event; the post-promotion `make restart && make smoke` caught it (the gate fired), fixed at its cause in #39. `verify.sh`/`verify-remote.sh` ids are alphanumeric by accident. First occurrence.
- **R2 — promotion is described as "move", but dropping a step forced rewriting a dependent one.** `the-transcript-keeps-each-turns-route` went from four routes to three when `a-queue-question-cites-only-that-queue` stayed behind. Coherent, not a weakening; `realign.md` § 5 does not mention it. First occurrence.
- **R3 — `/realign` still writes no run artifact; the 103/0 local baseline and the harvest result exist only in the lane's words.** At least the fifth occurrence (realign 0006 retros R1, third and fourth; re-raising it as a diff was rejected there). Same disposition.
- **R4 — `STATUS.md` § "Remote — `verified`" still cites the feat-branch deploy 41817426510, and § "Merged" omits the realign's 42053598184 / dev-eval 42055304392** (they are only in PR #40's body; STATUS cannot cite a deploy of its own commit without moving the head). The § Remote line also carries two dates (`(2026-11-04) (2026-11-02, …)`). Change artifact.
- **R5 — the bundle does not read `runs/dev-eval-*` at all.** The realign's eval verdict is in evidence only via PR comment. First occurrence.

## Rejected

- **`gh pr edit --body-file` GraphQL error.** GitHub-side; the `gh api` PATCH workaround is fine.
- **Foreground `sleep` blocked.** Environment; the background until-loop is the intended route.
- **The six never-observed 422s, the `[vendored-contracts]` warning, the stack left up.** Decided before; nothing new.

## Not verified

- Product PRs' merged state and CI were not re-fetched; taken from `STATUS.md`.
- That the running local stack's images were built from the lock SHAs — the containers were created 54 min before the bundle, consistent with the lane's `make restart`.
- `dev`'s live state: no AWS read, by design (ADR 0018).

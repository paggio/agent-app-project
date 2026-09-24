---
lane: ship-iterate
change: 0007-dev-environment
run: changes/0007-dev-environment/runs/20260924T103206Z
date: 2026-09-24
verdict: coherent-with-warnings
findings: 2 proposed, 7 recorded, 4 rejected
pr: https://github.com/paggio/agent-app-project/pull/31
---

## State audit

- **Control repo** — on `feat/0007-dev-environment` at `33f3794`, equal to `origin`; ` M frontend`, ` M infra` are gitlinks at the lock with the worktrees on the slice branches, as `/ship` leaves them. `bf2a6b8` touches `contracts/infra-outputs.yaml` alone; its SHA is in `change.yaml` and `STATUS.md` names only the short form.
- **Submodules** — backend and eval on `main` at the lock; frontend `e7a092a`, infra `611df58` on `feat/0007-dev-environment`, no uncommitted files.
- **Contract against what is served** — local `attempt-1/harvest.log` ran: no gap, the five declared-never-observed 422s again. Not re-checked on `dev`.
- **Assertions** — local 71/0, only 2 from the change suite; remote 60/0, 10 from the change suite.
- **Cloud** — `dev-push-35988704468/run/verify-remote.json`: `verified`, deploy set frontend `e7a092a`, infra `611df58` = PR heads now (frontend#8, infra#1, fetched). `dev` up on purpose per the lane; not verified from here.
- **Pull requests** — `prs.json` records #24, frontend#8, infra#1; heads fetched with `gh`.
- **Gates** — `manifest.py --validate` 0, `test-hooks.py` 0; `check-docs.py` exit 1 on the lane's tree (F1, plus `chatbot-eval/contracts/infra-outputs.yaml` behind the re-freeze — the `/realign` catch-up).

## Findings

### F1 — `check-docs.py` reads forked sessions' worktrees under `.claude/worktrees/`, so `make check` failed 60 times over files this tree does not own
- **Evidence:** `retro-evidence.sh` § 5 on this lane: `[dead-wiring]` and `[commands]` failures, all under `.claude/worktrees/agent-a5f09b0393ce04d29/` and `agent-a6360c65bf5eee3c9/` (the forks behind #30 and #29, still locked). `prose_files()` globs `.claude/**/*.md` recursively.
- **Judgement:** a gate that fails for a reason nobody can fix from the tree is a gate the next person learns to ignore; it also blocked this retrospective's own `make check`.
- **Disposition:** proposed — `prose_files()` drops `.claude/worktrees/`. `check-docs.py` exit 1 before, 0 after, same tree.

### F2 — `vendor-contracts.sh` never publishes `infra-outputs.yaml` to infra, and infra's own contract test SKIPS green without it
- **Evidence:** `attempt-1/infra.log:14`: "vendor-contracts: nothing to publish … Without `infra-outputs.yaml`, the repo's contract check skips itself"; `infra/tests/contract.sh` exits 0 on a missing file; `vendor-contracts.sh` published only files already present. ADR 0008: "A frozen contract reaches every consumer that verifies against it".
- **Judgement:** protection claimed and never invoked (question 6). infra is the producer of this contract and its CI never compared against it.
- **Disposition:** proposed — also publish a file the repo names outside `contracts/` (`git grep`). `--check` now reports `infra/contracts/infra-outputs.yaml is missing, and infra reads it` and exits 1; before, it reported every copy matching. No other repo changes: backend and frontend do not name it, eval already vendors it.

## Recorded, not proposed

- **R1 — `/ship-iterate` re-dispatched a slice whose amended brief says "nothing in this slice changes", second occurrence.** `frontend.md:3`; a full agent session for `ok, no new commits`. First: `20260907T150124Z` R9. Proposable now; held back under the cap, and R9's argument (a repo's "nothing to do" is a claim) still deserves a reply rather than a sentence in §4.
- **R2 — `/ship-iterate` has no route for an amendment that asks for control-repo harness work.** The lane split it into #30/#29 by judgement; right result, no instruction. Related to `20260902T102422Z-ship-iterate` R1 and `20260910T163100Z` R7, which were the same work landing on the change branch instead.
- **R3 — a bootstrap change on a slice branch is invisible to the remote pass.** infra `bootstrap/deployer.tf` +11 between `0742451` and `611df58`; `dev-push` deploys `envs/dev` only, so the deployer role in AWS lags the branch silently and criterion 10 fell back to `--judge heuristic`. First occurrence.
- **R4 — a harness PR (#30) had to merge before a change criterion could be proved,** because the eval workflow is `issue_comment`-triggered and runs from `main`. Same shape as the accepted cost in `docs/adr/0018`; recorded, not argued.
- **R5 — an upstream Bedrock outage reads as a breach** (run 35989985453). The backend's bare 500 on `ServiceUnavailableException` is a chatbot-backend slice, as `STATUS.md` already says.
- **R6 — `STATUS.md` carries two remote records that disagree:** the amendment's (`35988704468`, infra `611df58`) and a stale § "Remote — verified" and PR table (infra `0742451`, `35900953903`). Change artifact, not harness.
- **R7 — the `INFRA_*` exemption in smoke interpolation is known only from reading `smoke.py`/`check-docs.py`.** One lookup, first occurrence.

## Rejected

- **`retro-evidence.sh` picking `dev-push-*` as "the run".** It did on the lane's branch; `origin/main` already globs `[0-9]*` (#30).
- **`fanout.json` "has no per-slice status".** It does, at `repos.<slice>.status`; the parse was wrong.
- **The distroless `printenv` probe.** Operator error, not harness.
- **Anything about the five 422s or the vendored `contracts/README.md` warning.** Decided in earlier retros.

## Not verified

- `dev` is up and serving — needs AWS credentials.
- Whether the deployer's `bedrock:InvokeModel` has been applied — needs `make -C infra bootstrap` output or IAM read.
- The contract against what `dev` serves — no remote harvest exists.

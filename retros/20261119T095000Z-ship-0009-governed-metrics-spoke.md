---
lane: ship
change: 0009-governed-metrics-spoke
run: changes/0009-governed-metrics-spoke/runs/20261119T091127Z
date: 2026-11-19
verdict: coherent-with-warnings
findings: 2 proposed, 9 recorded, 4 rejected
pr: none
---

## State audit

- **Control repo** — not clean: `.gitignore` carries an uncommitted `tmp/` entry. HEAD gitlinks equal `repos.lock` (reverted in 2b561c9); the ` M <repo>` lines are worktree pointers on feature branches, expected after `/ship`.
- **Contracts** — last commit 9508c3f touches `contracts/mcp/metrics-gateway.json` alone; `freeze_sha` is in `change.yaml:8` and nowhere else on the branch.
- **Submodules** — all six on `feat/0009-governed-metrics-spoke`, each equal to the head `/dev-push` 44498487651 built.
- **Contract against what is served** — harvest pass in 20261119T091127Z (six declared-never-observed 422s, as every lane since 0004). Gateway MCP contract not harvested; asserted by smoke steps only.
- **Assertions** — local 142/0 (26 from the change). Remote 82/0, 6 from the change: four are setup, two are substantive (`the-deployed-spoke-cites-gmv`, `a-coding-question-does-not-route-to-metrics`). Twenty change steps are `local` because the gateway has no origin on dev.
- **The cloud** — `verified` in `verify-remote.json` of 44498487651; deploy set equals every PR head as it stands now. Dev is up and billing.
- **Pull requests** — `prs.json` records all seven as existing; not re-fetched here.
- **Gates** — `check-docs.py`, `manifest.py --validate`, `test-hooks.py` green now.
- **Incident caused by this retro** — probing `dev-push.sh` on the retro branch, the agent ran `rm -rf changes/0009-governed-metrics-spoke` believing it had just created it; the gitignored `runs/` survived the branch switch and was deleted. The four `dev-push-*` evidence sets were re-downloaded from Actions; the five local iterate runs are lost apart from what `retro-evidence.sh` captured.

## Findings

### F1 — `dev-push.sh` waits two hours on a run GitHub holds for approval, because it marks the held run "seen" and approval re-runs the same id
- **Evidence:** `gh run view 44489379590` → `attempt: 2`; `44339415359` → `status: completed, conclusion: action_required`, created = updated, zero jobs. `dev-push.sh` adds every candidate to `SEEN` before reading its artifact; a held run has none, so it is dropped, and after approval it is never looked at again. Friction log item 20: one wait "waited indefinitely"; the user approved by hand.
- **Judgement:** clears the bar — observed twice in this lane, and a silent wait is a pass-by-silence in the deploy path.
- **Disposition:** proposed — a held run is named once with its URL and revisited until it is approved. Probe with a stubbed `gh`: the `origin/main` script was killed after 40 s still waiting; the fixed one reports the hold and returns `verified` once the stub approves.

### F2 — a control commit with gitlinks off `repos.lock` is caught only by CI's `deploy-set.py`, second occurrence
- **Evidence:** 892a3e8 committed six feat-branch gitlinks; `/dev-push` 44489379590 refused at resolve, in CI, after a manual approval. First occurrence: `retros/20261023T112356Z-ship-0008-call-centre-hub-and-spoke.md` R2.
- **Judgement:** second occurrence, so it is proposable. The check already exists and is right; it just runs late.
- **Disposition:** proposed — `dev-push.sh` (change mode) fetches `feat/<change>` and runs `deploy-set.py --change` locally before commenting, which also catches an unpushed slice branch. Probe: at 892a3e8 the `origin/main` script commented; the fixed one exits 2 with the drift and posts no comment. At the pushed head it passes.

## Recorded, not proposed

- **R1 — `iterate.sh --only` publishes contracts only to the dispatched repos, while verify's preflight checks every slice; run 2 refused `chatbot-backend`.** Friction 11; worked around by re-dispatching. First occurrence.
- **R2 — a remote failure has no route into a repair brief; the lane hand-appended "Remote failure" to `infra.md` before `iterate --only infra`.** Friction 23. The failed Job's pod left no log in the evidence; the cause was found only in the RDS server log. First occurrence.
- **R3 — `BUDGET_EMAIL` for `make dev-bootstrap` has no default and no lane mention, second occurrence (0008 ship R9).** Proposable, not proposed: the requirement lives in `infra/`, so the fix is an infra slice or a `stack/dev.env` declaration, and two findings were enough for this PR.
- **R4 — quoted values in hand-pasted `secrets.env`: compose strips the quotes, `with-aws.sh` and `push-gh-creds` do not, and `make creds` says "set".** Friction 18. Same class as 0008 ship R3 and 0008 ship-iterate R5 (hand-pasted credentials, `make creds` blind to them). Next time, propose stripping the quotes in the two readers.
- **R5 — `dev-push.sh` reportedly exited 0 on a `gh` network error with no verdict.** Testimony only, not reproduced. From the code, `set -e` exits on the `gh run list` substitution with gh's status (1), not 2: the exit code is wrong either way.
- **R6 — `ship.md` does not say how to bring harness fixes into a change branch mid-flight; rebasing orphans `freeze_sha`, so the lane merged `main` in twice.** Friction 16. First occurrence.
- **R7 — `make config` fails until every new repo's compose file exists, so nothing can check the stack wiring before dispatch.** Friction 7. First occurrence.
- **R8 — `STATUS.md` § Blockers still says "Before `/dev-push`: `make dev-bootstrap` — human" after `verified`.** Coherence, the lane's to fix.
- **R9 — the change is asserted on dev by two substantive steps; the gateway, Trino, Glue and the indexer Job on dev are reached only through one routed chat.** The `local` tags are honest (no origin on dev). The thin remote coverage should be named in the PR body, not presented as 82.

## Rejected

- **`gh-setup` HTTP 422 on a public repo's access policy.** Harmless noise.
- **`[provider-credentials]` refusing `AWS_*` in compose.** The gate fired as designed; the precedent is in its message.
- **Auto-mode classifier refusing `gh pr merge` / the approve API.** Already rejected in 0007 realign and 0008 ship.
- **A job → assert → job ordering in smoke (friction 5).** A redesign of ADR 0014's jobs-before-smoke; the three-release sequence encoded it.

## Not verified

- `prs.json` URLs and product PR CI state: not re-fetched.
- Whether dev's resources match the deploy set beyond `verify-remote.json`: no AWS read (ADR 0018).
- The original contents of the five local runs under `runs/2026111*`: deleted by this retro (see the audit).

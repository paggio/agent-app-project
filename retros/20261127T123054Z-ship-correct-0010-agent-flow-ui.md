---
lane: ship-correct
change: 0010-agent-flow-ui
run: changes/0010-agent-flow-ui/runs/20261127T115933Z
date: 2026-11-27
verdict: coherent-with-warnings
findings: 0 proposed, 6 recorded, 3 rejected
pr: https://github.com/paggio/agent-app-project/pull/54
---

## State audit

- **Control repo** — `feat/0010-agent-flow-ui` @ `c2f8d58`. Dirty: ` M .gitignore` (`tmp/`, personal) and three feat gitlinks, uncommitted (correct). `contracts/` alone in `76ac577` = `freeze_sha`, an ancestor of HEAD after the `origin/main` merge; second copy still at `STATUS.md:6` (written before #52's template fix).
- **Submodules** — chatbot-backend `05f6f0f`, frontend `ed07d5b`, infra `e41593c` on `feat/0010-agent-flow-ui`; the other three on `main` at `repos.lock`. Right for a ship lane.
- **Contract** — harvested this run (`attempt-1/harvest.log`): no drift, the six framework 422s.
- **Assertions** — local 128/0 (17 change suite), e2e pass, seed pass; remote 99/0 (17 change suite).
- **Cloud** — `dev-push-45995285787/run/verify-remote.json` `verified`; deploy set = PR heads as fetched now (#12 `05f6f0f`, #11 `ed07d5b`, #6 `e41593c`).
- **Pull requests** — `prs.json` matches `gh`: control #53 created, product PRs OPEN, MERGEABLE, CI green. STATUS CI column still ☐.
- **Gates** — `check-docs.py` exit 1 on the change branch (`chatbot-eval/contracts/openapi.yaml` ≠ 1.9.0, 0010 ship R6); manifest, test-hooks green. `make check` green on this branch (from `origin/main`).
- **Stack** — local stack up; gateway healthz serves both projects. Dev up, per the lane.

## Findings

None cleared the bar. The cause (a cold gateway) was fixed in the harness, shown failing in the `/ship` run and passing here.

## Recorded, not proposed

- **R1 — the new CLAUDE.md clause lets a blocked lane merge the one open `harness/` PR, which bundles other retros' unreviewed proposals.** #52 carried `864a467` (0009 realign retro) and `30243ea` (0010 ship retro) beside the seed. User-authorised this time; the clause generalises it. A policy call for the user, not a diff.
- **R2 — `[claude-md-size]` counts lines, so a rule folded into an existing bullet passes.** `CLAUDE.md:26` is 222 chars; table rows were already 175–239. First occurrence; length is not what the budget has caught.
- **R3 — bringing a harness fix into a change branch mid-flight has no instruction; second occurrence** (0009 ship R6). Lane merged `origin/main`, freeze survived. Not proposed: both lanes got it right, so nothing is yet caught by writing it down; CLAUDE.md is at 60.
- **R4 — a change branch based on an open realign PR carries its diff; second occurrence** (0010 ship R7). #53 shows 0009's STATUS, baseline, lock and gitlinks until #51 merges. A stacked base would merge into the realign branch if it is not deleted — no clean fix; merge #51.
- **R5 — `/ship-correct` phase 1 names no "assertion right, harness the cause" shape, and its `make verify` instruction differs from `iterate.sh --verify-only`, which also opens PRs.** Friction 6–7. Handled correctly; first occurrence.
- **R6 — the stale baseline comment ("The local stack runs no release Job, so locally only the routing guard holds") lives only on #51.** Now false locally. Content fix on #51 or after it.

## Rejected

- **`verify.sh` jobs-loop watchdog without `wait "$j_dog"` may print "Terminated: 15".** Log noise; style.
- **`SEEDS` as data under `smoke/` or `stack/`.** One list, one consumer, no second seed yet — speculative.
- **Remote 99 vs local 128.** `local` tags, accepted (0009 ship R9).

## Not verified

- The seed stage's failure routing — never seen failing; would need a broken `dbt-release` image.
- Dev's live state — no AWS read (ADR 0018).

---
lane: realign
change: 0007-dev-environment
run: changes/0007-dev-environment/runs/20260924T103206Z
date: 2026-10-12
verdict: coherent-with-warnings
findings: 1 proposed, 7 recorded, 3 rejected
pr: none
---

## State audit

- **Control repo** — clean on `chore/realign-0007` at `a8d8254` = `origin/chore/realign-0007`. `contracts/` untouched since `bf2a6b8`; that SHA is also quoted in `STATUS.md:6` (prose, earlier lane).
- **Submodules** — all four on `main`, each equal to its `origin/main` and to `repos.lock` (backend `7bf1af6`, eval `1fe285b`, frontend `103e58e`, infra `2afe929`). Right for `/realign`.
- **Contract vs served** — not re-checked by me (stack down). Lane reports the harvest agrees bar the five declared-never-observed 422s; the bundle's recorded harvest is the 2026-09-24 run's.
- **Assertions** — lane reports 71/0 locally after `make restart`, 2 of them the promoted untagged steps; the other 8 promoted steps are `remote` and asserted nowhere yet. Not verified (Docker down).
- **Cloud** — not verified. Latest `verify-remote.json` (run 35988704468) deployed frontend `e7a092a`, infra `611df58` — feature heads, not the lock. #32 carries the `/dev-push` handoff comment; the only `dev-push` runs since are the lane's own 37955078229 (failed, expired session) and 37955216634 (cancelled mid-apply).
- **Pull requests** — #32 open, unmerged, head `a8d8254`, files: STATUS.md, three gitlinks, `repos.lock`, `smoke/baseline.yaml`. Fetched with `gh`.
- **Gates** — `check-docs.py` 0 (1 known warning), `manifest.py --validate` 0, `test-hooks.py` 0, `make check` 0, all against the tree as it stands.

## Findings

### `/realign` ran from a stale copy of itself and started a `dev` apply
- **Evidence:** root on `feat/0007-dev-environment` (`c5875b3`, merged as #24), which does not contain `origin/main` (`git merge-base --is-ancestor origin/main feat/0007-dev-environment` → 1). That branch's `realign.md:211` says `./scripts/dev-push.sh --lock --ref chore/realign-<change>`; `origin/main`'s, since `0d97eb1`, says hand the deploy to the user. Runs 37955078229, 37955216634; ~40 orphaned resources, `dev/terraform.tfstate.tflock` left behind.
- **Judgement:** the lane noticed `STATUS.md` disagreed and did not stop — prose judgement failed; a binary check would not have. Nothing in `realign.md` asked where the root was.
- **Disposition:** proposed — a first check in `realign.md`: `origin/main` must be an ancestor of HEAD and the branch `main` or `chore/realign-<change>`, else stop and rerun from `main`. Probed: exit 1 on `feat/0007-dev-environment`, exit 0 on `chore/realign-0007`. Only protects branches cut after it merges — inherent to a command file loaded from the working tree.

## Recorded, not proposed

- **R1 — `/ship` § 5b still tells the agent to run `./scripts/dev-push.sh <change>` itself, and the user has since decided agents never deploy `dev`.** `ship.md:148`, `iterate.sh:225`, `verify.sh:457`, `ship-correct.md:86`; ADR 0018 §3 decided "the lanes use it too". A redesign of an ADR decision — the user's call, argued in the report.
- **R2 — `STATUS.md` says "`dev`: not deployed by this lane" and omits the two runs it started, the cancelled apply and the orphan cleanup.** `289ff7f` (18:09) postdates run 37955216634 (15:54). Lane-specific record error, not a harness gap.
- **R3 — a cancelled apply leaves resources no state records, and `make dev-down` cannot see them.** Testimony plus runs above; the cleanup was a hand-written by-ID script. No smallest harness change identified (the kill is GitHub's force-cancel against terraform); infra's business if anyone's.
- **R4 — a realign that needs a small product-repo fix has no shape; the lane dispatched `claude -p` in `infra/` for infra#2.** Second occurrence of `retros/20260911T154844Z-realign-0006-chatbot-eval.md` R2. Proposable; left for a dedicated change because the shape is a decision (dispatch vs. a session the user starts), not a line.
- **R5 — the lane pinned twice because #31 merged mid-lane and made infra's vendored copy required.** § 2b worked as written; the cost was a second pin commit. No defect in the instructions.
- **R6 — `make check` cannot tell external drift in a product repo's CI (CRDs-catalog `b7e2015`) from the lane's breakage.** Product-repo concern; one occurrence.
- **R7 — the freeze SHA has a prose home in `STATUS.md:6`.** Third occurrence (0005 realign R2, 0006 realign R4); a gate is possible but this run did not write it.

## Rejected

- **`deployed-set.json` written before the apply succeeds.** Deliberate: `scripts/verify-remote.sh:285-289` — a failed rollout still owns state, and `dev-down` must destroy with that infra.
- **A confirmation prompt in `dev-push.sh`.** It is called non-interactively by lanes per ADR 0018 §3; the question is R1's, not a prompt's.
- **The auto-mode classifier refusing the § 2b merge.** The permission system, not the harness.

## Not verified

- `dev` empty, the tflock removed, `deployed-set.json` content — needs AWS credentials.
- The baseline at the lock, locally and through CloudFront — needs Docker, and the user's `/dev-push` on #32.
- infra#2's budget Region filter applied — needs `make bootstrap`.

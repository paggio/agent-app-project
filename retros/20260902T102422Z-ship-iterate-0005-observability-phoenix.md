---
lane: ship-iterate
change: 0005-observability-phoenix
run: changes/0005-observability-phoenix/runs/20260902T094706Z
date: 2026-09-02
verdict: coherent-with-warnings
findings: 2 proposed, 7 recorded, 3 rejected
pr: https://github.com/Paggio/agent-app-project/pull/14
---

One attempt, one slice, `verified-local`, 63 assertions, 18 from the change's own suite, and
a dispatch that reported a proper SLICE-RESULT block and left its stack down. The amendment
itself is the cleanest run in this repo's record: `manifest.py --validate` and
`check-docs.py` passed first try, no re-freeze was taken and the reasoning for not taking
one is written down, and the new `[clean-slate]` gate blocks in both directions — verified
again here, independently of the lane's testimony.

What the harness has to answer for is not in the run. It is that the change branch carries
harness surface — a new global gate in `scripts/check-docs.py`, a new verb in
`scripts/stack.sh`, the first change-specific script ever added to that directory — and that
`git merge-tree` now reports a content conflict in both of those files between
`feat/0005-observability-phoenix` and the open harness branch. `CLAUDE.md` forbids exactly
this in prose and nothing mechanised it. It is recorded rather than proposed, because a gate
that refused it would have refused work the harness offers no other home for; that home is
R9's undecided question, and this is its third appearance.

This retrospective commits onto the branch of the one already open (#14) rather than opening
a second, per the one-open-PR cap.

## State audit

- **Control repo** — clean tree on `feat/0005-observability-phoenix` at `fb18361`, submodule
  pointers included. `contracts/` unchanged against HEAD; `dfbb48f` is `contracts/README.md`
  alone (`git show --stat`) and is an ancestor of HEAD.
- **Freeze recorded** — `change.yaml:8` carries `dfbb48f8…`; `STATUS.md:5` carries the same
  40 characters, and `BRIEF.md:158`/`STATUS.md:27` the short form in prose. Fourth occurrence
  of R5/20260826 → R7/20260901. They agree today. No re-freeze was taken, correctly: the
  amendment moves no interface.
- **Submodules** — `chatbot-backend` `24fb295` on `feat/0005-observability-phoenix`, clean,
  ahead of `repos.lock` (`4a80a99`); `frontend` `d9b76a8` and `infra` `6eebe0a` on `main`
  matching the lock. That is what a `/ship`-family lane should leave.
- **Contract against what is served** — re-checked in this lane.
  `runs/20260902T094706Z/attempt-1/harvest.log`: additive only, the same five paths returning
  an undeclared `422` carried since 0004. No breaking drift.
- **Assertions** — 63 passed, 0 failed, 18 from the change's own suite (10 before the
  amendment). Not thin: the five new steps assert one HTTP span per request, `user.id`,
  `session.id`, `input.value`, the seeded account signing in, and no credential anywhere in
  the project. Seven of the eighteen criteria are asserted outside the seam and `BRIEF.md`
  § "A gap in the oracle" says where — see R3.
- **The cloud** — nothing reached a remote environment. `verify.json` records
  `environment: null`, `remote_asserted: false`, `infra: "skipped: deploy.infra=false"`, and
  the report is labelled `verified-local`. Read as `verified-local`, not as shipped.
- **Pull requests** — chatbot-backend#8 is a fact in `prs.json` and confirmed `OPEN` here
  with `static` and `integration` `SUCCESS`. agent-app-project#13 is `OPEN` with `docs` and
  `manifests` `SUCCESS` and is **absent from `prs.json`** for the third lane running — F1
  below. Both report `mergeable: MERGEABLE` against `main` individually, and conflict with
  each other — R1.
- **Gates, re-run now** — `check-docs.py` exit 0 (15 checks, one known permanent warning);
  `manifest.py changes/0005-observability-phoenix --validate` exit 0; `test-hooks.py` exit 0
  in both directions; `make check` green on `harness/retro-20260901T120000Z`, including both
  product repos' lint and typecheck with the submodules on their feature branches — F1 of
  20260901 is holding. `[clean-slate]`, the gate this change added, probed here: exit 1
  naming `phoenix-db` on a host bind mount, exit 0 once reverted, `git status` clean after.
- **The stack** — **up** when the evidence was collected, Phoenix restarted two minutes
  earlier, i.e. left by the lane's out-of-band `make phoenix-durability`. Third occurrence of
  R8/20260826.
- **Not verified** — anything in a remote environment; there is none. The out-of-band results
  in `STATUS.md` (`make phoenix-durability`, the backend's 315 tests, the trace read by hand)
  are the lane's testimony and were not re-run here. That is R3.

## Findings

### F1 — `prs.sh --create` still opens PRs for slices only, so `prs.json` records half of every change

- **Evidence:** `scripts/prs.sh:77` iterated `$CHANGE_SLICES`, while `--list` at `:46`
  iterates `. $REPOS` and carries the comment saying why: "a change has a half here too —
  the freeze, the plan, the smoke criteria — and omitting it is how change 0002's half sat
  merged into a dead-end branch for four days". `runs/20260902T094706Z/prs.json` is
  `{"ok": true, "repos": {"chatbot-backend": …}}` with agent-app-project#13 open and unnamed.
  Reproduced today with `--dry-run` on the change branch: one repo out, `ok: true`.
  Second occurrence of R11/20260827, third of R8/20260901 — recorded twice, never proposed.
- **Judgement:** `prs.json` is the artifact this retrospective's own § 2 treats as fact
  against `fanout.json`'s claim, and it has been structurally incomplete since 0004. The
  reason 20260901 gave for not proposing was that a fix "puts a `git push` in a loop that
  touches no remote except through `prs.sh`" — but `prs.sh` is where the pushes already
  happen (`:112`), for slices. The residual worry was the control-repo branch: nothing in
  the harness creates `feat/<change>` here, so a target that assumed it would start failing
  lanes that kept the control half elsewhere.
- **Disposition:** proposed. The control repo joins the loop **only when this repo is already
  on `feat/<change>`**; when it is not, the target list and the exit code are exactly what
  they were. Shown both ways: before, `prs.json` has one repo; after, it has
  `agent-app-project → #13` and `chatbot-backend → #8`, both `existing`, no writes (dry run).
  Probed for the no-op case against `0004-rag-knowledge-base` from a branch that is not
  `feat/0004-…`: no control-repo entry, `rc=1` from the two slices exactly as before.
  What it would have caught: #13 would be in `prs.json`, and the lane would not have pushed
  and opened it by hand for the second lane running.

### F2 — `/ship-iterate` gave no honest answer for an amendment that removes nothing, and nothing told it to reverse the old slice's absolutes

- **Evidence:** `.claude/commands/ship-iterate.md` § 1 step 3 said only "say what to
  **remove**, explicitly". Every item in this amendment was additive or a parameter flip, so
  the honest answer was "nothing", which reads as the instruction skipped; the lane invented
  `changes/0005-observability-phoenix/chatbot-backend.md:19` — "**Nothing is removed.**" — to
  make the absence deliberate. Separately, the real hazard of the amendment was two rules the
  *first* slice stated absolutely — "any change to `auth/` … out of scope" and "redaction …
  Not here" — both of which the amendment required. The command says nothing about that
  shape, and the lane invented the banner at `chatbot-backend.md:3-21` to name both reversals
  before the old text is reached.
- **Judgement:** a prose defect in prose's own territory. Nothing here "must not happen" in
  the hook sense, and no gate can read a slice file for self-contradiction — the reversal is
  legitimate, it is the *silence* that is not. Two work-arounds invented in one lane, on one
  file that is now on its second version and will get a third, is not tidiness.
- **Disposition:** proposed. Step 3 gains two sentences: a purely additive amendment is a
  normal shape and says so, and where the amendment reverses something the old text forbade
  absolutely it is named at the top before the old text is reached. What it would have caught:
  the next amending lane writes the banner because it was asked to, rather than because it
  happened to notice — and a dispatched agent stops being able to choose which of two
  contradicting sections it believes.

## Recorded, not proposed

- **R1 — the change branch carries harness surface, and the two open PRs now conflict.**
  `git diff --stat origin/main...feat/0005-observability-phoenix` includes
  `scripts/check-docs.py +58` (the new global `[clean-slate]` gate), `scripts/stack.sh`,
  `Makefile`, ADR 0011 and a change-specific `phoenix-durability.sh` — which
  `git log --diff-filter=A` shows is the **only** script under `scripts/` ever added by a
  change commit rather than a harness commit. `CLAUDE.md` says "Harness fixes arrive as a PR from
  `harness-retro` … Never slip one into a change", and the lane's friction log does not
  mention the rule, which is the strongest evidence that it did not read as applying.
  The price is now concrete: `git merge-tree origin/harness/retro-20260901T120000Z
  origin/feat/0005-observability-phoenix` → `CONFLICT (content)` in `scripts/check-docs.py`
  and `scripts/stack.sh`, because both branches add a check function after
  `report_readme_divergence` and a line to the same `checks` tuple. Not proposed: a gate
  refusing harness paths on a change branch would have refused `stack.sh`'s `restart` verb
  and the durability script too, and the harness offers those no other home — that is R3.
  It would also turn the user's open #13 red on merge. The rule needs a boundary a human
  draws, not one this retrospective invents.
- **R2 — `stack.sh`'s SERVICES is still short by three.** `scripts/stack.sh:24` on the change
  branch is `(backend postgres redis phoenix frontend proxy)` against a nine-service
  `stack/compose.yml`. Already covered by F3 of 20260901, in the open PR; noted only because
  once both land the new `[stack-services]` gate will require `opensearch`, `minio` and
  `phoenix-db` here and `phoenix`/`phoenix-db` in `failure-brief.py`. That is the gate
  working, and it is a conflict to resolve rather than a finding.
- **R3 — a change's out-of-band oracle still lands in `scripts/` and nothing runs it.**
  Third appearance: F2/20260827, R9/20260901, here. `STATUS.md` § "Out-of-band checks" carries
  four PASS rows for criteria 12–18 — `make phoenix-durability`, the backend's 315 tests, a
  trace read by hand — as prose the lane wrote. It re-ran them, and the artifact cannot
  distinguish that from a copy-paste of the previous version's numbers. The lane says so
  itself. Still not proposed: letting `change.yaml` declare commands the loop runs and counts
  is a capability with an ADR's worth of consequence, 20260901 asked for it to be decided
  rather than met again, and the human has not answered — #14 is still unmerged. Proposing it
  now would be smuggling the argument in as a diff. It is the single most valuable thing a
  human could decide about this harness right now.
- **R4 — `CHAT_MODEL=echo` is a thing a human must remember on every run.** Second lane
  running; R11/20260901 recorded it. `stack/dev.env` leaves `CHAT_MODEL` undeclared on
  purpose (ADR 0006 layer 3), the Bedrock credentials in `chatbot-backend/.env` are expired,
  so a plain run 500s every model-bearing step in `smoke/baseline.yaml` as much as in the
  change's suite. Not proposed, and 20260901's reason still holds: the design is sound and
  documented, and a preflight credential probe is a new network call in the loop. What has
  changed is only that it is now unmistakably a standing tax rather than one bad afternoon —
  the next occurrence should propose something, and the cheapest candidate is not a probe but
  recording the model in effect and its layer in `verify.json`, so a reader of the run can
  tell which one it was.
- **R5 — nothing in the lane distinguishes "make X true" from "make X guaranteed".** The
  clean-slate item was a request to verify and entrench a property, not to repair one, and
  the two need opposite first moves: the lane measured first — 33 traces, `make down &&
  make up`, project gone — and had it assumed the property was broken it would have "fixed"
  working code. `/ship-iterate`'s opening ("a change of mind, not a bug report") splits the
  wrong pair. One sentence would cover it; it is left out of F2 deliberately, because F2 is
  already two sentences in a 90-line file and the third has cost nothing yet.
- **R7 — `[dead-wiring]` reads `retros/` as live documentation, and a retrospective cites
  the branch it audited.** Writing this file failed `make check` twice: `check-docs.py:216`
  and `:219` scan every prose file for `scripts/*.sh|py` and `docs/adr/NNNN` and fail when
  the path is absent from the tree — and a retro branched from `origin/main`, as § 5 requires,
  cannot see the script or the ADR the change under audit introduced. Both references become
  valid the moment #13 merges. Paid by rewording: this file says "a change-specific
  `phoenix-durability.sh`" and "ADR 0011" where it wanted the paths. Fourth occurrence of the
  class "the retrospective cannot clear its own § 5 gate" (R2/20260826, R2/20260827,
  F1/20260901), and the first with this cause. Not proposed only because the branch already
  carries three findings and the reword cost two minutes; the fix is three lines — skip
  `retros/` in the two path-existence loops while leaving it in `all_prose`, so the
  reverse-direction checks are untouched. The next retrospective should propose it on sight
  rather than degrade its own record again.
- **R6 — every gate author reinvents the probe, by hand, twice.** Confirming `[clean-slate]`
  blocks meant editing `stack/compose.yml` to add a host bind mount, running, editing again
  for an `external: true` volume, running, and restoring — with nothing but care between a
  forgotten restore and a probe riding along in a pull request. `docs/init/README.md` § 2
  step 5 and this agent's own § 5 both require exactly this and neither offers tooling. The
  same dance was done again in this retrospective. Not proposed: no probe has yet been left
  behind, so a helper would be a convenience, not a defect removed.

## Rejected

- **A `--lint` rule that a `body_excludes` needs a positive assertion beside it.** The lane's
  friction 3 is real — three of the five new steps needed a deliberate pairing to avoid
  passing on an empty response, and `smoke.py --lint` cannot see the shape of an expectation
  against an empty list. But the rule would fire on 31 existing, correct steps across five
  suites and the baseline (most of which carry a `json:` assertion the rule cannot read as
  positive), and no vacuous assertion has ever actually passed. `check-docs.py`'s own
  doctrine — every check names the defect that caused it — rejects it.
- **Anywhere for the harness to keep what a probe learned about a third-party API.** Friction
  4: the Phoenix REST API's server-side filters (`attribute=k:v`, `&name=`, `&span_kind=`),
  and the trap that `exclude_spans=["receive"]` makes `client_request_hook` unreachable, cost
  a container probe for the second lane running. It is genuinely valuable and it does have a
  home — the slice file records it, and that file is committed. A new documentation location
  for it would be a place nothing reads.
- **A gate on harness paths in a change branch.** See R1: it would have refused work with no
  sanctioned alternative, and the alternative is R3's undecided question.

## Not verified

- Anything in a remote environment. `deploy.infra` is false and `remote_asserted` is false;
  `verified-local` is the whole of what this lane proved.
- The out-of-band results in `STATUS.md` — the durability trace `b1aa0e0c…`, the 315 backend
  tests, the log lines carrying the response's trace id, and the by-hand span reads. Re-running
  them needs the stack and the backend's toolchain; they are the lane's testimony. R3.
- Whether `prs.sh --create` opens a control-repo PR that does not yet exist. The probe used
  `--dry-run` against a change whose PR is already open, so the `existing` path is proven and
  the `created` path is not.

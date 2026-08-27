---
lane: ship-iterate
change: 0004-rag-knowledge-base
run: changes/0004-rag-knowledge-base/runs/20260827T144501Z
date: 2026-08-27
verdict: coherent-with-warnings
findings: 2 proposed, 7 recorded, 4 rejected
pr: none — `make check` cannot pass on any branch this lane is allowed to use; see R2
---

The amendment itself is the cleanest run this repo has had: one attempt, no contract gap,
both slices OK first time, 60 assertions green, both pull requests updated in place with
CI green on each. What is not clean is everything the harness remembered — or failed to.

Three of yesterday's findings recurred today, and the reason they recurred is the same in
all three cases: **the fixes were written and could not be published.** The 20260826 retro
committed `iterate.sh`, `fanout.sh` and `check-docs.py` fixes to
`harness/retro-20260826T163132Z`, pushed it, and opened no pull request because its own § 5
gate could not pass. Today's lane paid for two of those fixes again, and believed both were
sitting in pull request #10 — they are not; #10 is the `ship-iterate` lane and touches
neither script. Nothing in the harness could have told it otherwise: the evidence bundle's
§ 7, the section whose whole job is "what has already been said", printed
`previous retros: (none)`.

That is the shape of this retrospective. The judgement was fine both days. The memory is
what is broken, and it is broken in a way that compounds.

## State audit

- **Control repo** — clean tree at `698b8e3` on `feat/0004-rag-knowledge-base`; the bundle
  found nothing uncommitted, submodule pointers included.
- **`contracts/` committed alone** — `be87279` is `contracts/README.md` and
  `contracts/openapi.yaml`, 2 files, nothing else. It supersedes `44e38bc`, which never
  merged; re-freezing rather than reconciling is what the lane prescribes and what
  ADR 0010 decided — that file is unmerged, see below.
- **The freeze recorded in `change.yaml` and nowhere else** — no: `change.yaml:12` has it,
  and `changes/0004-rag-knowledge-base/STATUS.md:6` carries the same 40 characters, from
  the scaffold. They agree. See R5, second occurrence, which cost a second edit today.
- **Submodules** — `chatbot-backend` `9149e2a` and `frontend` `7d27776`, both on
  `feat/0004-rag-knowledge-base`, both clean, both ahead of `repos.lock`; `infra` on `main`
  at `6eebe0a`, matching. That is exactly what a ship-shaped lane leaves.
- **Contract against what is served** — re-checked in this lane:
  `runs/20260827T144501Z/attempt-1/harvest.log` reports additive only, five paths returning
  an undeclared `422`. No breaking drift, and the same five as yesterday.
- **Assertions** — 60 passed, 0 failed, 24 of them from the change's own suite. Not thin:
  the session gate, the content-type refusal, the retrieval round trip, cross-account
  isolation, deletion purging both storage and the index, and the citation surviving it.
  Two criteria are asserted only outside the seam and the brief says so — see R1.
- **The cloud** — nothing. `verify.json` records `environment: null` and
  `remote_asserted: false`; `deploy.infra` is `false`. The label printed was `verified`.
  Second occurrence of the 20260826 F1 defect, whose fix exists and is unpublished.
- **Pull requests** — facts. `runs/20260827T144501Z/prs.json` records chatbot-backend#7 and
  frontend#6 as `existing`, written by `prs.sh --create` after it queried them, and both
  were confirmed here as `OPEN` with every check `SUCCESS` (backend: `static`,
  `integration`; frontend: `lint, typecheck, unit`, `playwright against the dockerised
  build`). `fanout.json`'s per-slice `pr` claims agree with them this time.
- **Gates, re-run now** — `check-docs.py` exit 1 on `[vendored-contracts]` and nothing
  else, on this branch and on any branch off `origin/main` (probe in R2);
  `manifest.py --validate` exit 0 for every change; `test-hooks.py` exit 0 in both
  directions; `smoke.py --lint` clean across 89 steps in 4 suites; `make -C chatbot-backend
  lint typecheck` and `make -C frontend lint typecheck` both exit 0.
- **The stack** — **up**, and it was up before this retrospective started. R7/R8, second
  occurrence: see the system defects in the report.
- **Evidence images** — `changes/0004-rag-knowledge-base/evidence/choose-file-control.png`
  and `duplicate-citations.png` are committed and named in the slice files. The mechanism
  ADR 0010 introduced worked on first use.

## Findings

### F1 — the evidence bundle could not see the retrospective before it, or the fixes stranded with it

- **Evidence:** `scripts/retro-evidence.sh:323` listed previous retros with
  `ls -1 retros/*.md`, the working tree only. Today's bundle, § 7, printed
  `previous retros: (none)` while
  `retros/20260826T163132Z-ship-0004-rag-knowledge-base.md` — 279 lines about this same
  change — existed on `origin/harness/retro-20260826T163132Z`. A retro lands **by pull
  request**, so a retro whose pull request could not be opened is invisible to precisely
  the mechanism `retros/README.md` says the directory exists for: "friction that was
  noticed and tolerated once becomes proposable the second time it appears". The same
  section lists open pull requests and closed ones and has no line for a pushed branch that
  is neither, which is where yesterday's three fixes are.
- **Judgement:** meets all four lines. Not speculative: it happened on the first occasion
  it could have.
- **Disposition:** proposed. § 7 now lists retro files found on any ref, marking the ones
  not in this tree with the ref that carries them, plus a `harness branches with no pull
  request` line. Shown both ways: with the file present it lists it; with the file moved
  aside — the state on a `/ship` branch — it prints
  `retros/20260826T163132Z-…md — NOT in this tree, on harness/retro-20260826T163132Z`, and
  names the branch as having no pull request. The file was moved back; `git status` clean.

### F2 — `smoke.py` still cannot send a file, and this time it cost a criterion

- **Evidence:** second occurrence of R1 in the 20260826 retro, which recorded it with
  "named here so the next lane that meets it can propose it as a second occurrence". The
  cost escalated exactly as that finding predicted it might. Last lane the limit shaped the
  frozen interface — upload took a JSON `content` string partly because the suite could not
  send bytes. This lane the interface was designed correctly anyway
  (`multipart/form-data` for binary, JSON for text), and the bill arrived instead as a
  criterion with no seam oracle: `changes/0004-rag-knowledge-base/smoke.yaml:19` says
  "NO PDF STEP EITHER, and that one is a harness limit rather than a choice", and
  `BRIEF.md` § "A gap in the oracle" says "PDF upload is not asserted at the seam either,
  and this is the one that hurts… The harness fix is a `files:` key on a smoke step; it is
  a control-repo change and `CLAUDE.md` forbids slipping one into a change, so it belongs
  to a retrospective." The change handed this here, in writing.
- **Judgement:** the 20260826 rejection was on "smallest change" — a new capability in the
  script whose readability is why it is trusted. That objection is answered by the size of
  the diff (one step key, one lint block, one helper, one `files=` argument) and outweighed
  by the alternative, which is a headline requirement proved by one oracle where everything
  else has two. No ADR decided the suite's request vocabulary.
- **Disposition:** proposed. `files: {field: <path beside the suite>}` or
  `{field: {path, filename, content_type}}`; `form:` carries the text fields beside it;
  `body` and `files` together are refused. Fixtures resolve against the suite that names
  them. Demonstrated three ways: `check-docs.py` `[step-schema]` fails
  (`step key 'files' is accepted by smoke.py but not documented`) until the template header
  documents it and passes after; `--lint` on a malformed step reports all three of
  body-and-files-together, a fixture that is not beside the suite, and
  `unknown key 'contenttype' — did you mean 'content_type'?`; and a real step uploaded a
  fixture to a local echo server, which saw
  `multipart/form-data; boundary=…`, `filename="charter.pdf"`,
  `Content-Type: application/pdf` and the `form:` field beside it. The probe files live
  outside the repo. **No step was written for 0004** — the criteria are the change's, and a
  retrospective does not edit them.

### R2 — the retrospective still cannot publish, and that is now the most expensive defect here

- **Evidence:** third occurrence. `scripts/check-docs.py:417` compares each submodule's
  vendored `openapi.yaml` byte-for-byte against `contracts/openapi.yaml` and fails on a
  difference — but `docs/adr/0008` makes dispatch the publisher, so between the freeze
  commit and `/realign` those copies necessarily differ, and the state the check calls a
  failure is the state a freeze is defined to create. Probed today, with `contracts/`
  swapped in from each branch a retrospective is allowed to use and restored afterwards:
  from `origin/main` (1.3.0) exit 1; from `d0a6b87`, the base of the open harness pull
  request (1.4.0), exit 1. The submodule working trees carry 1.5.0, published from
  `be87279` at dispatch. Every other gate is green, including both product repos' lint and
  typecheck. So the one check standing between this record and a pull request is the one
  that fails on every legal branch point for the whole window this lane runs in.
- **What it has cost, now measurable:** yesterday's three fixes are on a pushed branch with
  no pull request. Today the `verified` label was hand-corrected in `STATUS.md` for the
  second time, and `[commands]` false-positived on a URL path fragment for the third time
  at `contracts/README.md:222`, with correct prose reworded for the second time. Both fixes
  were written yesterday. Neither could be merged, and nothing showed the lane where they
  were — it believed they were in pull request #10.
- **Judgement:** meets the bar on every line. Not proposed **again**, for the same reason
  as yesterday and one more. The retro lane's own § 5 says a `make check` failure with a
  cause the retrospective did not introduce is a system defect: report it, open nothing, do
  not attempt a fix. Fixing it is therefore doubly out of bounds — it is the check blocking
  this file's publication, and the rule naming it says hands off. It needs a human. The
  shape still worth trying is the one yesterday proposed: compare the vendored copy against
  `contracts/` at the freeze SHA of a change that has not merged, and downgrade to a named
  warning when it matches.
- **Disposition:** recorded and escalated, three occurrences, with the probe above as new
  evidence. Two decisions are available to a human and both are cheap: fix the check, or
  say that a retrospective's pull request is opened with `make check` green *on the change
  branch*, where `contracts/` and the vendored copies agree.

### R3 — proposal latency is the defect, not the proposals

- **Evidence:** the retrospective lane is two days old and has produced four fixes; zero
  have merged; two of them cost a later lane real time (above). The cap in § 5 — one open
  pull request at a time, a second retrospective commits onto the open branch — assumes
  pull requests get opened. When none can be, the cap silently becomes "one branch nobody
  can see", which is what F1 is about.
- **Judgement:** the mechanism half is F1 and is proposed. The rest is a decision about how
  the lane publishes, which belongs to whoever owns `docs/adr/0009`.
- **Disposition:** recorded. This record was committed onto
  `harness/retro-20260826T163132Z` rather than onto a third branch, so that one pull
  request lands both retrospectives and all the fixes at once.

### R5 — the freeze SHA has a second home, and it bit the first time the SHA moved

- **Evidence:** second occurrence, predicted verbatim by the 20260826 retro.
  `changes/0000-example-change/STATUS.md:13` scaffolds `- SHA: \`<sha>\``, so re-freezing
  at `be87279` meant editing `change.yaml` and `STATUS.md`. The change's own brief argues
  against exactly this, in its own words: "It goes in `change.yaml` as `freeze_sha`, which
  is the only place anything reads it — two copies of a SHA is one copy that can go stale."
  `check_freeze_sha_home` (`scripts/check-docs.py:69`) scans for the older shape of the
  defect and not this one. `changes/0001-auth/STATUS.md:5` carries a literal 40-character
  copy too; `0002` and `0003` wrote a pointer instead, which is the pattern that works.
- **Judgement:** real, two occurrences, and the smallest change is small — take the line
  out of the scaffold and let the check refuse a literal SHA under that heading in a
  change's `STATUS.md`.
- **Disposition:** recorded, not proposed. Three findings is a lot and this is the third;
  the check would also fail `changes/0001-auth`, so it lands with a small edit to a shipped
  change's record, which is a reviewer's call rather than a retrospective's.

### R7/R8 — the loop leaves the joined stack up, does not say so, and it broke the next lane again

- **Evidence:** second occurrence. `scripts/iterate.sh:401` passes `--keep-up` to
  `verify.sh` whenever `ATTEMPT < MAX_ATTEMPTS`, so a green attempt 1 of 2 leaves the
  joined stack running, and `iterate.sh:275` mentions the stack only when the human passed
  `--keep-up` themselves. Today the lane's first act was tearing down `agentapp-stack-*`
  left from yesterday's run, by hand, with `stack.sh down` and two
  `docker compose -p … down`. The same stack is up right now, after this run.
- **Judgement:** meets the bar. The smallest change is confined to `finish()`: if the human
  did not pass `--keep-up` and the loop's own between-attempts `--keep-up` is what left it
  running (`ATTEMPT < MAX_ATTEMPTS`), take it down on a green outcome and say so; on a
  failure leave it and say that too, because a running stack is evidence.
- **Disposition:** recorded, not proposed — it cannot be shown working without a full loop
  run, and the stack that would demonstrate it is a system defect this lane reports rather
  than clears. Proposable on sight next lane, with this record as the citation.

### R9 — the oversize fixture, second occurrence: the rejection holds

- **Evidence:** yesterday the fixture (1372 bytes) was under the cap (2000) and a correct
  backend passed a negative step. Today the cap became 10 MB and no readable fixture can
  trip it, so the lane deleted the step and moved criterion 12's size half into
  `chatbot-backend`'s tests, recording it in `smoke.yaml:14` and in `BRIEF.md`
  § "A gap in the oracle". Same class, twice in two days — but the second occurrence was
  caused by a requirement change, not by an authoring error, and the response was correct
  both times.
- **Judgement:** the 20260826 rejection stands and for the same reason: nothing in
  `smoke.py` can know what condition a fixture was written to trip unless the suite
  declares it, and a declaration invented for two occurrences that were both handled
  correctly is the speculative check `check-docs.py` refuses. The adjacent temptation — a
  gate that every numbered criterion has a step — is worse: it needs criterion IDs threaded
  through two files, and both gaps this change has were already written down in the brief
  under a heading that exists for them.
- **Disposition:** rejected again, recorded for the pattern.

### R10 — the friction log's two factual errors, because the next lane will make them again

- **`contracts/openapi.yaml` is parsed before dispatch, and has been since before this
  run.** `validate_freeze` (`scripts/manifest.py:129-152`) `yaml.safe_load`s
  `contracts/openapi.yaml` and `contracts/infra-outputs.yaml` and reports the line and
  column, with a comment naming the unquoted `: ` inside a description as the case it was
  written for. The lane hand-parsed the spec after editing, hit the trap at line 877, fixed
  it before the gate ever ran, and concluded nothing checks it. Nothing is missing here;
  what is missing is a sentence in the lane pointing at what the gate covers.
  What the gate does **not** cover is the frozen tree: it parses `contracts/` in the
  working tree, which is required to be clean, but `freeze_sha` may name an earlier commit.
  Amending the freeze commit — what the lane did — keeps those the same thing. A second
  contracts-only commit would not, and the lane says nothing either way.
- **Yesterday's F1 and F3 fixes are not in pull request #10.** #10 is
  `harness/ship-iterate` and touches `.claude/commands/ship-iterate.md`, `CLAUDE.md`,
  `README.md`, `concept.md`, the new ADR and three lines of `check-docs.py`
  (`AGENT_DISPATCHERS`). The fixes are on `harness/retro-20260826T163132Z`, unopened. F1
  proposed here is what would have told the lane that.
- **Disposition:** recorded. The first half is the lane prose gap below; the second is F1.

### R11 — the control repo's half of this change is not pushed, and no lane says it should be

- **Evidence:** found after this record was first written. `feat/0004-rag-knowledge-base`
  is three commits ahead of its remote — `be87279` (the freeze), `8139f43` (the amendment),
  `698b8e3` (the run) — so the commit that `change.yaml` records as `freeze_sha`, that
  `vendor-contracts.sh` published into both product repos at dispatch, and that both open
  pull requests are implemented against, exists on one laptop. `grep -n "git push"` across
  `scripts/*.sh` and `.claude/commands/*.md` returns nothing; `prs.sh --create` iterates
  `$CHANGE_SLICES`, which is the product repos, and `prs.sh --list` was taught about this
  repo in `915f772` precisely because its half kept going missing. Second occurrence of the
  class: pull request #7 is titled "realign: recover 0002's stranded control-repo half".
- **Judgement:** meets the bar. The smallest change is not obvious, though — pushing a
  branch is a network side effect in a loop that otherwise touches no remote except through
  `prs.sh`, and whether this repo's half is a pull request per change or a push before
  dispatch is a decision with an ADR's worth of consequence.
- **Disposition:** recorded, and reported to the human as a system defect for the state it
  left behind rather than fixed here.

### The new lane, graded on its first run

What held up, checked against the artifacts rather than taken on trust:

- **The amend order** (brief, then `smoke.yaml`, then the slice files, then `STATUS.md`)
  produced a coherent change: `BRIEF.md`'s new "Out of scope" and § "A gap in the oracle"
  are exactly what `smoke.yaml`'s header and the deleted step encode, and `STATUS.md`
  states both costs in prose a diff would not show.
- **"Say what to REMOVE, explicitly"** is load-bearing, and the artifacts agree: the
  per-chunk citation is gone and `fanout.json`'s backend reason names
  "one citation per document" as something it did.
- **Branches already exist, so sessions continue** — supported: the backend slice hit the
  3600s watchdog building this from cold yesterday and finished inside it today for a
  comparable amount of change, first attempt, no contract gap.
- **Images as files under `evidence/`** worked on first use, and the frontend slice acted
  on the one it was given.

Two gaps, both in the lane's prose rather than its mechanism:

- **Phase 2 says commit `contracts/` alone and says nothing about a freeze commit that
  then needs a fix.** `check-docs` flagged prose inside the freeze commit after it was
  made. Amending it and re-recording the SHA is right — it keeps `freeze_sha` naming the
  tree that was frozen — and the alternative leaves two commits that both look like
  freezes. The lane should say which, in one line, next to the gate that would not catch
  the difference (R10).
- **The `lane:` vocabulary in `retros/README.md` was not extended when the third lane was
  added**, so this file's frontmatter names a lane the schema does not list. Corrected
  here; the omission is the same class as `AGENT_DISPATCHERS`, which #10 did remember.

One more instance of R2's class, met while writing this file: `check-docs` `[dead-wiring]`
failed on it for citing the ADR that decided the lane being graded, because that ADR exists
only on the unmerged pull request. The reference was reworded rather than the check
changed — the third time in two days that correct prose has been rewritten to satisfy a
gate that is right about the tree and wrong about the moment.

## Rejected

- **A parse check for `contracts/openapi.yaml`.** It exists. See R10.
- **A gate that every criterion has a step.** R9.
- **Fixing `[vendored-contracts]`.** R2 — out of bounds twice over, and escalated instead.
- **Anything inside `contracts/` or a product repo.** The multipart intake is frozen and
  implemented; a criterion changes here, on purpose, by a human.

## Not verified

- Anything in a remote environment. There is none: `deploy.infra` is false and
  `remote_asserted` is false, so `verified-local` is the whole of what this run proved,
  whatever the label said.
- The two product pull requests were confirmed open with green checks, but nothing here
  ran their suites; the 78 Playwright tests are reported by `frontend`'s CI, not by this
  repo.
- The stack-teardown fix in R7/R8 is a sketch, not a diff, and was not exercised.
- Whether `make check` passes on a branch off `origin/main` after `/realign` — expected,
  untested, and it is the difference between this lane publishing and not.

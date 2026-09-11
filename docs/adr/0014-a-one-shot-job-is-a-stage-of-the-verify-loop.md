# 0014 — A one-shot job is a stage of the verify loop, and its exit code is an assertion

**Status:** accepted
**Date:** 2026-09-03
**Relation to 0003:** extends it. 0003 decided that a pass requires counted evidence and
that an outcome may never be inferred from the absence of a failure signal. This adds the
kind of evidence the loop could not previously count at all.

## Context

`smoke.py` makes HTTP requests against a stack somebody else brought up. That is a
deliberate and load-bearing constraint — it is why the suite is readable, why it is the same
oracle a person runs by hand, and why `--contract` can check every request against the
frozen spec. It also means the loop can assert nothing about a criterion whose oracle is a
**process** rather than a request.

Two such criteria already existed and neither was an assertion:

- `changes/0005-observability-phoenix` criterion 12 — a trace survives restarting Phoenix.
  A suite running against a live stack cannot cycle a container mid-run, so it became
  `make phoenix-durability`: a make target, run by hand, with its result reported in prose.
- The same change's criterion 13 — `make down` leaves no state. Split in half, with the
  enforceable part becoming a `check-docs.py` gate and the other part a **measurement
  recorded on a date**.

Both were handled honestly: 0005's brief has a section called "A gap in the oracle" that
names them and says what the oracle is instead. But an honest gap is still a gap, and three
retrospectives in a row have now recorded that those out-of-band oracles "were not re-run
here" — the third one saying so explicitly. A criterion whose verification depends on
somebody remembering is a criterion that will eventually be believed rather than checked,
which is the failure `docs/adr/0003` was written against.

`changes/0006-chatbot-eval` cannot survive that arrangement, because its central criteria
are entirely of this kind. "The run produces a Phoenix experiment with per-example scores
from four evaluators" requires the run to have happened. "It exits non-zero when a threshold
is breached" is not a thing any HTTP client can ask of anything. And the joined stack forgets
everything on `down` (`docs/adr/0011`), so a suite that read what a run produced without the
run having happened in the same pass would be asserting an empty Phoenix on a cold stack, or
last week's leftovers on a warm one.

Three ways to close it were available:

1. **Give `smoke.py` a step kind that runs a container.** Rejected: it destroys the property
   that makes the suite trustworthy. A file where some steps are requests and some are
   `docker compose run` is no longer readable as acceptance criteria, `--contract` has
   nothing to say about half of it, and the one script whose readability is why it is the
   oracle grows a container runtime.
2. **A special case in `verify.sh`: if this change has a `chatbot-eval` slice, run the
   eval.** Rejected outright. A stage that names one repo is the shape of defect this repo's
   whole doctrine is against, and the next such criterion would add a second branch.
3. **A generic declaration in `change.yaml`.** What was decided.

## Decision

**`change.yaml` may declare `jobs:` — one-shot containers the loop runs to completion inside
the joined stack — and each job's exit code is a counted, routable assertion.**

```yaml
jobs:
  - name: eval-run-meets-its-thresholds
    service: eval
    owner: chatbot-eval
    expect_exit: 0
    timeout_s: 900
  - name: a-breached-threshold-exits-non-zero
    service: eval
    owner: chatbot-eval
    expect_exit: 1
    env: {EVAL_THRESHOLD_RETRIEVAL_RECALL: "1.01"}
```

Six properties, each of which is the decision rather than an implementation detail:

1. **`owner` routes the repair, exactly as a smoke step's does.** A failing job produces the
   same brief a failing assertion does, with the job's own output attached — which for a job
   is the whole of the evidence, since there is no request and no response to show.
   `manifest.py --validate` requires `owner` to be a slice of the change.

2. **`service` must be a service `stack/compose.yml` declares**, which is also where its
   `agentapp.owner` label lives. So the two facts a failing job needs — how to start it and
   who is answerable — are declared in one file, and `check-docs.py` fails when a job's
   `owner` and its service's label disagree. One container may not have two answerable repos.

3. **`expect_exit` makes the refusal a first-class case.** A job that must exit non-zero is
   as much a criterion as one that must exit zero, and it is usually the more interesting
   one: "the gate actually gates" is only provable by breaching it. A second job with an
   impossible threshold is how this change proves its own exit code, and it costs one
   declaration rather than a paragraph of prose.

4. **Exit 2 from a job is that process refusing to judge**, in the same vocabulary
   `docs/adr/0003` established for this repo's own gates. It still fails and it still routes
   to the owner — a job that cannot reach what it measures is a real failure — but it is
   reported as a refusal rather than as a breach, because calling it a breach sends a repair
   agent after a number when the cause is a missing precondition.

5. **Jobs run BEFORE smoke.** A job produces the state the suite then asserts, and on a cold
   stack there is nothing to assert until it has.

6. **A job of this change satisfies the counted-evidence gate.** `verify.sh` required at
   least one assertion from the change's own suite; it now requires at least one from the
   suite **or** one passing job. Written as an `or` rather than folded into one counter, so a
   reader can still see which kind of evidence a pass rests on — `verify.json` carries
   `jobs: {ran, passed, failed}` beside the assertion counts, and `ran` is what distinguishes
   "declared two jobs and ran none" from "declared none".

`scripts/stack.sh run <service> [KEY=VALUE ...]` is the entry point, so a job run by hand
and a job run by the loop cannot drift apart on flags — the reason that script exists. It
translates bare `KEY=VALUE` pairs into `-e` itself rather than accepting compose flags: a
job may override a threshold, it may not redefine the service.

## Consequences

**Makes easy.** A criterion whose oracle is a process stops being a paragraph and becomes a
line in `change.yaml` that fails a run. Migrations, seeders, backfills and scheduled jobs all
have this shape, and all of them were previously unassertable here. The pattern also matches
what these things become in production — a k8s Job — so the local assertion and the deployed
artifact are the same thing.

**Accepted costs.**

- **`verify.sh` now starts containers, not just requests.** It already brought the stack up,
  so the capability is not new, but the failure surface is: a job can hang, and a watchdog
  per job is the answer for the same reason `fanout.sh` has one — macOS ships no
  `timeout(1)`. A killed `docker compose run` can leave its container behind; `finish()`
  tears the project down, so it is cleaned at the end of the run rather than immediately.
- **A job is a much coarser assertion than a step.** "Exit 1" says a threshold was breached
  and not which, and the log is the only thing that says more. That is inherent — the exit
  code is the interface — and it is why the brief for a job failure includes the job's whole
  tail rather than a filtered slice of it.
- **Two jobs that run the same service run it twice**, and this change pays that: the
  threshold-breach job re-runs the whole eval. Seeding is idempotent so the second run is
  cheaper than the first, but it is not free, and a change with five exit-code criteria
  would want a cheaper mechanism than five runs.
- **`change.yaml` grows a fourth top-level key**, and every key there is one more thing a
  planner can get subtly wrong. Mitigated by typing it as strictly as `deploy.*` is:
  a null `jobs:`, a quoted `expect_exit`, a non-integer `timeout_s` and an env value with a
  space in it are each a refusal with the reason named, for the reason 0003 gives — a stage
  that compares against nothing cannot fail.
- **It does not retire the out-of-band oracles it was written because of.**
  `make phoenix-durability` still needs a restart mid-run, which is a thing a job cannot do
  either. So 0005's gap is unchanged, and this ADR closes a class it is not a member of.
  Named so the improvement is not read as bigger than it is.

## Alternatives considered

- **A `run:` step kind in `smoke.py`.** Rejected: it costs the property that makes the suite
  the oracle. A reader must be able to tell what is being asserted by reading the file, and
  `--contract` must be able to check every request in it.
- **A branch in `verify.sh` for this change's slice.** Rejected: a stage that names one repo,
  which is the defect `docs/adr/0005` deleted four skills over.
- **Leave it as a make target and a paragraph, like criterion 12.** The status quo, and it is
  what three retrospectives have now recorded as unverified. It also cannot work here: the
  change's central criteria are all of this kind, so the run would report `verified-local`
  on the strength of assertions about a version endpoint.
- **Let the eval assert its own thresholds and report a verdict the loop trusts.** Rejected
  for `docs/adr/0002`'s reason, which applies to a process exactly as it applies to an agent:
  the thing under test does not decide whether it passed. The exit code is a fact the loop
  observes; a verdict in a file would be a claim.
- **Run jobs after smoke.** Rejected: the suite exists partly to assert what the job
  produced, and on a cold stack there would be nothing there.

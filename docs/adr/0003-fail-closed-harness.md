# 0003 — The harness fails closed, and a pass requires counted evidence

**Status:** accepted
**Date:** 2026-08-20

## Context

ADR 0002 built the deploy-verify-repair loop and made `owner` the field that routes a
failure. It said what the loop should decide. It did not say what the loop is entitled to
conclude from silence, and the implementation answered that question badly in seven
different places:

- `verify.sh` initialised `STATUS="pass"` and flipped it only on an explicit `fail_stage`.
  Any unexpected `set -e` death fired the EXIT trap with `STATUS` still `pass`, printing
  `PASS — <change> verified` and writing a pass-shaped `verify.json` while exiting
  non-zero.
- `iterate.sh` captured `fanout.sh`'s exit code into a variable instead of acting on it.
  `fanout.sh` refuses to dispatch without a `freeze_sha` — and the loop then ran deploy and
  smoke anyway. A change with the freeze SHA recorded in the wrong file produced
  `outcome: verified`, exit 0, and no implementation at all.
- `manifest.py` read `deploy.get("local", True)`. A present-but-empty `local:` key parses
  as `None`, which is falsy, so both the deploy stage and the smoke stage skipped and the
  run still reported PASS.
- A missing change smoke file was a `note`. An empty `steps: []` was a warning — and it is
  what `new-change.sh` scaffolds, so the default state of a fresh change was a suite that
  passed by asserting nothing.
- `smoke.py` never validated `expect`. A step with no `expect` passed on any response
  including a 500, and a misspelled key (`expects:`, `status_code:`) was silently ignored.
- `smoke.py` with zero selected steps returned `ok: true` and exit 0, which made the
  infra-tagged stage an unconditional vacuous pass.
- `fanout.sh` matched the agent's terminal line with the glob `OK|OK.*`, and `iterate.sh`
  detected a contract gap by grepping the whole of `fanout.json` for the substring
  `contract`.

Every one of those is the same mistake: **an outcome inferred from the absence of a failure
signal rather than from the presence of counted evidence.** Individually they read as small
oversights. Together they meant the harness's strongest claim — `verified` — could be true
of a run in which nothing was built and nothing was asserted.

This was tolerable while the only cost of a false `verified` was a wasted local run. ADR
0004 makes `verified` mean Terraform was applied to a real account, and at that point a
harness that cannot distinguish "passed" from "did not look" is worse than no harness,
because it produces confidence without enforcement — the failure mode `docs/init/README.md`
already names for unverified gates.

## Decision

Three conventions. Every gate in `scripts/` implements them, and new gates are held to
them.

1. **Exit 1 means the thing under test failed. Exit 2 means the harness refused to judge
   it.** No caller may conflate the two. A malformed suite, an undefined variable, an
   unparseable manifest and an empty step selection are all exit 2, and they are reported
   as the control repo's fault rather than routed to a product repo as a repair brief.

2. **A pass requires counted evidence.** `verify.sh` counts the assertions it evaluated and
   records them in `verify.json`. `status: pass` requires reaching an explicit terminal
   marker, zero failures, **and at least one assertion originating from the change's own
   suite**. A run that proves only that the stack still works says so, and fails.

3. **Every dispatched agent returns a structured result, or is recorded as failed.** The
   agent prints a sentinel-delimited JSON block. Absent, malformed, or carrying a status
   outside the enum are all failures. "No result" is a defined outcome, not an accident,
   and `blocked-by-contract` is a field value rather than a substring somebody greps for.

Consequences that follow mechanically, and are part of the decision:

- `STATUS` initialises to `incomplete`; `finish()` converts that to a failure naming the
  stage that died. A `verify.json` can no longer contradict the exit code.
- `expect` is required on every smoke step. There is no exemption for capture-only steps,
  because a capture-only step is exactly the vacuous-pass hole.
- The step schema is owned by `smoke.py` and exposed as `smoke.py --lint`, called by
  `manifest.py --validate`. One schema, two entry points, no second copy to drift.
- The six preconditions `.claude/commands/ship.md` asked a reader to check by hand become
  one machine gate. This is ADR 0001's argument turned on the harness itself: instruction
  text cannot fail a build.
- A fifth loop outcome, `blocked`, for "a precondition was unmet, nothing ran". Calling
  that `unattributable` sent a reader to container logs to diagnose a missing `freeze_sha`.

## Consequences

Cross-repo breakage still surfaces in minutes, but a *green* run now carries a claim you
can check: how many assertions ran, how many came from the change, and which stages were
skipped and why. `report.md` cannot say `verified` above an empty assertion count.

Accepted costs:

- **A freshly scaffolded change is now unshippable until someone writes its criteria.**
  `./scripts/new-change.sh` produces a directory that fails `--validate` on four counts.
  This is deliberate and it is the point, but it does convert a warning people learned to
  ignore into a blocker they must clear, and the first encounter will feel like friction.
- **`expect` on every step** makes a handful of legitimate patterns slightly more verbose
  (a step that exists only to establish a session must still state a status).
- **The seam suite still does not validate response bodies against the frozen schema.**
  `Contract.check` verifies that a path, method and status are declared, and nothing more.
  Real structural conformance needs a JSON-Schema dependency and a `$ref`/`oneOf` resolver
  inside the one script whose readability is why it is trusted as the oracle. Instead the
  loop now runs `harvest-contract.py --diff` against the live spec, which catches the same
  drift structurally and earlier. What remains uncovered is a runtime body that violates a
  schema its own published spec declares correctly — genuinely narrower, and the right
  place to catch it is the backend's own tests against its vendored contract. Named here so
  it is a decision on the record rather than an unstated gap.
- **More things now fail.** Some of them will be the harness's own bugs rather than a
  slice's, and `fault: harness` in `verify.json` exists to say so. The alternative was a
  harness that failed less often by looking less carefully.
- **The conventions are only as good as their probes.** Each gate in this ADR has a
  deliberate break recorded in the change that introduced it, per
  `docs/init/README.md` — "break a test on purpose and confirm the gate blocks."

## Alternatives considered

- **Fix the seven defects individually and leave the defaults alone.** Rejected: it treats
  as coincidence what is one design mistake, and it leaves the next skip branch someone
  adds free to pass vacuously. The assertion counter is what makes the whole class
  unreachable rather than the seven known instances.
- **Keep the prose preconditions in `ship.md` and add more emphasis.** Rejected by ADR
  0001's own thesis, and by `docs/init/README.md`'s drift signal: if a written rule is
  repeatedly violated, shorten the file and add a mechanism — do not add emphasis.
- **Let the dispatched agent report its own verdict and trust it.** Rejected for the reason
  ADR 0002 gives: agents implement, they do not decide whether the change is done. The
  structured result records what the agent *claims*; the smoke suite decides.
- **Make `unattributable` the catch-all it already was.** Rejected. Build failures, missing
  smoke variables and malformed suites all have obvious owners or an obvious location, and
  reporting them as "a harness or environment problem" sent people to the wrong evidence.

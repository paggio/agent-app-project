# 0002 — The control repo owns the joined stack and the cross-repo smoke suite

**Status:** accepted
**Date:** 2026-08-18

## Context

ADR 0001 made `contracts/` the coordination mechanism: a machine-readable artifact that
fails a build, rather than prose three agents will each interpret differently. It worked
for the interface. It said nothing about whether the interface is actually honoured at
runtime, and nothing filled that gap.

What existed instead:

- `fanout.sh` dispatched three `claude -p` runs into background subshells and called
  `wait`, which discards exit codes. It asked each agent for a trailing `OK` /
  `FAIL:<reason>` line that nothing read. The dispatcher could not fail, so nothing could
  iterate on its result.
- Verification stopped at "each repo's own gates pass, a PR exists" — the check that had
  already passed inside the repo that wrote the code.
- Nothing brought the repos up together. `chatbot-backend/docker-compose.yml` and
  `frontend/docker-compose.yml` declare no `networks:`, so they landed on separate
  default networks and the Caddy proxy's `/api/*` upstream did not resolve. `/api/`
  returned 502, and the frontend compose file documented this as expected.

So three repos could each be internally green while the seam between them was broken,
and nobody would find out until someone ran the whole thing by hand.

The freeze precondition had the same shape of problem: `grep -q '[0-9a-f]\{7,\}'` over
`BRIEF.md` was satisfied by any stray hex, so a change could fan out against an unfrozen
contract and warn about nothing.

## Decision

The control repo owns the joined stack and the cross-repo smoke suite, and runs them as
a bounded deploy-verify-repair loop.

1. **`stack/compose.yml`** composes both submodule compose files with Compose `include:`,
   putting every service in one project and therefore one network. It lives here because
   neither product repo may own it: the frontend cannot name a service it does not ship,
   the backend has no business knowing a proxy exists, and `CLAUDE.md` plus the
   `no-subrepo-edits.sh` hook forbid the control session from writing into a submodule.
   `include:` rather than repeated `-f`, because `-f` resolves every file's relative
   paths against the first file's directory and would break `build: { context: . }` in
   both.

2. **Smoke assertions are control-repo artifacts**, in `smoke/baseline.yaml` plus a
   `smoke.yaml` per change, run against the single origin a browser would use. Every step
   names an `owner` — the repo answerable for it. That field is what makes a failure
   routable instead of a group email.

3. **`changes/NNNN-*/change.yaml`** is the machine-readable half of a change: slices,
   freeze SHA, and whether this change requires a real infra deploy. Same argument as
   ADR 0001, applied to the change rather than the interface.

4. **The infra path is a contract before it is an implementation.** When
   `deploy.infra: true`, verify runs `make -C infra deploy` then `make -C infra outputs`,
   and checks the produced JSON against `contracts/infra-outputs.yaml`. `infra/` is
   currently an empty skeleton with no IaC tool chosen, so this fails loudly with
   "infra declares no deploy target" rather than skipping — a skipped deploy reported as
   a pass is the outcome worth preventing.

5. **`iterate.sh` closes the loop**: dispatch, deploy, assert, and on failure send the
   failing assertion plus that service's container log back to the owning repo, bounded
   at 2 attempts by default. A slice reporting a contract gap is a hard stop with no
   retry.

## Consequences

Cross-repo breakage surfaces in minutes, at the seam, attributed to a repo, with the
evidence an agent needs to fix it — instead of surfacing days later to a human.
`verify.sh` is usable standalone, so the oracle is the same one a person runs by hand.

Accepted costs:

- **The control repo now depends on Docker and on both submodules being checked out.**
  It was previously a documents-and-scripts repo that needed neither. Planning still
  works without them; shipping does not.
- **The smoke suite is a fourth place assertions live**, after the three repos' own test
  suites, and it can rot. Mitigated by scope: only the seam belongs here. Anything
  provable inside one repo stays inside that repo.
- **Smoke steps are written by the same people who write the criteria**, so a weak
  criterion becomes a weak step. The harness cannot fix that; it only makes it visible,
  by warning when a change declares no steps at all.
- **Repair is bounded, so some failures end with a human.** That is deliberate — an
  unbounded loop churns forever on a contract gap it is forbidden to fix.
- **A repair pass re-runs an agent over code it just wrote**, which can compound a bad
  approach rather than correct it. The brief mitigates this by carrying observations
  rather than diagnosis, and by forbidding the agent to weaken the assertion.

## Alternatives considered

- **An orchestrating agent that coordinates the three repos** — rejected again, for the
  reason ADR 0001 gave: it substitutes a non-deterministic coordinator for a
  machine-readable artifact. `iterate.sh` is a deterministic script that *dispatches*
  agents; the control flow, the attribution and the stopping conditions are fixed in
  shell where they can be read and audited. Agents implement; they do not decide whether
  the change is done.
- **Put the joined compose file in `frontend/`** — it is the repo that owns the proxy.
  Rejected: it would make the frontend's own compose file untrue (it would name a service
  from another repo), and the control session is forbidden from editing it anyway.
- **Re-run each repo's own suites against the joined stack instead of a new suite** —
  cheaper to build, but those suites assert what one repo believes about itself. The
  frontend's tests pass today against mock clients; running them against the joined stack
  would still exercise mocks. A separate suite is the only one that can fail on the seam.
- **Run the smoke suite in each repo's CI** — every product repo would need to vendor the
  other two, which is the polyrepo coupling ADR 0001 spent its whole budget avoiding.
- **Leave verification to a human checklist** — the status quo. It is what let the
  backend ship `POST /v1/chat` while the frontend hand-declared a threads-and-SSE
  `ChatClient`, with `contracts/openapi.yaml` still at `paths: {}`.

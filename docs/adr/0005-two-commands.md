# 0005 — Two commands, and the freeze is a gate rather than a session boundary

**Status:** accepted
**Date:** 2026-08-21
**Relation to 0001:** amends it. The contract-first structure stands; the rule about *how
many sessions* it takes does not.

## Context

ADR 0001 decided that contract changes are "sequential and single-session… never both at
once", and `CLAUDE.md` grew a lane table reading "never plan, freeze and implement in one
pass". At the time that was the only available enforcement: nothing could check that a
freeze had happened, so the check was a human keeping three activities apart.

Three ADRs later, that is no longer true. `manifest.py --validate` requires `freeze_sha` to
be a real commit, an ancestor of `HEAD`, with `contracts/` clean; `fanout.sh` extracts
`contracts/` at exactly that SHA with `git archive` and grants the slices nothing else, so
an agent cannot read a contract that moved after the freeze even if it wants to. The
ordering is a machine fact.

Meanwhile the surface had grown to nine documented entry points for one activity —
`plan-cross-repo-change` → `freeze-contract` (or `align-contract`) → `/ship` → `make
iterate` / `make verify` / `make smoke`, plus `deploy-to-aws` — and the symptom ADR 0003
warned about arrived: prose that no mechanism held to account drifted. `concept.md` reached
838 lines still teaching readers to run `fanout.sh` in a form `docs/adr/0002` had replaced.
The freeze discipline was written out in eight places, the `local`/`remote` tag semantics in
five, "the real environment wins" in seven. Three guards read as protection and were not:
`DEV_ENV_DEFAULTED` was consumed and never set, `agentapp.owner` labels were read and never
declared, and `harvest-contract.py --diff` was documented in three places as a gate
`verify.sh` runs and had no caller at all.

And "the pull requests are open" — the thing a human acts on — was an unverified claim. The
dispatched agent was asked in prose to open one and to report a URL; nothing pushed, nothing
called `gh`, nothing checked.

## Decision

**Two commands, and nothing else.**

1. **`/ship`** is the whole cross-repo lane: plan artifact, contract freeze, gate, dispatch
   and repair loop, then the pull requests. One invocation, five phases, each ending at a
   gate.
2. **`/realign`** is the whole after-the-merge lane: bump the submodules, re-check the
   contract against what is actually served, re-run the baseline suite, pin the triple,
   promote the durable smoke steps.
3. **Single-repo work uses no harness at all** — `cd <repo> && claude`. It is ~80% of the
   work and it should cost nothing.

Consequences that are part of the decision:

- **The four skills are deleted.** Their content was reference, not procedure: a skill
  activates on the model's judgement, and reference that must be *exactly* right when it is
  read belongs in a file read on purpose. The infra Make-target interface moved to
  `docs/infra-interface.md`, the freeze and harvest discipline to `contracts/README.md`, the
  planning doctrine into `/ship` itself.
- **The freeze precedes dispatch; it does not require its own session.** The invariant is
  the commit ordering, and the gate enforces it. "A separate session" was a proxy that cost
  three handoffs and bought nothing `manifest.py` does not already buy.
- **PR creation is mechanical.** `scripts/prs.sh --create` pushes and opens what is missing,
  idempotently, and writes `prs.json`. `iterate.sh` calls it on a green outcome. The agent's
  claimed `pr` field stays in `fanout.json` as a claim; `prs.json` is the fact.
- **A gate that is documented is called.** The three dead guards are wired rather than
  deleted, and `check-docs.py` grows two checks: every slash command named in prose exists and
  is routed to, and no prose presents `fanout.sh`, `iterate.sh` or `verify.sh` as a
  user-facing entry point. That last one is the drift that produced this ADR.

## Consequences

One place to look for each of the two things this repo does. `concept.md` becomes an
orientation document at a fifth of its length, holding reasoning rather than quoted file
bodies — the part that rotted.

Accepted costs:

- **One session now holds plan authority, freeze authority and deploy credentials.** ADR
  0001 deliberately made the control session powerless and ADR 0004 already gave it deploy
  credentials; this removes the last structural separation. What remains is the gate, the
  `plan` exit-3 guardrail, and `prod`'s absence from the allowlist. That is a real
  reduction in defence-in-depth, taken because the separation was enforced by prose and
  prose was demonstrably not holding.
- **`/ship` is a long command, and a long command can be partially executed.** Phases 2 and
  3 are the ones that matter, and phase 3 fails closed if 2 was skipped — but a model that
  stops after phase 1 now leaves a half-done change where previously it had reached a
  natural boundary. The mitigation is that the gate names exactly what is missing.
- **Commands do not auto-activate.** A skill could fire when its description matched; a
  command must be typed or invoked deliberately. That is the point — the previous behaviour
  meant four skills competing to describe one activity — but it does mean an agent that
  reads neither `CLAUDE.md` nor `README.md` gets no guidance at all. `CLAUDE.md`'s lane
  table is therefore the load-bearing routing, and `check-docs.py` now holds it to that.
- **Deleting skills deletes their nuance.** The expand-and-contract default, the
  operationId rewrite, the "delete surface that should not be public" instruction: each is
  now one sentence where it used to be a paragraph. Compression loses something real, and
  the bet is that a paragraph nobody loads is worth less than a sentence in a file that is
  always read.
- **`prs.sh` gives the control session push access to the product repos.** Narrow — it
  pushes an existing local branch and opens a PR, never merges — but it is new reach.

## Alternatives considered

- **Keep the skills and shorten them.** Rejected by ADR 0003's own thesis and by
  `docs/init/README.md`'s drift signal: if a written rule is repeatedly violated, add a
  mechanism, do not add emphasis. Four skills describing one activity is a routing problem,
  not a length problem.
- **One command for everything, `/ship` with a `--realign` mode.** Rejected: the two have
  different preconditions (one requires a clean `contracts/` and unmerged branches, the
  other requires the PRs already merged) and different failure modes. Collapsing them would
  make the argument decide which set of preconditions applies, which is exactly the kind of
  thing a reader gets wrong.
- **Keep `plan` as its own command, so the human reviews the artifact before dispatch.**
  Genuinely tempting, and it is what ADR 0001 intended. Rejected because the review that
  matters is of the *acceptance criteria*, and those are readable in `smoke.yaml` at any
  point including after a failed run — whereas the handoff cost was paid on every change.
  `--verify-only` and `--no-repair` remain for anyone who wants a smaller step.
- **Have the dispatched agent report its PR and trust it, as before.** Rejected for the
  reason ADR 0002 gives: agents implement, they do not decide whether the change is done.
  A URL nothing fetched is not evidence.

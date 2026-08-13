# 0001 — Contract-first polyrepo with a control repo

**Status:** accepted
**Date:** 2026-08-13

## Context

A three-tier system (API service, web client, infrastructure) developed primarily
through AI coding agents. Two properties had to hold at once:

1. Each tier keeps its own git history, CI pipeline, deploy cadence, secret scope and
   observability. A shared pipeline couples deploy risk across tiers that have very
   different review requirements — infra is gated, the app repos are per-merge.
2. Agents working in separate repos must not each invent their own version of the
   interface between them. Three agents allowed to re-derive an interface will, and
   they will disagree in small ways that surface in production rather than in review.

Prose instructions do not solve (2). Instruction text cannot fail a build.

## Decision

Four repositories: three product repos, plus a control repo that vendors them as git
submodules and owns `contracts/`.

- The control repo is the only place `contracts/` is edited. Product repos vendor a
  read-only copy and verify conformance in their own CI.
- Contract changes are sequential and single-session; implementation is parallel.
  Never both at once. The commit that lands a contract change is its freeze point.
- The control repo's `CLAUDE.md` is additive context, never load-bearing. Every
  product repo is fully self-describing in isolation, because CI clones each one on
  its own and a developer may clone only one.

## Consequences

**Makes easy.** Independent deploy cadence and secret scope per tier. A single-repo
change — around 80% of the work — carries no cross-repo overhead at all: the session
sees one repo and nothing else. Coordination is enforced mechanically rather than
argued about.

**Accepted costs.**

- A feature spanning all three repos produces three pull requests and three CI runs,
  and cannot merge atomically.
- Version skew between repos is a permanent tax, paid via expand-contract migrations
  and feature flags. Production will always briefly run mismatched versions.
- Submodules are a sharp edge: detached HEAD on update, and stale pointers after
  product-repo merges. Mitigated by `scripts/`, the `CLAUDE.md` hard rules and
  `repos.lock` — mitigated, not removed.

**Fallback.** If the three-PR overhead becomes the dominant source of friction, merge
backend + frontend + contracts into one repo and keep infra separate.

## Alternatives considered

- **Monorepo.** Removes skew and atomic-merge pain, but couples deploy cadence and
  blast radius across tiers, and puts the whole tree in every agent session's reach.
- **Polyrepo with no control repo, interface agreed in prose.** Cheapest to set up;
  fails exactly where it matters, since nothing verifies the agreement.
- **An orchestrating agent that coordinates the three repos.** Substitutes a
  non-deterministic coordinator for a machine-readable artifact. The artifact can
  fail a build; the coordinator can only be persuasive.

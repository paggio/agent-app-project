# 0021 — The local stack is seeded with a metrics release

**Status:** accepted
**Date:** 2026-11-27

## Context

The joined stack starts cold (`docs/adr/0011`), and only a change's `jobs:` published a
metrics release. A job's owner must be a slice. 0009 put a real-backend metrics test in the
frontend's e2e, so 0010 — which touched neither analytics-dbt nor metrics-gateway — failed
e2e on `no_release`, and the repair went to a frontend that could not fix it.

## Decision

`verify.sh` runs `scripts/seed-local.sh` after the stack is up and before smoke, for every
change that declares no jobs: `dbt-release`, then `indexer`. A change with jobs owns its state
sequence from cold volumes and is not seeded. A failed seed is the owner's when that repo is
a slice, `fault: harness` otherwise. The seed is not an assertion and is counted nowhere.

## Consequences

- Every suite, and every product repo's e2e, may assume a served release locally.
- Verify costs the two jobs' runtime (seconds on 0009's data).
- A broken release job now fails changes that did not touch it — attributed to the harness,
  not dispatched.

## Alternatives considered

- Skip metrics tests when no release is served — keeps a criterion that never runs locally.
- Let a job's owner be a non-slice — a failure then routes to nobody.

# 0011 — The local stack forgets everything on `down`

**Status:** accepted
**Date:** 2026-09-02
**Relation to 0002 and 0006:** extends both. 0002 made this repo the owner of the joined
stack; 0006 said what configuration it may read. This says what STATE it is allowed to
keep, and for how long.

## Context

`make down` has always run `docker compose down -v`, so the joined stack has always come
back cold. Nothing said so, nothing checked it, and the property was one bind mount away
from quietly ending.

0005 is what made that worth writing down. It adds Phoenix, whose entire value is a
history — and a history is exactly the thing somebody reaches for a host bind mount to
preserve. Measured before deciding anything: 33 traces in the `chatbot-backend` project,
then `make down && make up`, then the project gone. The behaviour was already right.

Two ways it could stop being right, neither of which any existing gate would notice:

1. **A host bind mount.** `- ./data:/mnt/data` survives `down -v` because it is not a
   volume Compose owns. The stack would then come back warm, and the first symptom would
   be a smoke run passing on data an earlier run left behind.
2. **An `external: true` volume.** Same outcome, declared more deliberately, and it would
   read as an intentional exception in review rather than the invariant break it is.

Both live in the product repos' compose files, which this repo may read and may not edit —
so a gate here is the only thing that can see them.

## Decision

**`down` is a clean slate, and no service in the joined stack may keep state anywhere
`down -v` cannot reach.** Every persistent path is a project-scoped named volume declared
in the compose file that declares the service. No host bind mount for data, no
`external: true`.

`scripts/check-docs.py` § `[clean-slate]` enforces it across `stack/compose.yml` and both
included files, and names the service and the mount when it fails.

Two consequences that are part of the decision rather than side effects:

- **`stack.sh restart <svc>` exists precisely because `down` is destructive.** Restarting
  one service keeps its volume, which is what `make phoenix-durability` needs in order to
  ask whether a trace outlived a restart. A durability check that used `down` would be
  asserting that data survives its own deletion.
- **A developer who wants to keep a trace exports it.** Phoenix's REST API answers, and the
  span data is not the artefact anyway — a change's `evidence/` directory is.

## Consequences

**Makes easy.** A run cannot pass on a previous run's leftovers, which is the failure this
is really about: it is invisible, it is intermittent, and it makes a broken change look
green on the second attempt. `up` means the same thing on a colleague's machine as on a
fresh clone, with no "did you clear the volumes first" step in any instruction.

**Accepted costs.**

- **Losing your traces every cycle is annoying, and the annoyance is the point.** A stack
  that accumulated state across cycles would be one nobody could reason about. The cure for
  wanting the history is a longer-lived Phoenix somewhere that is not the local stack, which
  is a deployment decision and not this one.
- **A cold `up` pays for it in time** — OpenSearch's JVM, an empty index, the embedding
  model, and now Phoenix's schema migration. `up --wait` absorbs it before smoke begins, so
  it is wall-clock rather than flakiness.
- **The gate reads two files this repo does not own.** Narrowed the same way 0006 narrows
  its `.env` read: read-only, tolerant of absence, and failing with the service and the
  mount named so the fix is obvious in the repo that must make it.
- **It does not govern a product repo's OWN stack.** `cd chatbot-backend && make up` is that
  repo's business. The rule binds the joined stack, which is this repo's.

## Alternatives considered

- **Leave it undocumented, since it already works.** Rejected for the reason 0006 rejects
  the same argument: a behaviour nothing asserts is one that regresses without a failure,
  and this one regresses into passing tests rather than failing ones.
- **A `make down-hard` that also prunes, leaving `down` gentle.** Rejected. Two teardowns
  means every instruction has to say which, and the wrong one is always the default.
- **Let Phoenix keep its data and drop everything else.** Tempting, and it is the one people
  will ask for. Rejected: "clean except for one service" is not a property anybody can hold
  in their head, and Phoenix's data is derived from runs — a trace store outliving the runs
  it describes is a store full of traces pointing at code that no longer exists.

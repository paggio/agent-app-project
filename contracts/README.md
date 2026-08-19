# contracts/ — owned here, consumed everywhere

The interface between the three product repos. Edited only in this repo, only in a
sequential single-purpose session, and frozen by commit before any implementation
starts. Each product repo vendors a copy and verifies conformance in its own CI.

| File | Interface |
| --- | --- |
| `openapi.yaml` | HTTP |
| `events/*.schema.json` | async messages |
| `infra-outputs.yaml` | what infra promises the app repos (ARNs, URLs, secret names) |

`openapi.yaml` describes the API as the backend serves it — paths without the `/api`
prefix, which the proxy strips before forwarding. `events/` and `infra-outputs.yaml` are
still empty skeletons; fill them in when the first real interface exists, because an
invented contract is worse than no contract.

**`openapi.yaml` is machine-rewritten.** `./scripts/harvest-contract.py --write` drafts
it from a running service, so YAML comments inside it do not survive. Durable guidance
belongs in this file. Prose you write in the spec — `summary`, `description`,
`operationId`, `tags` — IS preserved across re-harvests; only structure is retaken from
the implementation.

## Changing a contract

1. Additive by default. The repos deploy independently, so production will always
   briefly run mismatched versions: new fields optional, new entries alongside old
   ones, removals in a later change once every consumer is updated.
2. One commit, nothing else in the diff. That commit is the freeze point.
3. Record its SHA as `freeze_sha` in the change's `change.yaml`.
4. Only then fan out.

## Which way round

Two skills, one destination — a reviewed contract, committed alone. They differ only in
where the first draft comes from.

| | Skill |
| --- | --- |
| The interface does not exist yet; you are deciding it | `freeze-contract` |
| It exists and works; you are promoting it to a promise | `align-contract` |

Neither lets the implementation decide. `harvest-contract.py` drafts and classifies —
additive versus breaking, judged by what it would do to a consumer — and refuses to
write a breaking change until you pass `--accept-breaking`. A contract that
automatically matched the implementation could never fail a build, which is the whole
thing `docs/adr/0001` was written to prevent.

## What enforces this

- `./scripts/harvest-contract.py --diff` — contract versus what is actually served
- `./scripts/smoke.py --contract` — every asserted request must be declared surface,
  with a declared status. Run on every deploy by `verify.sh`.
- each product repo's own `make contract` — note it HARD-FAILS if `openapi.yaml` is
  vendored with no conformance check wired, so vendoring and wiring must land together.

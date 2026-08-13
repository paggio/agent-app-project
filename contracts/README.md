# contracts/ — owned here, consumed everywhere

The interface between the three product repos. Edited only in this repo, only in a
sequential single-purpose session, and frozen by commit before any implementation
starts. Each product repo vendors a copy and verifies conformance in its own CI.

| File | Interface |
| --- | --- |
| `openapi.yaml` | HTTP |
| `events/*.schema.json` | async messages |
| `infra-outputs.yaml` | what infra promises the app repos (ARNs, URLs, secret names) |

The files currently here are empty skeletons. Fill them in when the first real
interface exists — an invented contract is worse than no contract.

## Changing a contract

1. Additive by default. The repos deploy independently, so production will always
   briefly run mismatched versions: new fields optional, new entries alongside old
   ones, removals in a later change once every consumer is updated.
2. One commit, nothing else in the diff. That commit is the freeze point.
3. Record its SHA in the change's `BRIEF.md`.
4. Only then fan out.

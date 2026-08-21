---
name: freeze-contract
description: Changing contracts/ — the OpenAPI spec, event schemas or infra outputs. Use when an interface between repos needs to change, or before fanning out a cross-repo change.
---

`contracts/` is the coordination mechanism. Three agents in three repos will each
re-derive an interface if allowed to, and they will disagree in small ways. Prose
cannot prevent that; a contract that fails a build can.

## Rules

- This repo is the only place `contracts/` is edited. Product repos vendor a copy and
  their CI verifies against it.
- One session, sequential. No implementation work in the same session.
- The commit that lands the contract change IS the freeze point. Record its SHA as
  `freeze_sha` in the change's `change.yaml` before any fan-out.
- **Nothing reads `BRIEF.md` for the SHA.** `docs/adr/0002` removed that mechanism because
  the check was a `grep` for hex, which any stray string in prose satisfied — so a change
  could fan out against an unfrozen contract and warn about nothing. `manifest.py` and
  `fanout.sh` read `change.yaml` and only `change.yaml`.

## Order of work

1. Read the brief's acceptance criteria and the current `contracts/`.
2. Make the change additive wherever possible — the three repos deploy independently
   and production will run mismatched versions. New fields optional, new endpoints
   alongside old ones, removals in a later change once consumers are updated.
3. Validate the artifacts (schema/spec linting) before committing.
4. Commit alone, with no other changes in the diff.
5. Record that commit as `freeze_sha` in the change's `change.yaml`. Confirm with
   `./scripts/manifest.py changes/<change> --validate`, which checks the SHA is a real
   commit, that it is an ancestor of HEAD, and that `contracts/` is clean.

`infra-outputs.yaml` is a contract like any other: promoting an output is a freeze pass,
with the same one-commit-alone discipline. See `docs/adr/0004`.

## After freezing

Fan out. If an implementing agent reports that its slice needs a contract change, it
must STOP rather than work around it — that report comes back here as a new freeze
pass, not as a local patch. Mechanically that is a slice returning
`status: "blocked-by-contract"` with a `contract_gap`, which stops the whole change with
no retry; the loop reports `contract-gap` and the gap text lands in `report.md`.

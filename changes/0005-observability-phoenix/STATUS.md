# 0005 — status

## Contract freeze

- SHA: `dfbb48f8f081c08ccda14d07928c299f01928a81`
- Frozen: 2026-09-01

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0005-observability-phoenix` | <link> | ☐ | ☐ |
| control (this repo) | `feat/0005-observability-phoenix` | <link> | ☐ | ☐ |

No frontend or infra row: neither repo changes. See BRIEF.md § Out of scope.

Merge order: **chatbot-backend first.** It is backward compatible on its own — a response
header nobody reads yet, and two new local-dev services. The control repo's PR carries the
suite that asserts them, so merging it first leaves `main` with a suite that fails against
the backend on `main`.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
_Never run._
<!-- iterate:end -->

## Blockers

- None.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`
- [ ] `/realign` — and decide there whether the trace steps are durable enough to promote
      into `smoke/baseline.yaml`. They assert a service no other change depends on, so the
      answer is not automatically yes.

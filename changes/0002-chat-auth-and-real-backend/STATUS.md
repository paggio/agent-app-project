# 0002 — status

## Contract freeze

- SHA: recorded as `freeze_sha` in `change.yaml`, which is the only place anything reads it
- Frozen: 2026-08-21
- What moved: `contracts/openapi.yaml` 1.1.0 → 1.2.0 — `postChat` gains
  `security: [{cookieAuth: []}]` and a `401` `ErrorResponse`. Non-additive, on purpose;
  the reasons are in `BRIEF.md` § "Contract changes".
- **Re-frozen once.** The first freeze was `bbd2256`. The harvest gate then blocked the
  run on `RegisterRequest.display_name`, which the implementation has served as
  `anyOf: [string, null]` since change 0001 while the contract promised a bare
  `type: string`. Neither slice touched it; the drift predates this change and was never
  gated, because the harvest stage was wired after 0001 was verified. The second freeze
  declares the nullable union, and `harvest-contract.py --diff` then reports agreement.
- **Vendored copies: settled, and the harness changed because of it.** Both were briefly
  out of step — the frontend re-vendored at the first freeze, the backend could not vendor
  at all because writes into `contracts/` are denied in that session. Asking a slice to
  copy a file it is forbidden to touch was the harness's mistake, not the slice's:
  `docs/adr/0008` makes the control repo publish the vendored specs from the freeze SHA
  before dispatch, and `verify.sh` compares them in preflight. Both copies now match the
  second freeze byte for byte.

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0002-chat-auth-and-real-backend` | [#5](https://github.com/Paggio/chatbot-backend/pull/5) | ☐ | ☐ |
| frontend | `feat/0002-chat-auth-and-real-backend` | [#4](https://github.com/Paggio/frontend/pull/4) | ☐ | ☐ |

Recorded mechanically in `runs/20260821T173105Z/prs.json` — `prs.sh` reported both as
already open rather than creating duplicates.

No infra slice in this change.

**Merge order: chatbot-backend, then frontend.** Both orders are in fact safe — a
deployed old frontend never calls `/v1/chat`, and a new frontend against an old backend
gets a `200` — so this order is chosen for the ordinary reason rather than a forced one:
the backend half is the security fix and it is self-contained.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
- **verified** — 20260821T173105Z, 1 attempt(s)
- report: `changes/0002-chat-auth-and-real-backend/runs/20260821T173105Z/report.md`
<!-- iterate:end -->

## Blockers

- None blocking this change. One adjacent fact worth carrying forward: the deployed task
  role still lacks `bedrock:InvokeModel` on the inference-profile ARN and the
  foundation-model ARNs the cross-region profile spans (`chatbot-backend/docs/adr/0004`).
  Nothing here deploys, so nothing here is blocked by it — but the first real chat turn in
  the cloud fails on authorization until an `infra/` change lands it.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`
- [ ] `/realign` — bump the submodules, re-harvest the contract against what is served,
      re-run the baseline, and promote the durable steps from `smoke.yaml` into
      `smoke/baseline.yaml`. The two worth promoting are
      `chat-without-a-session-is-refused` and `revoked-session-cannot-chat`: an open
      billable endpoint is exactly the kind of regression a baseline exists to catch.

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
- **Known divergence to settle in `/realign`:** `frontend/contracts/openapi.yaml` was
  re-vendored by its slice at the FIRST freeze, and `chatbot-backend/contracts/openapi.yaml`
  is still at `1.1.0` because writes into `contracts/` are blocked in that session. So the
  two vendored copies disagree with each other and with the second freeze. Nothing in the
  harness syncs them; `/realign` is the lane that must.

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0002-chat-auth-and-real-backend` | opened by `prs.sh` on a green outcome | ☐ | ☐ |
| frontend | `feat/0002-chat-auth-and-real-backend` | opened by `prs.sh` on a green outcome | ☐ | ☐ |

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
- **unattributable** — 20260821T163053Z, 2 attempt(s)
- report: `changes/0002-chat-auth-and-real-backend/runs/20260821T163053Z/report.md`
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

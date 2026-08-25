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
| chatbot-backend | `feat/0002-chat-auth-and-real-backend` | [#5](https://github.com/Paggio/chatbot-backend/pull/5) | ☑ | ☑ `ceb0365` |
| frontend | `feat/0002-chat-auth-and-real-backend` | [#4](https://github.com/Paggio/frontend/pull/4) | ☑ | ☑ `9ce42ea` |
| agent-app-project | `feat/0002-chat-auth-and-real-backend` | [#6](https://github.com/Paggio/agent-app-project/pull/6) | ☑ | ☑ **into the wrong base** |

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

- [x] `./scripts/lock.sh` and commit `repos.lock` — `d589855`
- [x] `/realign` — 2026-08-25. Submodules bumped to merged main, contract agrees with what
      is served, baseline green at 14 assertions, `make e2e` green at 30.

### What realign found first

This change's control-repo half was **not on `main`**. PR #6 was opened against
`chore/two-command-harness` instead of `main`, and that base had already merged to `main`
via PR #5 seventeen hours earlier — so the merge succeeded onto a branch nothing merges
onward. The contract freeze, this directory, `docs/adr/0006-0008` and five harness fixes
were stranded there while both product PRs were merged and deployed.

The two findings `harvest-contract.py --diff` reported against `main` — an undeclared `401`
on `postChat`, and `display_name` as a BREAKING request change — were both symptoms of
that, not drift to fix. Recovering the branch (`6c296b6`) brought the freeze *and* the
`anyOf` fix that resolves the second finding, after which the harvest reports agreement.
Nothing was re-authored on top of `main`.

### Promotion: seven steps, not the two named above

The note here named `chat-without-a-session-is-refused` and `revoked-session-cannot-chat`.
Promoting only those two would not have worked:

- `revoked-session-cannot-chat` replays a captured cookie, so it needs
  `register-a-chat-account` and `login-establishes-the-session` ahead of it or it sends
  nothing and silently becomes a copy of the anonymous case.
- Both named steps assert a `401`. A backend whose gate is stuck closed passes both. So
  `chat-with-a-session-answers` and `chat-still-validates-the-body` came too, and they are
  what keeps the block from being a tautology.

Only `chat-route-deep-links-to-the-app` stayed behind: it is SPA fallback already covered
by `origin-serves-app`, provable inside the frontend, and says nothing about the UI calling
the backend.

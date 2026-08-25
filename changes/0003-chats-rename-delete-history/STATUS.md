# 0003 — status

## Contract freeze

- SHA: `4bcea59` — recorded as `freeze_sha` in `change.yaml`, which is the only place
  anything READS it; this line is prose for a human and nothing parses it
- Frozen: 2026-08-25
- What moved: `contracts/openapi.yaml` 1.2.0 → 1.3.0 — six new paths under `/v1/threads`,
  nine new schemas, and `THREAD_NOT_FOUND` added to `AuthError.code`'s documented values.
  Additive throughout: nothing existing changes shape and `/v1/chat` is untouched.
  `contracts/README.md` gains § "Chats, ownership and titles" and adds `404` to the error
  envelope's list of statuses.

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0003-chats-rename-delete-history` | <pending> | ☐ | ☐ |
| frontend | `feat/0003-chats-rename-delete-history` | <pending> | ☐ | ☐ |

No infra slice in this change.

**Merge order: chatbot-backend, then frontend.** This one is forced, not a preference. The
backend half is additive and safe alone — it adds tables and paths, changes nothing existing,
and a deployed old frontend never calls the new endpoints. The frontend half is NOT safe
alone: it sends chats through `/v1/threads/{id}/messages`, so a frontend deployed against a
backend without it gets a 404 on every send and the app is broken for everyone.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
_Never run._
<!-- iterate:end -->

## Blockers

- None blocking this change. Two adjacent facts carried forward rather than fixed here:
  the deployed task role still lacks `bedrock:InvokeModel` (nothing here deploys, so nothing
  here is blocked by it — but history makes the first real cloud turn more expensive when it
  lands), and the rate-limit buckets remain per-process, so the new per-account limit on
  sending multiplies by replica count above one replica.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`
- [ ] `/realign`

### Promotion note for `/realign`

Candidates for `smoke/baseline.yaml`, and the dependency that decides them: the ownership
block is the durable regression, but promoting `another-user-cannot-*` alone would not work —
all three assert a `404`, which a backend whose chats are simply unreachable also returns. The
block only means something with `create-a-chat`, `first-message-titles-the-chat` and
`the-chat-survived-the-other-users-attempts` ahead of it, and that last step is the one that
tells an ownership check apart from a delete. Take the block or take none of it.

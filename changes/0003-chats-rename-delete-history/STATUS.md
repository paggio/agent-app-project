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
| chatbot-backend | `feat/0003-chats-rename-delete-history` | [#6](https://github.com/Paggio/chatbot-backend/pull/6) | ☐ | ☐ |
| frontend | `feat/0003-chats-rename-delete-history` | [#5](https://github.com/Paggio/frontend/pull/5) | ☐ | ☐ |

Recorded mechanically in `runs/20260825T115532Z/prs.json` — `prs.sh` reported both as
already open rather than creating duplicates, because each slice opened its own.

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
- **verified** — 20260825T115532Z, 1 attempt(s)
- report: `changes/0003-chats-rename-delete-history/runs/20260825T115532Z/report.md`
<!-- iterate:end -->

## What the green run does and does not cover

**39 assertions, 25 of them from this change's own suite, plus 46 Playwright tests.** The
browser stage is the one that matters here, and it ran the four `real-backend.spec.ts` tests
that normally skip for want of a backend — including `a renamed chat still shows its new name
after a full page reload` and `a deleted chat is gone from the sidebar and stays gone after a
reload`, which are criterion 8 and the only evidence for it.

**The green run used `CHAT_MODEL=echo`, and that is not the usual local default.** The first
run went to Bedrock, because `stack/dev.env` deliberately leaves `CHAT_MODEL` undeclared so
it falls through to `chatbot-backend/.env` (`docs/adr/0006`), and every model call returned
`500`:

```
botocore.exceptions.ClientError: An error occurred (ExpiredTokenException) when calling
the Converse operation: The security token included in the request is expired
```

An expired local AWS session token, not a defect in either slice. The tell is that
`chat-with-a-session-answers` failed with it — a **baseline** step that predates this change
— while every assertion that does not invoke a model passed, on both attempts. The other four
failures were downstream of it: no turn could be stored, so the transcript was empty. Re-run
with `CHAT_MODEL=echo` and the same checked-out code, it is green. Renew the credentials to
exercise the Bedrock path.

## Blockers

- None blocking this change. Three adjacent facts carried forward rather than fixed here:
  the deployed task role still lacks `bedrock:InvokeModel` (nothing here deploys, so nothing
  here is blocked by it — but history makes the first real cloud turn more expensive when it
  lands); the rate-limit buckets remain per-process, so the new per-account limit on sending
  multiplies by replica count above one replica; and the local Bedrock credentials above are
  expired, so a credential-free `CHAT_MODEL=echo` is the only way to get a green local run
  today.

## Two findings for the next pass

**1. The contract is narrower than what is served, additively.** `harvest-contract.py --diff`
reports `GET` and `DELETE /v1/threads/{thread_id}` returning an undeclared `422` — the one
the framework emits for path-parameter validation on any path that has a parameter. It
classified both as "additive — safe to promise", which is why the gate passed rather than
blocked. Left unfrozen on purpose: declaring it now means a re-freeze, and a re-freeze makes
both slices' committed vendored copies stale for a difference no consumer can act on. This is
exactly what the harvest path in `contracts/README.md` § "Changing a contract" is for, so
**promote it at `/realign`** rather than re-freezing here.

**2. The harness charged a slice for an environment fault.** `verify.json` recorded
`fault: slice` and `owners_failing: [chatbot-backend]` for an expired upstream credential,
then spent a full repair session dispatching an agent that could not possibly fix it — the
second attempt produced the identical five failures. `docs/adr/0003` has `fault: harness` for
"this repo's bug" and nothing for "the environment this ran in". A `500` whose container log
is an upstream `ExpiredTokenException`, on a step that was passing in the baseline before the
change, is distinguishable from a slice regression and worth classifying as such — it would
have saved an attempt and pointed at the real fix.

The sharper version: **the diagnosis was already in the run artifacts and nothing read it.**
The repair agent's own structured result says it plainly —

> `"reason": "Gates green and PR open; the 5 failures were the expired AWS token in`
> `gitignored .env (CHAT_MODEL=bedrock). Needs aws sso login or CHAT_MODEL=echo — .env`
> `writes are denied to me."`

— and `iterate.sh` recorded `fault: slice` over the top of it. `docs/adr/0003` is right that
an agent does not get to decide whether the change is done; that is not the same as its report
being worthless as *evidence*. Its own change, not this one.

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

# 0003 — chatbot-backend slice

Chats become durable objects owned by an account, with rename and delete, and a turn is
answered with the earlier turns of that chat supplied to the model.

`POST /v1/chat` is NOT touched. It keeps its current shape and its current stateless
behaviour, because consumers deploy independently and an old client must keep working. The
new surface arrives alongside it.

## What to build

- **Two tables, one numbered migration.** A chat, owned by exactly one account, and its
  messages. Ownership is a real foreign key to the account, and deleting a chat deletes its
  messages — the contract promises a hard delete, so there is no soft-delete column and no
  `deleted_at`. Messages carry a role (`user` or `assistant`) and an ordering that is stable
  under equal timestamps; two turns written in the same millisecond must still read back in
  the order they happened.

- **The six endpoints in the frozen contract**, all of them requiring a live session
  through the same dependency `/v1/chat` already uses. There is no second way to resolve a
  session in this repo and this slice must not introduce one.

- **Ownership is decided in SQL, never by filtering in Python.** Every statement that reads
  or mutates a chat is scoped by the account in the same `WHERE` clause that finds it, so no
  path can forget. This is the same rule the session expiry already follows and for the same
  reason: a check that lives in one place cannot be skipped in another.

- **"Not yours" and "does not exist" are one answer:** `404` with `THREAD_NOT_FOUND` in the
  error envelope, byte-identical in both cases. A `403` would confirm the chat exists and
  make the endpoint an enumeration oracle for other people's chat ids — the same reasoning
  that already makes an unknown email and a wrong password return an identical `401`.

- **The title.** Derived server-side from the first user message when the chat has never
  been given one explicitly, so a client never has to invent a title and two clients cannot
  derive different ones. Derived exactly once: after a `PATCH` sets a title, later messages
  never overwrite it. That "explicitly named" state is internal — the contract exposes only
  `title`, and nothing about how it got there.

- **History reaches the model.** A turn is answered with the earlier turns of the same chat
  supplied as context, bounded — a recent window, with a configured maximum, and turns that
  fall outside it are simply not sent. No summarisation, no compaction.

  Two constraints on how:

  - **The stored transcript is the only source of history.** Do not configure a graph
    checkpointer as a second store. Two records of one conversation is a divergence with no
    tie-breaker, and the transcript is the one a person reads back.
  - **The existing module boundary holds.** `graph/` must not learn HTTP types and `api/`
    must not learn the model library's message types. The seam that carries a turn today
    carries plain values; extending it to carry prior turns must keep that true — plain
    roles and strings across the boundary, and the translation into model messages on the
    graph side.

- **The message endpoint is rate limited per account**, answering `429 AUTH_RATE_LIMITED`
  with `Retry-After` in seconds, using this repo's existing throttle rather than a second
  mechanism. This is in scope *because* of history: a signed-in account could already spend
  without limit, and sending prior turns multiplies what one request costs. The buckets are
  per-process, so above one replica the effective limit multiplies — that is an inherited
  limitation, already recorded here, and not this slice's to fix.

- **No `GET` mutates anything.** Reading a chat or listing chats must not touch
  `updated_at`, must not extend anything and must not write a row. The whole CSRF posture
  rests on it.

- **Commit the vendored `contracts/` copy** the dispatch published into this repo, with the
  rest of the work, so the promise travels with the pull request and CI verifies against the
  contract this was built for.

## Contract entries this depends on

- `contracts/openapi.yaml` → `POST /v1/threads` (`postThreadCreate`), `GET /v1/threads`
  (`getThreadList`), `GET /v1/threads/{thread_id}` (`getThread`),
  `PATCH /v1/threads/{thread_id}` (`patchThread`), `DELETE /v1/threads/{thread_id}`
  (`deleteThread`), `POST /v1/threads/{thread_id}/messages` (`postThreadMessage`)
- `contracts/openapi.yaml` → schemas `Thread`, `Message`, `ThreadResponse`,
  `ThreadListResponse`, `ThreadDetailResponse`, `CreateThreadRequest`,
  `RenameThreadRequest`, `SendMessageRequest`, `SendMessageResponse`
- `contracts/openapi.yaml` → `AuthError.code` now documents `THREAD_NOT_FOUND`
- `contracts/README.md` → § "Chats, ownership and titles" (the 404 rule, the title rule,
  what history promises and what it does not) and the `404` added to the error envelope's
  list of statuses
- `contracts/openapi.yaml` → `POST /v1/chat` unchanged, and its declared caps
  (`message` 1–8000) are the same caps the new message endpoint declares

The contracts are FROZEN. If this slice appears to require a contract change, STOP and
report it rather than working around it.

## Verification

- [ ] the migration applies to an empty database and to one that already holds accounts and
      sessions, from the lifespan, before the app serves
- [ ] **criterion 7 — history reaches the model.** A test with a fake model that RECORDS the
      messages it was handed, asserting the second turn of a chat is invoked with the first
      turn's user message and reply present, and the first turn is invoked with neither.
      This is the only evidence for that criterion anywhere in the system: the joined smoke
      suite runs `CHAT_MODEL=echo`, which has nothing to remember with, so no assertion at
      the seam can see it. If this test does not exist, the criterion is unproven no matter
      how green everything else is.
- [ ] the history window is bounded, proved by a chat longer than the window: the oldest
      turns are absent from what the model receives, and the request still succeeds
- [ ] **criterion 9 — the rate limit.** The per-account bucket returns `429` with
      `Retry-After` once the limit is reached, with the clock and the bucket injected rather
      than slept through. Also the only evidence for its criterion; reaching the limit at the
      seam would buy one completion per request.
- [ ] a chat's title is derived from the first message, and a renamed chat's title is NOT
      re-derived by a later message
- [ ] every read path is scoped by account, proved by a test where a second account's
      request for the first account's chat is `404` **and the chat is then still readable by
      its owner** — asserting the 404 alone passes for an implementation that deleted it
- [ ] deleting a chat deletes its messages, with no orphaned rows left behind
- [ ] `POST /v1/chat` behaves exactly as before, history included: it gets none
- [ ] `make contract` passes against the vendored spec
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`)

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys all of them together and runs
`smoke.yaml` against one origin. Every step in that suite except one is yours:

- [ ] `creating-a-chat-requires-a-session` / `listing-chats-requires-a-session` — both
      anonymous, `401 AUTH_REQUIRED`, and the refusal creates nothing and lists nothing
- [ ] `create-a-chat`, `chat-appears-in-its-owners-list` — it exists and it is listed
- [ ] `first-message-titles-the-chat`, `a-chat-gets-a-title-without-being-asked` — a reply
      arrives and the chat has a non-empty title nobody supplied
- [ ] `a-second-message-is-accepted` — the turn that carries history succeeds
- [ ] `transcript-persists-in-order` — four messages, `message_count` correct, roles
      alternating user-first, read back from storage
- [ ] `rename-a-chat`, `rename-survives-a-reread`, `the-list-shows-the-new-name` — the
      rename is stored, not echoed, and the list reflects it
- [ ] `another-user-cannot-read-the-chat` / `-rename-` / `-delete-the-chat` — three
      identical `404 THREAD_NOT_FOUND`
- [ ] `the-other-users-list-does-not-contain-it` — the LIST is scoped too, not just the
      detail read
- [ ] `the-chat-survived-the-other-users-attempts` — **the one to read first if anything
      here fails.** The three 404s above are satisfied by a backend that deletes the chat
      and then reports it missing. This step is the owner reading it back afterwards.
- [ ] `the-owner-deletes-the-chat`, `a-deleted-chat-is-gone`,
      `a-deleted-chat-leaves-the-list` — `204`, then the same `404` a stranger gets, and
      gone from the list as well as the detail read

These run against your code through a reverse proxy, not against your test doubles, and a
failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- **Migration ordering.** Numbered `.sql`, applied before the app serves, additive only. It
  creates tables and touches no existing one, so an older process running against the
  migrated database is unaffected — which is what lets this merge before the frontend.
- **Backwards compatibility is the whole reason `/v1/chat` survives.** A deployed old client
  keeps calling it and keeps working. Removing it is a later change.
- **No CORS**, unchanged and not negotiable here. The new endpoints are same-origin like
  every other one, and the global cross-origin refusal on unsafe methods now covers three
  more of them.
- The declared `403 AUTH_CROSS_ORIGIN` on the new unsafe methods is that existing global
  guard being written down for paths it already applied to, not a new mechanism.
- **`Message.role` is frozen as an inline two-value enum**, so declare it as a `Literal`
  rather than an `Enum` class. An `Enum` generates a separate named schema and a `$ref`,
  which is a structural difference `harvest-contract.py --diff` reports as drift before
  smoke ever runs — and the fix for that is a re-freeze, not a code change. `Thread` and
  `Message` timestamps are `date-time`, and `CreateThreadRequest.title` is optional AND
  nullable, declared as the `anyOf: [string, 'null']` union the framework actually emits —
  the same shape `RegisterRequest.display_name` already carries, and for the same reason:
  change 0002 lost a freeze to exactly that mismatch.

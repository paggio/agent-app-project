# 0003 — Chats a user owns, can rename, and can delete

## Why

Someone signs in, has a conversation, closes the tab, and the conversation is gone. Not
archived, not unreachable — gone, because it never existed anywhere but in that browser
tab's memory. `POST /v1/chat` takes one message and returns one reply, and the contract
says plainly that it holds no thread and no history. The frontend builds a
thread-shaped interface on top of it and keeps the threads in a client-side store
(`frontend/docs/adr/0002`), so `/chat/<id>` after a refresh is a `not-found` and the
sidebar starts empty every time.

That is the real problem behind the request to rename and delete chats. There is nothing
to rename and nothing to delete: a title that vanishes on reload is not a name, and
removing something from a list that will be empty in a minute anyway is not a deletion.
"For each user" has no meaning either, because nothing about a thread is associated with
an account — a thread has no owner to hang off.

Both product repos had already identified this as the next change, independently and in
the same words. `chatbot-backend/docs/architecture.md`: *"a thread has no owner to hang
off yet. Attaching threads to a user is the next change."* `frontend/docs/architecture.md`:
*"Making threads durable is a contract change and its own brief."* This is that brief.

The second half of the cost is conversational. Every message is answered cold — no history
reaches the model, however much the transcript above it looks like context — so the
assistant cannot be asked a follow-up question. Persisting a transcript and then not
showing it to the model would make that worse rather than better: the interface would look
like a conversation the model demonstrably is not having. So durable chats and real
multi-turn context land together.

## Acceptance criteria (these are the oracle)

- [ ] 1. A signed-in caller can create a chat, and `GET /v1/threads` then lists it for
      that caller.
- [ ] 2. A chat's transcript is durable: `GET /v1/threads/{id}` returns the user turn and
      the assistant turn from a previous request, in order, each with its role.
- [ ] 3. Renaming a chat changes its title, and a *subsequent read* returns the new title —
      not merely the `PATCH` response echoing what was sent.
- [ ] 4. Deleting a chat removes it: a subsequent read is `404 THREAD_NOT_FOUND`, and the
      chat is absent from `GET /v1/threads`.
- [ ] 5. A second account cannot read, rename or delete the first account's chat. All three
      answer `404 THREAD_NOT_FOUND`, and **the chat still exists for its owner afterwards** —
      an implementation that deletes and then reports 404 satisfies the first half and fails
      this one.
- [ ] 6. Every `/v1/threads` endpoint refuses an anonymous caller `401 AUTH_REQUIRED`
      before doing any work, and a refusal carries no reply — the gate is in front of the
      model, not behind it.
- [ ] 7. The reply to the second message in a chat is produced with the earlier turns
      supplied to the model. **Not assertable at the seam** — see "A gap in the oracle".
      It is a `chatbot-backend` test against a recording fake model.
- [ ] 8. In a browser: a renamed chat still shows its new name after a full page reload, and
      a deleted chat is gone from the sidebar and stays gone after a reload. This is what
      `smoke.e2e: true` is for.
- [ ] 9. `POST /v1/threads/{id}/messages` is rate limited per account, answering
      `429 AUTH_RATE_LIMITED` with `Retry-After`. Asserted in `chatbot-backend`'s own tests,
      not at the seam — see "A gap in the oracle".

## Out of scope

Each of these was considered and left out on purpose, so a slice does not helpfully add it.

- **Removing or changing `POST /v1/chat`.** It keeps working exactly as it does today,
  stateless, with no history. The repos deploy independently and production will run
  mismatched versions, so the new surface arrives *alongside* the old one. Deprecating it is
  a later change, once nothing calls it.
- **Streaming.** Still routed to a `POST /v1/chat/stream` that does not exist. Adding it
  here would double the size of both slices and it is orthogonal to owning a chat.
- **Pagination**, on the chat list or on a transcript. Both are capped instead (200 chats,
  500 messages, most recent first) and the caps are declared in the contract. A `cursor`
  parameter is additive when someone actually has 200 chats.
- **Soft delete, undo, or a trash.** Delete is a hard delete and the contract says so. An
  undo window is a product decision nobody has made, and the reversible-looking version is
  worse than the honest irreversible one.
- **Editing or deleting individual messages.** The unit this change makes addressable is the
  chat. Message-level mutation is new surface with its own questions about what happens to
  the model's view of a thread it has already answered in.
- **Summarisation or compaction of long threads.** History is a bounded window of recent
  turns; turns that fall out of it are simply not sent. Compacting them into a summary is a
  quality feature with its own failure modes and its own brief.
- **Sharing a chat between accounts, export, and search.** Ownership in this change is
  exactly one account, and 404 is the answer to everyone else.
- **Renaming the `AuthError` schema**, which now carries a code that is not about auth. The
  name becomes historical. Renaming it changes a generated *type name* in the frontend for
  no wire benefit, in a change that is already touching both repos.
- **Account deletion**, and with it the smoke-account accumulation `docs/adr/0004` records.
  Deleting a chat is not deleting an account, and this change adds no cascade for one.
- **Moving reading positions to the server.** A real `frontend` gap, unrelated to this one.

## Contract changes

`contracts/openapi.yaml`: **additive**, `1.2.0` → `1.3.0`. Nothing existing changes shape.

- New paths: `POST /v1/threads`, `GET /v1/threads`, `GET /v1/threads/{thread_id}`,
  `PATCH /v1/threads/{thread_id}`, `DELETE /v1/threads/{thread_id}`,
  `POST /v1/threads/{thread_id}/messages`.
- New schemas: `Thread`, `ThreadListResponse`, `ThreadDetailResponse`, `Message`,
  `CreateThreadRequest`, `RenameThreadRequest`, `SendMessageRequest`, `SendMessageResponse`.
- `AuthError.code` gains `THREAD_NOT_FOUND` to its documented known values. Additive by the
  rule already in the schema: consumers must tolerate an unknown code and fall back to
  `message`, so this cannot break one that obeys the contract.
- `/v1/chat` is untouched.

`contracts/README.md`: three prose additions, for the promises no schema can hold —
**chat ownership** (404 covers both "not yours" and "does not exist", and why), **titles**
(server-derived once from the first message; a rename is permanent), and **what history
means** (a bounded window of recent turns from the stored transcript, with the transcript as
the single source of truth). The `422`-versus-envelope rule gains `404` to the envelope's
list of statuses.

**Why `/v1/threads` and not `/v1/chats`.** One letter from the existing `/v1/chat`, with
entirely different semantics. A typo would reach a real endpoint and the failure would be a
confusing 422 rather than a 404. `frontend` already models these as threads and routes
`/chat/$threadId`, so "thread" is the word in the code on both sides of the seam; "chat" is
the word in the UI, which is where it belongs.

The freeze SHA does NOT go here. It goes in `change.yaml` as `freeze_sha`, which is the
only place anything reads it — two copies of a SHA is one copy that can go stale.

## A gap in the oracle

Two criteria cannot be proved by the smoke suite, and this is written down so nobody
concludes more from a green `smoke.json` than it says.

**Criterion 7, history reaching the model.** The joined stack in CI runs `CHAT_MODEL=echo`,
and an echo model has nothing to remember with. Asserting "the reply reflects the earlier
turn" needs a real provider and live credentials, which CI has neither of — the same
constraint that kept 0002 from asserting model identity. Worse, any seam assertion that
*would* work under `echo` would have to depend on how the backend formats history into the
prompt, which dictates implementation from the wrong repo. So the seam asserts the
substrate — the transcript persists, in order, with roles — and criterion 7 is a
`chatbot-backend` unit test against a fake model that records the messages it was handed.
The slice file says so explicitly, because it is the one criterion whose evidence lives
outside this repo.

**Criterion 9, the rate limit.** A per-account limit worth having is not reachable in a
handful of requests, and every request to reach it buys a completion from a provider. The
limiter is asserted in `chatbot-backend`'s own tests, where the clock and the bucket are
injectable. `docs/adr/0004` already records the deeper reason the seam is the wrong place:
the buckets are per-process, so above one replica the effective limit multiplies and a
remote assertion would flake as a function of replica count.

**And the one the smoke suite cannot see at all:** whether the *UI* consumes any of this.
Every HTTP-visible property here would pass with the frontend still keeping threads in
memory, exactly as change 0002 found for its own headline criterion. `smoke.e2e: true` in
`change.yaml` is not an optimisation — it is the only oracle for criterion 8, and the only
thing that catches a frontend slice that built the API client and never wired it in.

## Deployment

<!-- The machine-readable version of this lives in change.yaml, which is what the scripts
     actually read. Written here too because the infra decision is a judgement a human
     makes, and a bare `infra: true` in a manifest records the answer without the reason. -->

- Local stack and smoke: always. `./scripts/iterate.sh 0003-chats-rename-delete-history`
  brings up all repos together and runs `smoke.yaml` against the single origin.
- Infra deploy: **no**, and there is no infra slice. Nothing is provisioned. Postgres is
  already a real dependency with a migration applier that runs from the lifespan before the
  app serves, so two new tables are a numbered `.sql` file in the backend's own repo, not an
  infrastructure change. Set `deploy.infra: false` in `change.yaml` to match.
- One adjacent fact carried forward from 0002 rather than fixed here: the deployed task role
  still lacks `bedrock:InvokeModel`. Nothing here deploys, so nothing here is blocked by it.
  History does make the first real cloud turn more expensive when it does land.

## Slices

- `chatbot-backend.md`
- `frontend.md`

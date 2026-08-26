# 0003 — frontend slice

Chats stop living in this browser. The thread store becomes the API, so a conversation
survives a reload, and a person can rename a chat and delete one.

This is the change the module docs have been pointing at: threads are held in memory today
and `/chat/<id>` after a refresh is a `not-found`. That store is what this slice replaces.

## What to build

- **Chats come from the server.** The chat half of the API boundary — which is hand-authored
  today because the contract had nothing to say about threads — is now contract surface. List,
  create, read-with-transcript, rename and delete are real requests. The in-memory thread
  store goes away rather than becoming a cache in front of the API: two owners for one piece
  of state is the thing the state-ownership rule exists to prevent.

- **A reload keeps the conversation.** Opening `/chat/<id>` fetches that chat and renders its
  transcript. A `404` from the server now means the chat is genuinely gone — deleted, or never
  that person's — and the failure surface should say that, rather than the current "lost
  because we kept it in memory" framing.

- **Rename, in the UI.** A person renames a chat and the new name persists — visible in the
  sidebar, and still there after a full page reload. The server derives a title from the first
  message, so a new chat is never untitled and rename is an override rather than the only way
  to get a name.

- **Delete, in the UI, with a confirmation.** It is irreversible and there is no undo: the
  server hard-deletes and the contract says so, so do not build an interface that implies
  otherwise. Use an accessible confirmation from the primitives already in use here. If the
  chat being deleted is the one currently open, navigate away — leaving the person looking at
  a transcript that no longer exists is worse than moving them.

- **Cache invalidation, not guessing.** A send, a rename and a delete all change what the
  list shows. The existing pattern — the completion of a send invalidates the chat's query so
  anything derived from it is re-read rather than assumed — is the pattern to extend, not to
  work around.

- **Starting a new chat.** Today a new chat's first message is handed from the index screen to
  the thread screen through history state, because the id was invented client-side. Chat ids
  are now the server's. That flow needs re-deciding rather than patching: whatever you choose,
  a person who types a first message and presses send must end up on a real chat whose id came
  from the server, with their message sent exactly once. Sending it twice is the failure mode
  to test for.

- **Per-chat drafts and reading positions are keyed by chat id**, and those ids are now
  server-generated and durable, which is strictly better for both. Drafts must keep their
  current promise: cleared when the server acknowledges the message, never when the form is
  submitted, so a failed send leaves the text where it was.

- **Regenerate the wire types from the vendored spec** and let the compiler find what moved.
  A spec the client disagrees with must fail to compile — that check is the point of the
  generated file, so do not hand-write shapes the spec already declares.

- **Commit the vendored `contracts/` copy** the dispatch published into this repo, with the
  rest of the work, so the promise travels with the pull request.

## Contract entries this depends on

- `contracts/openapi.yaml` → `POST /v1/threads`, `GET /v1/threads`,
  `GET /v1/threads/{thread_id}`, `PATCH /v1/threads/{thread_id}`,
  `DELETE /v1/threads/{thread_id}`, `POST /v1/threads/{thread_id}/messages`
- `contracts/openapi.yaml` → schemas `Thread`, `Message`, `ThreadResponse`,
  `ThreadListResponse`, `ThreadDetailResponse`, `CreateThreadRequest`,
  `RenameThreadRequest`, `SendMessageRequest`, `SendMessageResponse`
- `contracts/openapi.yaml` → `AuthError.code` now documents `THREAD_NOT_FOUND`, arriving with
  a `404`. Do not switch exhaustively on the code — the contract adds codes additively and
  requires a fallback to `message`, which is written to be shown as-is.
- `contracts/README.md` → § "Chats, ownership and titles": a `404` covers both "does not
  exist" and "not yours", indistinguishably, so the UI must not try to tell them apart. Also
  what history promises — see the note below, because it constrains what the UI may claim.
- `contracts/openapi.yaml` → `POST /v1/chat` is unchanged and still stateless. It is no longer
  the endpoint a chat sends through.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and report
it rather than working around it.

## Verification

- [ ] **criterion 8, and it is why the browser stage exists.** Playwright, against a real
      backend: rename a chat, reload the page, the new name is still there; delete a chat,
      reload, it is still gone. Both halves need the reload — an assertion made without one
      passes against a client that only updated its own cache.
- [ ] a chat opened by deep link after a full reload renders its transcript from the server
- [ ] a `404` on a chat renders a "this chat is gone" surface, not a retryable transport
      error, and does not sign the person out
- [ ] a `401` on any of these still means "sign in", handled the same way the route guard and
      a refused send already handle it — and a network failure or a `5xx` still must NOT clear
      the session
- [ ] deleting the open chat navigates away and the chat is absent from the sidebar
- [ ] a first message from the index screen is sent exactly once, and lands in the chat the
      person ends up looking at
- [ ] the generated wire types are regenerated and diffed, and the client typechecks against
      them
- [ ] no `fetch` outside the API layer, and no raw hex in components or routes — the existing
      lint and hook rules
- [ ] the repo's own gates pass

## Smoke — what this slice is actually judged on

The control repo deploys every repo together and runs `smoke.yaml` against one origin. One
step there is yours, and it is deliberately narrow:

- [ ] `chat-deep-link-serves-the-app` — `GET /chat/<id>` returns the app shell. Note the id
      in that path was deleted two steps earlier: this asserts the deep link still reaches
      the app rather than 404ing at the edge, which is what makes "this chat is gone"
      renderable at all instead of a dead page.

**That step is not the criterion.** Every HTTP-visible property of this repo would pass with
chats still held in browser memory, exactly as change 0002 found. The real oracle for this
slice is the Playwright suite, which the control repo runs against the joined stack because
this repo's own CI has no backend to run it against. A green CI here is not evidence for
criterion 8.

## Notes

- **The assistant still answers cold across chats, and now warm within one.** The backend
  supplies earlier turns of the *same* chat to the model, bounded to a recent window. So the
  transcript is no longer decorative — but old turns fall out of the window and are not sent.
  Do not build UI that promises the model remembers the whole thing.
- **No streaming.** `POST /v1/threads/{id}/messages` answers complete, exactly as
  `POST /v1/chat` does. The send-event shape is unchanged: whatever this repo emits for a
  complete answer today is what it emits now.
- **No CORS and no configurable base URL**, unchanged. Relative URLs only.
- **The message endpoint is rate limited per account** and can answer `429`. It is declared in
  the contract, so handle it as a refusal with a message a person can read, not as a crash.
- Reading positions stay in this browser. Moving them to the server is a different change and
  is explicitly out of scope for this one.

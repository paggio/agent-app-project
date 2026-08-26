# 0004 — frontend slice


## What to build

A page where a person manages the documents the assistant can read, and replies that say
which of those documents they were built from.

### 1. `/knowledge` — the knowledge base page

- A new guarded route, alongside the chat routes, using the same `requireSession`
  `beforeLoad`. It must branch the same three ways: a session proceeds, `null` redirects to
  `/login?redirect=/knowledge`, and a thrown `ApiError` renders in place at `/knowledge`
  rather than redirecting. A transport failure is not "you are signed out".
- **Upload.** A file picker, restricted to `.txt` and `.md`. Read the file as text in the
  browser and send it as JSON — there is no multipart upload in this contract. Show the
  server's refusal as the sentence the server wrote: the size cap and the accepted types are
  the server's policy and it states them in the `422`, so do not re-implement the rule here
  and do not invent a different message. A cheap client-side check that avoids an obviously
  doomed round trip is fine; it is a courtesy, not the authority.
- **The list.** Filename, size, the one-line summary the server derived, and the status.
  Empty is a normal state and deserves a real empty state, not a spinner that never resolves.
- **Delete.** A confirmation dialog that says the deletion is permanent, because it is — no
  archive, no trash, no undo. Presenting anything reversible would present something the
  server cannot do. This is the same posture the chat delete already takes; match it.
- **Reachable.** A link from the chat surface, and `/knowledge` must work as a deep link on a
  cold load, not only by in-app navigation.
- Invalidate the document list after an upload and after a delete. Nothing patches a derived
  field — the summary, the size and the chunk count all come from the server and are re-read
  rather than guessed at, exactly as a chat title is.

### 2. Citations in the transcript

- An assistant message may carry `citations` and `retrieval_consulted`. Both are **optional**
  and both are absent on every message written before this change — a transcript that mixes
  old and new messages is the normal case, not an edge case, and it must render cleanly.
- When there are citations, show the sources under the reply: the document each came from,
  and its `marker`, which is the number the reply's own text refers to as `[1]`. Where the
  document still exists, link it; where it does not, still name it. A citation carries its
  document's filename as a snapshot for exactly this reason — a deleted document does not
  erase the record that the answer used it.
- When `retrieval_consulted` is true and there are no citations, the assistant looked and
  found nothing relevant. That is worth saying quietly; it is a different fact from not
  having looked at all.
- When `retrieval_consulted` is false or absent, show nothing. No empty "Sources" heading.
- Do not claim more than the contract promises. A citation says the assistant **was given**
  that document; it does not certify that the sentence in front of you came from it. Nothing
  in this repo may phrase it as proof.

### 3. The API boundary

- A `KnowledgeClient` interface in `src/api/client.ts` beside the existing clients, with an
  HTTP implementation and a mock one. The mock keeps the component tests and the dev flags
  working with no backend, the same way the chat and auth mocks do.
- Relative URLs only. No configurable base URL — that decision is already made and is what
  keeps the session cookie flowing.
- A `401` on any of these means "sign in", handled the same way the chat surface already
  handles one. A `404` is gone. A `422` is a sentence to show. A `429` is a sentence to show.
  Nothing new crosses this boundary except the shapes; the error handling is the existing
  handling, reused rather than re-derived.
- Types come from the vendored spec. Regenerate the wire types and let the compiler check
  the client against them — a spec the client disagrees with must fail to build.

## Contract entries this depends on

- `contracts/openapi.yaml` → `POST /v1/documents`, `GET /v1/documents`,
  `GET /v1/documents/{document_id}`, `GET /v1/documents/{document_id}/content`,
  `DELETE /v1/documents/{document_id}`
- `contracts/openapi.yaml` → schemas `Document`, `DocumentResponse`, `DocumentListResponse`,
  `CreateDocumentRequest`, `Citation`
- `contracts/openapi.yaml` → `Message.citations` and `Message.retrieval_consulted`, both
  optional — treat them as absent-by-default, not as fields you can rely on being there
- `contracts/README.md` → "Documents, the knowledge base, and what a citation promises"

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] Component tests for the page against the mock client: empty state, a listed document,
      an upload that succeeds, an upload the server refuses, and a delete that is confirmed
      and one that is cancelled.
- [ ] A transcript renders correctly for all four message shapes: no citation fields at all
      (a message from before this change), `retrieval_consulted: false`,
      `retrieval_consulted: true` with citations, and `retrieval_consulted: true` with none.
- [ ] The guard on `/knowledge` branches three ways, with the third asserted by URL — still
      at `/knowledge` after a `5xx`, not redirected.
- [ ] An end-to-end flow against the real backend: sign in, upload a document, see it listed,
      ask the assistant about it, see the reply name it as a source, delete it, see the list
      update. This is the oracle for criteria 10 and 11 and there is no other.
- [ ] The generated wire types are regenerated and the client typechecks against them.
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`) — including no raw colour values
      outside the token layer.

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys all of them together and runs
`smoke.yaml` against one origin. The step whose `owner:` is `frontend` is yours:

- [ ] `spa-serves-knowledge-deep-link` — `GET /knowledge` on a cold load returns the app
      shell with a `200`, not a `404`. A missing SPA fallback breaks the deep link while
      in-app navigation to the same route works perfectly, so this only ever shows up
      through the proxy.

**One step is not much, and it is honest about being a fallback check and nothing more.**
Every other criterion this slice owns is a browser fact, which is why the change runs its
end-to-end pass: a `200` on `/knowledge` is equally true of a page that renders nothing.

These run against your code through a reverse proxy, not against your test doubles, and
a failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- **Merge order puts the backend first**, so by the time this lands the endpoints exist. Do
  not build a fallback for their absence — a page that degrades gracefully when the API is
  missing hides the deploy ordering problem instead of surfacing it.
- **Documents are cached per account like everything else.** Signing out already clears the
  query cache; make sure the new queries live inside that same clearing, so one account's
  document names never appear in the next one's list.
- **Text and markdown only, and PDF is explicitly out of scope for this change.** Do not add
  a PDF path helpfully — the backend cannot ingest one, and the file picker promising
  something the server refuses is worse than the picker not offering it.
- **A document has no edit.** Delete and re-upload. Do not build a rename or an in-place
  editor; neither exists on the server.
- The transcript still renders paragraphs and code, not markdown. A citation marker in a
  reply is plain text like everything else and needs no renderer.

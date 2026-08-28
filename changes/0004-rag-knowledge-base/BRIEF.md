# 0004 — a knowledge base the assistant can consult, and answers that say what they used


## Why

The assistant answers from the model's training data and from the last twenty turns of the
open chat. Nothing else reaches it. Every question about a document the person actually
holds — a policy, a report, a runbook — is answered from nothing, confidently, and there is
no way for the person to tell that from an answer grounded in their own material.

This change gives an account a knowledge base it manages itself, has the graph consult it
when the question warrants it, and makes the answer state which documents it was given. The
last part is not decoration: an answer that cites nothing and an answer that cites the wrong
thing are the two failures that make a grounded assistant worse than an ungrounded one, and
neither is visible unless the citations are.

## Acceptance criteria (these are the oracle)

- [ ] 1. A signed-in caller uploads a document and gets `201` with `status: ready` and
      `chunk_count >= 1`. It is searchable on the very next request — there is no polling,
      no pending state to wait through. Two intakes, one resource: `application/json` for
      text and markdown, `multipart/form-data` for anything binary.
- [ ] 2. A document belongs to exactly one account. A second account's list does not contain
      it, and reading or deleting it by id answers `404 DOCUMENT_NOT_FOUND` — the same answer
      an id that was never issued gets.
- [ ] 3. `GET /v1/documents/{id}/content` serves the original bytes back byte-identical from
      object storage. The index is derived data; this is the assertion that the system of
      record is real and readable, not just written to.
- [ ] 4. A question whose answer is in an uploaded document produces an assistant message
      with `retrieval_consulted: true` and at least one citation naming that document.
- [ ] 5. A question unrelated to anything in the knowledge base produces
      `retrieval_consulted: false` and no citations. The router is the reason retrieval is
      not paid for on every turn, so a router that always says yes is a failed router.
- [ ] 6. Deleting a document removes it from the list, `404`s on re-read, removes its bytes
      from object storage, and removes its chunks from the index — a later question about
      its subject cites nothing.
- [ ] 7. A citation recorded before a deletion still names the document afterwards. A
      transcript does not develop holes because the knowledge base moved on.
- [ ] 8. Retrieval fuses BM25 and dense scores with configurable weights. Setting either
      weight to zero yields the pure other retriever, and a fixture corpus proves each of
      the three configurations returns what it should. (chatbot-backend's own tests.)
- [ ] 9. `chatbot-backend/docs/graph.md` documents the graph and every node in it: what the
      node is for, what it reads from state, what it writes, and which model calls it makes.
      `docs/architecture.md` links it. Verified by review and by the repo's own gate; there
      is no seam assertion for a document.
- [ ] 10. In a browser: a person reaches `/knowledge`, uploads a file, sees it listed with
      its size and its one-line summary, deletes it through a confirmation that says the
      deletion is permanent, and the list updates without a reload.
- [ ] 11. In a browser: an assistant reply that used the knowledge base shows which documents
      it was given, and one that did not use it shows no sources at all.
- [ ] 12. A document over `DOCUMENT_MAX_BYTES` (10 MB) is refused `422` and nothing is
      stored, extracted or indexed; a content type outside the accepted set is refused `422`
      the same way. The size half is proved in chatbot-backend's own tests — see "A gap in
      the oracle"; only the content-type half is still reachable at the seam.
- [ ] 13. An account with an empty knowledge base gets exactly the behaviour it had before
      this change. Retrieval is additive: no documents means no citations, no extra latency
      beyond the router, and every step in `smoke/baseline.yaml` still passes.
- [ ] 14. A PDF is accepted, its text extracted, and the extracted text is what gets chunked,
      indexed and cited. A PDF with no extractable text — a scan — is refused `422` rather
      than stored as a document that can never be retrieved.
- [ ] 15. A person can read an uploaded document's content in the page, without downloading
      it and without leaving `/knowledge`.
- [ ] 16. A document cited more than once in one answer appears **once** in that answer's
      sources. Two chunks of one file is one source, not two.

## Out of scope

Each of these is a decision, not an omission.

- **Formats beyond text, markdown and PDF.** Office documents, HTML and images are each an
  extractor with its own failure modes. PDF is in because it is what people actually have.
- **Scanned PDFs and OCR.** A PDF whose pages are images yields no text. This change refuses
  it loudly rather than storing something that can never be retrieved; OCR is a dependency
  and a quality problem of its own.
- **Page-level citations.** A citation names the document and one extracted chunk. Mapping a
  chunk back to a page is a property of the extractor, and belongs with whatever needs it.
- **Asynchronous ingest.** Synchronous is bounded by the size cap and removes a status race
  from every step that follows an upload. `Document.status` is in the contract from day one
  so that `pending`/`indexing` is an additive change rather than a reshape.
- **Reranking.** You asked for a weighted BM25-and-dense retriever and that is what this is.
  A cross-encoder is the obvious next lever and it is a change with its own measurement.
- **Sharing a knowledge base between accounts.** Ownership is exactly one account, as it is
  for chats. Sharing is a permissions model, and this system has none.
- **De-duplicating re-uploads.** Uploading the same file twice makes two documents. Cheap to
  add later on `sha256`; adding it now buys an error code nobody has hit yet.
- **Retrieval on `POST /v1/chat`.** That endpoint is stateless by contract and stays frozen.
  A caller that wants the knowledge base posts into a chat.
- **Pagination on the document list.** Capped at 200, the same shape and the same reasoning
  as the chat list. A cursor is additive when somebody has 200 documents.
- **Editing a document.** Delete and re-upload. In-place edit means re-chunking, re-embedding
  and deciding what happens to citations that point at chunk 7 of a document that now has
  four — all of which is a change, not a field.
- **OpenSearch and object storage in the cloud.** `infra/` is an empty skeleton with no IaC
  tool chosen. See "Deployment".

## Contract changes

All additive. Nothing existing changes shape, so a deployed old client keeps working.

`contracts/openapi.yaml`:

- **New paths.** `POST /v1/documents`, `GET /v1/documents`, `GET /v1/documents/{document_id}`,
  `GET /v1/documents/{document_id}/content`, `DELETE /v1/documents/{document_id}`.
- **`POST /v1/documents` takes two request shapes.** `application/json` with a `content`
  string for text and markdown, unchanged; `multipart/form-data` with a `file` part for
  binary. Base64 in the JSON body was the alternative and was rejected: at a 10 MB cap it
  means 13.3 MB request bodies held in memory to be decoded, which is a poor interface
  chosen to suit a test tool. See "A gap in the oracle" for what that costs.
- **`application/pdf` joins the accepted content types**, an additive enum value.
- **At most one citation per document per message**, promised in `contracts/README.md`. Two
  chunks of one file is one source. The schema does not change; what it promises does.
- **New schemas.** `Document`, `DocumentResponse`, `DocumentListResponse`,
  `CreateDocumentRequest`, `Citation`.
- **`Message` gains two optional fields**, `citations` and `retrieval_consulted`. Optional
  and additive: a client built against 1.3.0 ignores them, and an assistant message from
  before this change has neither.
- **New error codes**, in the existing `{"error": {"code", "message"}}` envelope:
  `DOCUMENT_NOT_FOUND` (404) and `DOCUMENT_QUOTA_EXCEEDED` (409). Size and content-type
  violations are `422`, because they are stated policy — the same rule that puts password
  policy in `422`.

`contracts/README.md`: a new section, "Documents, the knowledge base, and what a citation
promises". It carries the parts no schema can hold — the `404`-for-everyone-else doctrine
restated for documents, that the index is derived and object storage is the record, that a
citation names what the model was *given* and that its document name is a snapshot which
survives deletion, and that the retrieval decision is a per-turn judgement whose criteria are
not promised.

The freeze SHA does NOT go here. It goes in `change.yaml` as `freeze_sha`, which is the
only place anything reads it — two copies of a SHA is one copy that can go stale.

## The shape of the graph, and why it is this shape

Decided here because three repos would otherwise each infer it, which is what this repo
exists to prevent. The backend slice implements it and documents it; `docs/graph.md` is the
readable version and criterion 9 is what makes it exist.

```
              START
                │
         ┌──────▼───────┐
         │ route_query  │   does this turn need the knowledge base?
         └──┬────────┬──┘
       yes  │        │  no
         ┌──▼─────┐  │
         │retrieve│  │      weighted BM25 + dense, account-scoped
         └──┬─────┘  │
            │        │
         ┌──▼────────▼──┐
         │    answer    │   the create_agent subgraph, tools bound
         └──────┬───────┘
                │
               END
```

Four decisions inside it, each of which had a cheaper alternative that was rejected:

**`route_query` is a node, not a tool call.** Letting the model decide by calling a search
tool would cost nothing on turns that need no retrieval and would allow re-querying, and it
was the cheaper design. A node was chosen instead because the decision becomes an explicit,
inspectable, separately testable step with a name — and `retrieval_consulted` on the stored
message is that decision, persisted. The cost is one extra model call on every turn, and it
is accepted.

**The router reads a corpus manifest built at ingest.** A router asked "does this need the
knowledge base?" with no knowledge of what is *in* the knowledge base is guessing. So every
document gets a one-line summary when it is uploaded, and the manifest — the account's
document names and summaries, capped — is what the router is given. This is the "something
clever at upload time": it moves the hard part from query time, where it is repeated on every
turn, to ingest time, where it happens once per document.

**The router's decision function is injected, exactly as the chat model is.** `CHAT_MODEL=echo`
replies with its own input and cannot classify anything, so an LLM-only router would decide
by accident in CI and criteria 4 and 5 would be untestable. `RETRIEVAL_ROUTER=heuristic|llm`
selects: `heuristic` scores lexical overlap between the question and the manifest against a
threshold, `llm` asks the model for a structured yes/no. Same seam as `build_chat_model`, same
reason. The summaries have the same fallback: derived deterministically from the document
when no real model is configured.

**`answer` is the existing `create_agent` graph, nested as a node.** Not a replacement for it.
`build_graph(model, tools)` keeps its meaning, `graph/tools.py` keeps its purpose, and the
tool loop stays available inside the answer step. The outer graph adds the two nodes in front.

**`graph/` still knows nothing about users or sessions**, and that invariant is not bent here.
Retrieval is account-scoped, but the graph never sees an `account_id`: it receives a retriever
that is *already* bounded to one account, the same way it receives an already-bounded history
and an already-constructed model. The scoping decision stays in `threads/`, where the account
is known.

## Deployment

- Local stack and smoke: always. `./scripts/iterate.sh 0004-rag-knowledge-base` brings up all
  repos together and runs `smoke.yaml` against the single origin. Two services join the
  joined stack — OpenSearch and MinIO — and both are `chatbot-backend`'s to own, so
  `stack/compose.yml` gains their `agentapp.owner` labels here. Without those labels an
  OpenSearch that fails to start is attributed to the whole change instead of to the one
  repo that can fix it.
- Infra deploy: **no**, because `infra/` is an empty skeleton with no IaC tool chosen —
  `make -C infra deploy` does not exist and `docs/adr/0002` §4 makes that a loud failure
  rather than a skip. `deploy.infra: false` in `change.yaml`, and the best outcome this
  change can reach is therefore `verified-local`.
- **What that defers, stated so it is a decision rather than a surprise:** an OpenSearch
  domain, an S3 bucket, and the IAM to reach both from the task role are a real infra change,
  and until it lands there is no deployed knowledge base. The application code is written
  against the ports and the environment variables that change will supply, so it is a
  configuration change here and not a rewrite — but nothing in this run is evidence that it
  works anywhere but locally.
- The stack gets slower. OpenSearch is a JVM that takes tens of seconds to become healthy and
  the embedding model is loaded once per process. `smoke.timeout_s` is raised to 600
  accordingly, and cold start is paid in `up --wait` rather than inside the suite.

## A gap in the oracle

What `smoke.yaml` cannot see, said plainly, because a criterion asserted nowhere is a
criterion nobody is keeping:

- **The LLM router is never exercised at the seam.** CI runs `CHAT_MODEL=echo`, so the
  deterministic router is what criteria 4 and 5 actually assert. That is the right trade —
  it makes the criteria real rather than flaky — but the `llm` path is covered only by
  `chatbot-backend`'s own tests against a recording fake, and by running the stack with
  Bedrock credentials by hand.
- **Ingest-time summaries are deterministic in CI** for the same reason, so criterion 10's
  "sees its one-line summary" asserts that a summary exists and is non-empty, not that a
  model wrote a good one.
- **Retrieval quality is asserted, but only at the level a fixture can prove.** The local
  ONNX embedder is a real model, so the dense half genuinely runs in CI — this is why it was
  chosen over a hash stub. What no seam step can prove is that the weights are *well chosen*;
  criterion 8 lives in the backend's tests, where a fixture corpus makes each configuration
  checkable.
- **The document quota and the upload rate limit are not asserted at the seam**, because
  reaching either costs a hundred ingests. They belong to `chatbot-backend`'s own tests, the
  same reasoning that keeps the per-account message limit out of the smoke suite.
- **PDF upload is not asserted at the seam either, and this is the one that hurts.**
  `smoke.py` speaks `body` (JSON) and `form` (urlencoded) and has no multipart, so the suite
  cannot send a file at all. Text keeps seeding the suite, so the retrieval, citation and
  deletion chain stays asserted exactly as before — but the headline new format is proved
  only by Playwright, which uploads a real PDF fixture through the real page. That is a
  genuine oracle rather than a stub, and it is still one oracle where the others have two.
  The harness fix is a `files:` key on a smoke step; it is a control-repo change and
  `CLAUDE.md` forbids slipping one into a change, so it belongs to a retrospective. When it
  lands, the PDF steps get written and this paragraph gets shorter.
- **The size refusal left the seam.** At 2000 bytes an oversize fixture was prose a reviewer
  could read. At 10 MB it is not expressible in a suite meant to be read as criteria, so the
  step is deleted rather than kept as something nobody can check. Criterion 12's size half
  is now a `chatbot-backend` test, where 10 MB is a generated buffer and costs nothing.
- **Criterion 9 is a document.** No step can assert prose. It is verified by review and by
  the backend repo's own gate, which fails a behaviour change that does not update
  `docs/architecture.md`.
- **Every HTTP-visible property below would pass with a `/knowledge` page that does not
  exist.** `smoke.e2e: true` is the only oracle for criteria 10 and 11, exactly as it was for
  0003's rename-survives-reload.

## Slices

- `chatbot-backend.md`
- `frontend.md`

No infra slice: nothing is provisioned. See "Deployment".

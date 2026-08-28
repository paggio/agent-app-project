# 0004 — chatbot-backend slice


## What to build

A knowledge base an account owns, and a graph that decides whether to consult it.

### 1. The graph gains a routing node, and `create_agent` becomes a node inside it

This is the centre of the change and the part most likely to be built differently from
what was decided, so it is specified rather than left open.

```
              START
                │
         ┌──────▼───────┐
         │ route_query  │   does this turn need the knowledge base?
         └──┬────────┬──┘
       yes  │        │  no
         ┌──▼─────┐  │
         │retrieve│  │      weighted BM25 + dense, over an already-scoped retriever
         └──┬─────┘  │
            │        │
         ┌──▼────────▼──┐
         │    answer    │   the existing create_agent graph, unchanged, as a node
         └──────┬───────┘
                │
               END
```

- `build_graph(model, tools)` keeps its signature and keeps compiling `create_agent`. What
  changes is that its result becomes the `answer` node of an outer `StateGraph`, rather than
  being the whole graph. Do NOT replace `create_agent` with a hand-rolled model node — the
  tool loop stays available, and `graph/tools.py` keeps its purpose.
- **`route_query`'s decision function is injected**, exactly as the chat model is.
  `RETRIEVAL_ROUTER=heuristic|llm`. `heuristic` scores lexical overlap between the question
  and the corpus manifest against a threshold and calls no model at all; `llm` asks the
  model for a structured yes/no. The default in the local stack is `heuristic`, because
  `CHAT_MODEL=echo` cannot classify anything and a router that decides by accident makes
  every retrieval assertion meaningless. Build both. One function, two implementations,
  chosen in one place — the same shape as `core.models.build_chat_model`.
- **The router reads a corpus manifest**: the account's document filenames and one-line
  summaries, capped at `MANIFEST_MAX_DOCUMENTS`. A router with no idea what is in the
  knowledge base is guessing, which is why summaries are generated at ingest.
- `retrieve` runs a weighted fusion of BM25 and dense scores and writes the surviving chunks
  into state. Below `RETRIEVAL_SCORE_FLOOR` nothing is injected and no citation is produced,
  even though the router said yes — "the router thought so" and "the corpus actually has
  something" are two different facts.
- **`graph/` still knows nothing about users or sessions**, and this must not be bent.
  Define a `Retriever` protocol in `graph/` and pass an instance that is ALREADY bound to
  one account. The graph must never see an `account_id`, a session, or anything it could use
  to scope a query itself — the scoping decision belongs where the account is known, the
  same way history is read and bounded before it ever reaches `run_turn`.

### 2. Documents: ingest, storage, index

- **Object storage is the system of record; the index is derived data.** Chunking,
  embeddings and the embedding model itself will all change, and re-indexing must never
  require anyone to re-upload. Store the original bytes through a `DocumentStore` port with
  an S3 implementation, pointed at MinIO locally via an endpoint override.
- **OpenSearch holds one index for all accounts**, with `account_id` as a filter term in
  every query. Not an index per account: that is an index explosion at a few hundred users.
  The account filter goes in the query itself, never applied to results afterwards — the
  same rule the chat store already follows in SQL, for the same reason.
- **Ingest is synchronous** and the document is searchable when `201` returns. Index with
  `refresh=wait_for`, or the default one-second refresh interval makes every step that
  follows an upload a race.
- **Embeddings are injected too**: `EMBEDDING_MODEL=local|bedrock`. `local` is a small ONNX
  sentence embedding model that runs offline with no credentials — this is what lets CI
  exercise the dense half for real rather than through a stub. `bedrock` uses a Titan text
  embedding model. Load the local model once per process, not per request.
- **Summaries are generated at ingest**, one line per document, and stored on the row. When
  no real chat model is configured, derive one deterministically from the document rather
  than leaving it empty — the router reads this field and an empty manifest routes nothing.
- Chunk on paragraph boundaries with overlap, `CHUNK_SIZE_CHARS` / `CHUNK_OVERLAP_CHARS`.
- Accept `text/plain` and `text/markdown` only, as a UTF-8 `content` field in a JSON body.
  Refuse anything else `422`. There is no multipart upload in this milestone.
- Enforce `DOCUMENT_MAX_BYTES` against the decoded content **before** chunking, embedding or
  storing anything. A refusal that has already paid for embeddings is not a refusal.
- Enforce `DOCUMENT_MAX_PER_ACCOUNT` — `409 DOCUMENT_QUOTA_EXCEEDED`, the envelope shape,
  because a well-formed request refused is not a validation failure.
- Rate limit uploads per account with the existing bucket mechanism, `429 AUTH_RATE_LIMITED`
  with `Retry-After`. Uploads buy embeddings; anything that buys something needs a bound.
- **Delete removes all three**: the row, the object, and every chunk in the index. A delete
  that leaves the object behind passes every metadata assertion and quietly accumulates
  bytes nobody is accounting for.

### 2b. AMENDED — PDFs, a 10 MB cap, and one citation per document

This section supersedes parts of §2 and §3 below. Where they disagree, this wins.

**`POST /v1/documents` takes two request shapes, one resource.**

- `application/json` with a `content` string — text and markdown, exactly as already built.
  Do not change it; the smoke suite seeds every document through it.
- `multipart/form-data` with a `file` part — anything binary. Base64 in the JSON body was
  the alternative and was rejected: at a 10 MB cap it means 13.3 MB bodies decoded in
  memory, which is a bad interface chosen to suit a test tool.

**`application/pdf` joins the accepted types.** Extract its text; the extracted text is what
gets chunked, indexed, summarised and cited — the stored original stays the PDF. **A PDF
with no extractable text is refused `422`**, not stored: a scan indexes nothing and would
sit in a knowledge base as a document that can never be retrieved, which is worse than a
refusal because it looks like it worked.

**`DOCUMENT_MAX_BYTES` becomes 10 MB** (10485760). Two consequences that are not just a
constant:

- Enforce it **while reading the upload**, not after. Reading an unbounded multipart body
  into memory and then measuring it is how the cap becomes the thing that crashes you.
- The refusal must still precede storage, extraction and indexing.

**REMOVE the per-chunk citation.** Today two chunks of one document produce two citations,
which renders as `[1] README.MD` / `[2] README.MD` — see
`changes/0004-rag-knowledge-base/evidence/duplicate-citations.png`. **At most one citation
per document per message.** The highest-scoring chunk represents the document; its
`chunk_index` and `snippet` are the ones carried. Markers are then assigned over the deduped
list, so they stay 1..k with no gaps. This is a promise in `contracts/README.md`, not an
option — do not make it configurable.

Retrieval itself still returns chunks and still uses several from one document as context if
they score. Only the CITATION list is per document.

### 3. Citations on the stored message

- The assistant message carries `citations` and `retrieval_consulted`, and both are
  **persisted with the message**. The stored transcript is the only record of a conversation
  — a citation computed at answer time and not stored is gone on the next read.
- **A citation's `filename` is a snapshot**, denormalised onto the message at the moment the
  answer is written. Do not store a foreign key and render by joining: deleting a document
  would then punch a hole in every transcript that ever cited it. The `document_id` is still
  carried, so a client can link to a document that still exists; a citation whose document is
  gone still names it.
- `marker` is a 1-based integer assigned server-side over the citations supplied for that
  turn, and it is what the answer text refers to as `[1]`. The system prompt asks the model
  to use those markers; a marker in the text that references no citation is dropped rather
  than shown. Under `CHAT_MODEL=echo` no markers are produced at all and the citation list
  is still correct and still complete — that is the intended degradation, not a bug.
- What a citation promises is **what the model was given**, not what it demonstrably used.
  Say so in the docs; do not claim more than the mechanism supports.

### 4. Local stack services

The repo's own `docker-compose.yml` gains OpenSearch and MinIO, both with healthchecks the
backend's `depends_on` waits on. **Name the services exactly `opensearch` and `minio`.** That
is not cosmetic: the joined stack the control repo assembles declares which repo owns each
service by name, and a service whose name does not match is a stack failure attributed to
nobody in particular instead of to this repo. OpenSearch needs `discovery.type=single-node` and its
security plugin disabled for local use; it is a JVM and takes tens of seconds to become
healthy, so the healthcheck's `start_period` and `retries` matter. MinIO needs its bucket to
exist before the first upload — create it on startup rather than assuming it.

**One trap worth naming.** `docker-compose.yml` passes `.env` in, and that file holds real
AWS credentials for Bedrock. boto3's default chain will pick them up for the S3 client too,
and then the local S3 client authenticates against MinIO with credentials MinIO never issued.
Configure the S3 client's credentials and endpoint explicitly from settings rather than
letting the default chain decide; the Bedrock client keeps using the default chain, unchanged.

### 5. Documentation — this is criterion 9 and it is not optional

- **`docs/graph.md`** — new, and the deliverable the change was asked for. The graph as a
  diagram, then one section per node: what it is for, what it reads out of state, what it
  writes back, which model calls it makes (and which it does not), and what happens when it
  is skipped. Concise. It is a reference somebody consults while changing a node, not an
  essay.
- **`docs/architecture.md`** — the module map gains the new package; the wire-format section
  gains the five document endpoints and the two new message fields; "Request lifecycle" gains
  the ingest path and the retrieval-bearing turn; "Known gaps" gains what this change does
  not do.
- **ADRs** for the three decisions a future reader will ask "why?" about: the routing node
  and the nesting of `create_agent`; OpenSearch as the index with object storage as the
  record; and the injected router and embedder that let the whole thing run with no
  credentials. Each with its accepted costs, in the existing house style.

## Contract entries this depends on

- `contracts/openapi.yaml` → `POST /v1/documents`, `GET /v1/documents`,
  `GET /v1/documents/{document_id}`, `GET /v1/documents/{document_id}/content`,
  `DELETE /v1/documents/{document_id}`
- `contracts/openapi.yaml` → schemas `Document`, `DocumentResponse`, `DocumentListResponse`,
  `CreateDocumentRequest`, `Citation`
- `contracts/openapi.yaml` → `Message.citations` and `Message.retrieval_consulted`, both
  optional and additive; every existing field of `Message` is unchanged
- `contracts/README.md` → "Documents, the knowledge base, and what a citation promises" —
  the ownership doctrine, what a citation means, and what retrieval does not promise
- `contracts/README.md` → "Two error shapes, one rule" — unchanged, and it is what decides
  that a size or content-type violation is `422` while a quota refusal is `409`

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] Criterion 8, which no seam step can reach: a fixture corpus and three retriever
      configurations — lexical weight zero, dense weight zero, and both non-zero — each
      returning what it should. This is the only place the weighting is actually proved.
- [ ] The router, both implementations, against a manifest fixture: a question about the
      corpus routes to retrieve, an unrelated question does not, and an empty manifest never
      routes to retrieve regardless of the question.
- [ ] The `llm` router and a real summary path against a recording fake model — the seam runs
      `heuristic`, so this repo is where the other branch is covered at all.
- [ ] Ownership: every document read, write and delete scoped by account in the query, with a
      test that a second account's list is empty rather than filtered.
- [ ] `DOCUMENT_MAX_BYTES` refuses before anything is stored, extracted or indexed — assert
      the store and the index were not touched, not merely that the status was 422. **This is
      now the only place criterion 12's size half is proved**: 10 MB is not expressible in
      the smoke suite, so the seam no longer covers it. A generated buffer costs nothing here.
- [ ] A PDF round trip: uploaded, text extracted, chunked, retrievable, cited. And a PDF with
      no extractable text refused 422 with nothing stored.
- [ ] Two chunks of one document in one answer produce ONE citation, with markers renumbered
      1..k over the deduped list.
- [ ] Delete removes row, object and chunks; assert all three, separately.
- [ ] A citation still names its document after the document is deleted.
- [ ] `make contract` passes against the vendored `contracts/openapi.yaml`.
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`)

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys all of them together and runs
`smoke.yaml` against one origin. The steps whose `owner:` is `chatbot-backend` are yours:

- [ ] `creating-a-document-requires-a-session` — `401`, and nothing stored by a refused call
- [ ] `listing-documents-requires-a-session` — `401` on the read path, no array leaked
- [ ] `register-kb-owner` — unchanged auth, still works
- [ ] `an-unsupported-content-type-is-refused` — `422`, no document created
- [ ] `upload-the-charter` — `201`, `status: ready`, and `chunk_count` of **at least 2**
- [ ] `the-document-has-a-summary-for-the-router` — the summary was persisted, not just returned
- [ ] `the-document-is-listed` — it appears in its owner's list
- [ ] `the-original-is-served-back` — the stored object comes back with its content type
- [ ] `start-a-chat` — unchanged, still works
- [ ] `asking-about-the-charter-consults-the-knowledge-base` — `retrieval_consulted: true`,
      a citation with `marker: 1` naming the document, **and that filename appearing exactly
      once in the whole response**. The charter now spans several chunks and the question
      matches more than one, so a per-chunk citation list fails here.
- [ ] `an-unrelated-question-consults-nothing` — `retrieval_consulted: false` and no citation
- [ ] `register-a-stranger` — unchanged, still works
- [ ] `the-strangers-list-omits-the-document` — the list is scoped, not just the detail read
- [ ] `the-stranger-cannot-read-the-document` — `404 DOCUMENT_NOT_FOUND`
- [ ] `the-stranger-cannot-read-the-original` — the bytes are scoped too
- [ ] `the-stranger-cannot-delete-the-document` — `404`, and see the next line
- [ ] `logout-the-stranger` — unchanged, still works
- [ ] `the-document-survived-the-strangers-attempts` — **the one that matters**: a backend
      that deletes and then reports missing satisfies all four `404`s above and only this
      step catches it
- [ ] `delete-the-document` — `204`
- [ ] `the-deleted-document-is-gone` — `404`, the same one a stranger got
- [ ] `the-original-is-gone-from-storage` — the object went too
- [ ] `the-index-forgot-the-deleted-document` — the manifest updated and the chunks are gone
- [ ] `the-citation-survived-the-delete` — the transcript did not develop a hole

These run against your code through a reverse proxy, not against your test doubles, and
a failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- **`DOCUMENT_MAX_BYTES` is 10 MB everywhere now**, including the joined stack. The old
  2000-byte override existed only so an oversize fixture could be readable prose, and that
  trade stopped being worth it — see the Verification list.
- **Migrations are additive and ordered**: the `documents` table, then the two new columns on
  the message table. Existing assistant messages have neither — a message from before this
  change must read back cleanly with no citations and no `retrieval_consulted`, which is
  what makes the backend safe to merge in front of the frontend.
- **`POST /v1/chat` gets no retrieval.** It is stateless by contract and stays frozen. Do not
  helpfully wire the knowledge base into it.
- **The graph is slower now, on every turn**, because the routing node runs whether or not
  retrieval follows. That was decided with its cost known — it is not something to optimise
  away by folding the decision back into the answer node.
- Pin the new dependencies exactly, the way the LangChain set already is. The ONNX runtime
  and the embedding model add materially to the image; that was decided too.
- Nothing here is deployed anywhere. There is no cloud OpenSearch and no cloud bucket yet, so
  read every endpoint's configuration from the environment with no baked-in assumption that
  it is reachable at a local address.

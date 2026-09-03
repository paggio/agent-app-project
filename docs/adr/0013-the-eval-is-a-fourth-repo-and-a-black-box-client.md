# 0013 — The eval is a fourth product repo, and a black-box HTTP client of the API

**Status:** accepted
**Date:** 2026-09-03
**Relation to 0001:** extends it. Three product repos becomes four, along the same seam:
the eval has its own history, its own image, its own deploy cadence and its own CLAUDE.md,
and it coordinates with the backend through `contracts/` like every other consumer.

## Context

`changes/0005-observability-phoenix` put traces in front of a person and named eval
explicitly out of scope: "Phoenix does all of it. This change puts traces in front of a
person; running evals over them is its own change with its own criteria." This is that
change, and the first question is where the code goes.

Three homes were available and two of them are worse for reasons that are not obvious:

- **Inside `chatbot-backend`, as a test suite or a `make eval` target.** It is the cheapest
  thing to build and it is what the backend's own `eval` pytest marker already gestures at.
  But an eval that lives beside the graph can import the graph, and the moment it does it is
  no longer measuring the deployed system — it is measuring a Python object assembled in a
  test process, with the HTTP layer, the session gate, the proxy, the `/api/` strip and the
  real datastores all absent. Every one of those has produced a real defect in this system.
  It also inherits the backend's deploy cadence, which is the opposite of what an eval
  wants: the point is to run against a build that already shipped.
- **Inside this control repo, as another `scripts/` gate.** Tempting, because the control
  repo already owns the joined stack and the smoke suite. Rejected because it is not the
  same kind of thing. The smoke suite asserts the seam and must stay small enough to read
  as the oracle; an eval carries a fixture corpus, a question set, four evaluators, a judge
  and a threshold policy, and it will grow. Putting it here would also make it undeployable
  — this repo is never deployed, and the eval's whole future is a k8s CronJob.
- **Its own repo.** What was decided.

The second question is what the eval is allowed to touch, and it is the one that actually
decides whether this is worth a repo. The original task description said the eval should
read a "vector DB URL" from its environment and "seed a dedicated eval collection".

## Decision

**`chatbot-eval` is a fourth product repo, and the backend's HTTP API is the whole of its
interface.** Four consequences, each of which was a live alternative:

1. **No datastore reach-around, and it is a gate rather than a preference.** No OpenSearch
   client, no S3 client, no postgres connection, no import of backend code. `EVAL_VECTOR_DB_URL`
   does not exist. Every number the eval reports must be derivable by any HTTP client from
   the frozen contract, which is also what makes the same run valid against a deployed
   environment. The eval repo's Stop hook refuses a datastore import.

   The corollary, and it is the expensive half: when the API cannot answer a question the
   answer is to **move the API**, which is a contract change here. That is why this change
   adds `GET /v1/version` rather than having the eval read the backend's environment.

2. **Isolation is an account, not a collection.** The backend's knowledge base is already
   scoped by account, so the eval's own account *is* its dedicated collection. There is no
   "eval collection" concept anywhere and there must not be one: a second isolation
   mechanism would be a weaker copy of a promise the contract already makes and the
   backend already enforces. "Never touch the live collection" becomes structural rather
   than careful.

   Backed by a second, cheaper rail: every document the eval uploads carries a marker
   prefix in its filename, and it deletes nothing that lacks the prefix. An
   `EVAL_ACCOUNT_EMAIL` pointed at a real account by mistake costs nothing.

3. **The eval's spans get their own Phoenix project; the backend's do not move.** A
   service's project is that service's own configuration. The alternative — letting a
   request name the project its traces are filed under — would be a way for any client to
   write into any store, and it is new contract surface for a convenience. So one eval
   example draws **one trace whose halves live in two projects**, joined by the trace id:
   the eval propagates W3C trace context, records the `X-Trace-Id` the backend returns,
   and puts it on its own span and in the example's output.

4. **Two code-based evaluators read the response body, not the trace.**
   `Message.retrieval_consulted` and `Message.citations[].document_id` are promised by
   `contracts/openapi.yaml` for exactly this purpose. Span attributes are explicitly not
   contract — `changes/0005`'s brief says so — so an eval that derived routing accuracy
   from a span would be built on something that may move without notice.

## Consequences

**Makes easy.** The same eval run is valid against the local stack and against a deployed
environment, with no branch and no second implementation, because it only ever speaks the
protocol both serve. It deploys on its own schedule as its own image, which is what a
CronJob wants. And it cannot silently become an integration test of the backend's internals,
because the thing that would let it is a gate failure.

**Accepted costs.**

- **A fourth submodule is a fourth copy of every hand-kept repo list.** Ten of them:
  `manifest.py`, `check-docs.py`, `lock.sh`, `prs.sh`, `vendor-contracts.sh`,
  `retro-evidence.sh`, `verify.sh`, `failure-brief.py`, the `Makefile`, and the write
  guard's own regex. Attaching this repo required editing all ten, and nothing but
  `test-hooks.py` would have failed if one had been missed. That is a real tax and it is
  now paid four times over rather than three; it is also the strongest argument available
  for eventually deriving the list from `.gitmodules`, which is a retrospective's business
  rather than this change's.
- **An eval that cannot reach past the API cannot measure everything.** Chunk-level
  retrieval quality, embedding drift and index health are invisible to it, and some of
  them are things an eval would legitimately want. The answer is a contract change, which
  is deliberately expensive — see `docs/adr/0001`'s own accepted costs.
- **A trace split across two projects is one more thing to explain.** A reader who opens
  the eval's project sees the task span and not the graph, and has to follow a trace id.
  Documented in the eval's `docs/architecture.md` and in `stack/dev.env`; not removable
  without giving a client the power to choose a project.
- **The eval account is a real account with a committed password.** Same posture as
  `DEV_ACCOUNT_*` from 0005 and safe for the same reasons — a `.test` address, nothing
  reachable behind it — but it is a second one, and the count is the thing to watch.
- **`ADR 0006`'s generalisation is now due and is not being taken.** `dev-env.sh` reads
  one submodule `.env` by name and 0006 said "generalise when the second one exists". A
  second one now exists in principle — the eval needs AWS credentials for
  `EVAL_JUDGE=bedrock` — but it does not need them in a *control-repo process*: they reach
  the container over compose's `env_file`, read by the Docker daemon, exactly as the
  backend's do. So no name is added to the allowlist and no layer is added. Recorded here
  because "the second file exists" will look like the trigger, and it is not.

## Alternatives considered

- **An eval inside `chatbot-backend`.** Cheapest. Rejected: it can import the graph, and
  the moment it does it stops measuring the deployed system. It also couples the eval's
  cadence to the code under test.
- **An eval inside this control repo.** Rejected: not deployable, and it would grow the one
  surface whose readability is why it is trusted as the oracle.
- **Give the eval a vector-DB URL and let it seed a collection directly.** What the task
  description asked for. Rejected: it duplicates the backend's chunking, embedding and
  scoring decisions in a second place, breaks the first time the backend changes any of
  them, and cannot run against a deployed environment where the datastore is not reachable.
  Uploading through `POST /v1/documents` gets the same corpus in with none of that.
- **Judge groundedness against `citations[].snippet`.** The obvious reading of "groundedness
  vs retrieved chunks", and wrong: the contract says the snippet is "truncated for display",
  so judging against it manufactures hallucinations that did not happen. The eval fetches
  the cited documents' full content instead, and the claim becomes "supported by the cited
  documents", which is the one the evidence supports.
- **A single Phoenix project for everything.** Simpler to explain, and it would put eval
  traffic into the project a person opens to debug real requests. Rejected on that, and
  because achieving it needs the backend to take the project from the request.

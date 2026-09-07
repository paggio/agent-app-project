# 0006 — Chatbot eval: a fourth repo that black-box tests the running backend

## Why

`changes/0005-observability-phoenix` put one trace per request in front of a person and
named this change out of scope in words: "Phoenix does all of it. This change puts traces
in front of a person; running evals over them is its own change with its own criteria."

A trace answers "what happened in this turn". It cannot answer the question anyone actually
has about a RAG system: *is it getting better or worse?* Today nothing does. 0004 put a
routing decision and a retrieval step in front of the answer, and the only oracle for
either is somebody typing a question and forming an impression. Every knob that matters —
`RETRIEVAL_ROUTER`, `retrieval_score_floor`, `retrieval_top_k`, the fusion weights,
`CHAT_MODEL`, the chunk size — can be tuned and nobody can say whether the tuning helped.

So: a fixed corpus, a fixed question set, four scores, a threshold, and an exit code.

**The shape of the thing is the decision, and it is `docs/adr/0013`.** `chatbot-eval` is a
fourth product repo whose only interface to the backend is the HTTP API — no OpenSearch
client, no S3 client, no import of graph code. That is what makes the same run valid against
the local stack and against a deployed environment, and it is enforced by a gate in that
repo rather than by good intentions.

## Amended, 2026-09-07 — `/ship-iterate`

Nothing has merged, so this supersedes rather than adds. Four questions were asked of the
first version; two were answered by measurement and needed no change, and two are real gaps.

**Measured before changing anything**, against the stack the green run left up:

| Asked | Found |
| --- | --- |
| does a re-run clean up the documents it sent? | **Yes.** 9 documents, no duplicate filenames, after four runs. The hash-compare seed works. |
| …and the conversations? | **No.** **36 threads** in the eval account — 2 runs × 18 examples — and nothing has ever deleted one. `GET /v1/threads` is capped at 200 by contract, so around the eleventh run the list truncates and the account becomes a junk drawer. |
| does anything report the exact model? | **`chat_model_id` already does**, and it is already in every experiment's metadata: `eu.anthropic.claude-haiku-4-5-20251001-v1:0`. What does NOT report it is the run's own printed summary, which names the JUDGE's model and never the model that produced the answers. |
| should the eval image be versioned too? | It is not. `image_tag` was `dev` for the backend and the eval image had no tag at all in the metadata. |

| Was | Is | Why |
| --- | --- | --- |
| threads accumulate forever | the eval **titles** each thread with a marker at creation and **purges its own marked threads at the start of every run** | a re-run must leave the account as it found it, and the document seed already sets that pattern. `CreateThreadRequest.title` is settable at create and `deleteThread` exists, so this needs no contract change |
| `BACKEND_IMAGE_TAG=dev` | `local-0.0.1`, hand-bumped, and a gate fails a change that touches a product repo without bumping it | `dev` is the same string forever, so two experiments a month apart are indistinguishable in the one field that is supposed to identify the build |
| the eval image was untagged | `EVAL_IMAGE_TAG`, in the experiment metadata | the evaluator code is as much a factor in a score as the fixture is. Two runs over the same corpus with different evaluators are not comparable, and nothing said so |
| the summary named only the judge's model | it names the backend's `chat_model` and `chat_model_id` too | the summary is the only evidence a failing job hands back, and it did not say what produced the answers |
| the metadata's `chat_model_id` was unasserted | a step asserts it equals what `/v1/version` reported | it was there by the slice's good judgement rather than by requirement, which is not the same thing |

**No re-freeze. `c0ff827` stands.** Reasserted because "we changed our minds, therefore
re-freeze" is the reflex: every one of these is implementable against the frozen tree.
`CreateThreadRequest.title`, `PATCH`/`DELETE /v1/threads/{thread_id}` and `chat_model_id`
are all already promised, and a second freeze with an identical `contracts/` tree would
make the record say an interface moved when it did not.

## What we are NOT building, and it is the important half

**This change asserts the MECHANISM, never the QUALITY.** Every criterion below is of the
form "four scores exist, carrying this metadata, and the exit code responds to the
threshold". None of them says a score is good.

That is not timidity, it is the only honest thing available. The joined stack runs
`CHAT_MODEL=echo` by default and `EVAL_JUDGE=heuristic`, so the reply is the question echoed
back and the judge is token overlap. Gating on answer quality there would fail every run for
a reason that is not a defect. The two code-based thresholds — routing accuracy and
retrieval recall — DO gate for real, because the router is lexical, the embedder is a local
ONNX model and the ingest summariser is deterministic with no model configured, so those two
numbers are meaningful with no credentials at all. Quality gating on the other two arrives
the day somebody runs `CHAT_MODEL=bedrock EVAL_JUDGE=bedrock`, and that is a run a person
starts on purpose. `stack/dev.env` carries all four thresholds so raising one is a one-line
reviewable change.

## Where the evaluation set lives

One place, and it is a question this change was asked to answer explicitly:

```
chatbot-eval/evalset/
  README.md        the only doc that explains the set and how to extend it
  corpus/<id>.md   the documents. THE FILENAME STEM IS THE FIXTURE ID.
  questions.yaml   input · reference_answer · expected_doc_ids · should_retrieve · notes
```

The corpus is uploaded through `POST /v1/documents` into the eval's own account, so it
becomes a real document collection indexed the real way. `expected_doc_ids` name corpus
entries by their fixture id and are resolved to server-assigned document ids at seed time.
The eval repo's Stop hook refuses a change to the set that does not touch its `README.md`.

## Acceptance criteria (these are the oracle)

1–5, 8–20 and 21–25 are `smoke.yaml` steps. **6 and 7 are `jobs:` in `change.yaml`** — a
one-shot container whose exit code is the assertion, which is the harness capability this
change needed and `docs/adr/0014` decides. **New in this amendment: 21–25.**

**The version endpoint — the one contract change**

- [ ] 1. `GET /api/v1/version` with no session answers **401** `AUTH_REQUIRED`. Which build
      and which model an environment runs is deployment information, and `/healthz` already
      answers liveness for an anonymous caller.
- [ ] 2. With a session it answers 200 carrying `version`, `image_tag`, `git_sha`,
      `chat_model`, `chat_model_id`, `embedding_model` and `retrieval_router`.
- [ ] 3. `image_tag` is the value the stack passed IN (`${BACKEND_IMAGE_TAG}`), not one the
      application invented. A build identity an app makes up for itself is not one.
- [ ] 4. `chat_model` is one of the declared selectors — `echo` or `bedrock` — so the field
      is the real effective setting rather than a free-text label.
- [ ] 5. **The response carries no credential.** No secret, no password, no AWS access key,
      no signup code. This is the criterion that makes an endpoint reporting configuration
      safe to have, and it is asserted rather than reviewed because "report the config" is
      exactly the instruction under which a secret gets added later.

**The run, as a process**

- [ ] 6. One eval run against the joined stack **exits 0** with the thresholds in
      `stack/dev.env`. — job `eval-run-meets-its-thresholds`
- [ ] 7. The same run with `EVAL_THRESHOLD_ROUTING_ACCURACY=1.01` **exits 1**. The gate
      actually gates, and the only way to know that is to breach it. Thresholds are
      therefore NOT range-validated: an impossible one must compare, not be refused.
      — job `a-breached-threshold-exits-non-zero`

**The account, which is the collection**

- [ ] 8. The eval's account exists and the credentials committed in `stack/dev.env` sign in.
      On a cold stack it exists only because the eval registered it, so this is also the
      assertion that the eval provisions its own identity.
- [ ] 9. That account's knowledge base holds the fixture, every document's filename carrying
      `${EVAL_DOCUMENT_PREFIX}` — so the corpus went in through the API and is indexed the
      way a real upload is.
- [ ] 10. **No document in that account lacks the prefix.** The prefix is the only thing the
      eval will ever delete, so this is the assertion behind "an `EVAL_ACCOUNT_EMAIL`
      pointed at a real account by mistake costs nothing".

**The dataset**

- [ ] 11. The question set is a Phoenix dataset named `${EVAL_DATASET_NAME}` holding at
      least one example.
- [ ] 12. **Two runs produce ONE dataset, not two.** The upsert is by name; Phoenix versions
      the content. Asserted after two runs, which is what the two jobs above leave behind.

**The experiment**

- [ ] 13. A Phoenix project named `${EVAL_PHOENIX_PROJECT_NAME}` exists and holds spans the
      eval exported — its own project, not the backend's, and not Phoenix's `default`.
      **Corrected 2026-09-03:** this was originally asserted as `project_name` on the
      *experiment*, and it passed for the wrong reason — Phoenix names an experiment's
      project itself, as `Experiment-<hash>`, so the step was matching the `project_name`
      the eval copies into its own metadata. Measured against a live run.
- [ ] 14. Its metadata carries `image_tag` equal to what the backend reported. The run
      records what it evaluated by READING it, never by being told.
- [ ] 15. Its metadata carries a 64-hex `fixture_hash`, so two runs over different corpora
      are never silently compared.
- [ ] 16. Its metadata carries `chat_model`, `judge` and `judge_prompt_version`. Two runs
      judged by different prompts are not comparable and nothing else would say so.
- [ ] 17. Every run in the experiment has a `trace_id`, and **no run has an `error`**. An
      experiment of ten errored examples would otherwise satisfy every step above.
- [ ] 18. **No run is missing or failed an evaluation** for any of `routing_accuracy`,
      `retrieval_recall`, `groundedness`, `answer_correctness`. This is the four-evaluator
      criterion, asserted through Phoenix's own `incomplete-evaluations` endpoint so an
      empty answer is the pass and a missing evaluator is named in the failure.
- [ ] 20. **One trace, asserted without a project.** The trace id Phoenix assigned an
      experiment run equals the `X-Trace-Id` the backend returned for that request, which the
      eval records as `backend_trace_id` in the run's output. Two fields of one response, so
      no export race can affect it — and that equality is exactly what "the two services were
      in one trace" means. **Added 2026-09-03**, because criterion 19 turned out to depend on
      which project a shared trace is filed under, and measurement showed that is decided by
      whichever exporter's span created the trace row first.
- [ ] 19. **Trace context propagated, read from a project.** The trace id Phoenix recorded for
      an experiment run also resolves in the BACKEND's project, and the backend's
      `POST /v1/threads/{thread_id}/messages` span there has a NON-null parent — because the
      eval's task span is its parent. Note this is the opposite of 0005 criterion 4, which
      requires a null parent: these are different traces, and an ordinary request with no
      inbound `traceparent` is still rooted at the HTTP span.


**A re-run leaves the account as it found it — new in this amendment**

- [ ] 21. **Every thread in the eval account carries `${EVAL_THREAD_PREFIX}` in its title.**
      The marker is what makes the purge safe to have: it is the only thing the eval will
      ever delete, so an `EVAL_ACCOUNT_EMAIL` pointed at a real account loses no
      conversation. Exactly the rail `${EVAL_DOCUMENT_PREFIX}` already is for documents.
- [ ] 22. **Two runs leave one run's threads, not two.** After the two jobs, the canary
      question's thread title appears **exactly once**. Anchored on one reserved question id
      (`q-charter-quorum`) because a regex cannot count duplicates across a list — the same
      reason `two-runs-produced-one-dataset` is written the way it is. The eval owns the
      stronger invariant and refuses if the account holds a thread it did not create.

**What identifies a comparable run — new in this amendment**

- [ ] 23. **The backend's image tag is a version, not a word.** `image_tag` matches
      `local-<major>.<minor>.<patch>`. `dev` was the same string forever, which made the one
      field meant to identify the build unable to.
- [ ] 24. **The experiment records the eval image's own version.** Its metadata carries
      `eval_image_tag` equal to `${EVAL_IMAGE_TAG}`, and the eval never invents it — null
      when nothing supplied one, the same rule `image_tag` has. Evaluator code is a factor
      in a score exactly as the fixture is.
- [ ] 25. **The experiment records the model that produced the answers**, faithfully and in
      full. Two halves: the metadata's `chat_model` equals what `/v1/version` reported —
      captured from the backend's own response, so an eval that took it from its own
      environment fails — and `chat_model_id` is present and well-formed, `null` exactly
      where the contract allows it or a non-empty string. **Amended once more, later the
      same day:** the first spelling asserted `chat_model_id` against a live capture and was
      *unsatisfiable* under `CHAT_MODEL=echo`, the loop's own default, because a captured
      null interpolates as the literal `None`. See § "A gap in the oracle".

## A gap in the oracle

Two things are real and not seam-visible, and saying so is part of the plan.

- **Seeding is idempotent, with no duplicates.** The second job re-seeds; a non-idempotent
  seed would leave two copies of every document. A regex cannot assert "no duplicate
  filenames" over a list, and hard-coding the corpus size in `stack/dev.env` would put the
  fixture's size in two places and drift. So **the eval asserts it and refuses (exit 2)**
  when its account's marked documents are not exactly its fixture after seeding — and the
  jobs stage reports exit 2 distinctly from exit 1, which is what makes that visible rather
  than being read as a threshold breach.
- **The thread count after a run.** Criterion 22 anchors on one reserved question id
  because a regex cannot count duplicate titles across a list — the same wall
  `two-runs-produced-one-dataset` hit. The full invariant is the eval's: after purging and
  seeding, the account holds exactly one thread per example and none it did not create this
  run, and it **refuses (exit 2)** otherwise. The seam holds the marker and the canary; the
  eval holds the count.
- **`chat_model_id` equal to what the backend reported.** Only meaningful when a model is
  configured, and the loop runs `CHAT_MODEL=echo`, where the correct value is `null`. The
  seam asserts the selector against a live capture and the id's presence and shape; the
  equality is asserted by chatbot-eval's own tests, which construct a `VersionResponse`
  carrying an id and check it is copied. Worth knowing WHY the seam cannot do it:
  `smoke.py` stringifies a captured null, so `${var}` bound to null interpolates as the
  four characters `None` and the assertion becomes unsatisfiable rather than failing
  honestly. That is a harness defect rather than a property of this change, and it is in
  the friction log for the retrospective rather than fixed here.
- **The judge, judging.** `EVAL_JUDGE=bedrock` needs credentials the loop must not require.
  Covered by the eval repo's own tests against a recorded judge response, and by the
  metadata criterion 16 — an experiment always says what judged it, so a run with the real
  judge is distinguishable from one without.

## Out of scope

- **Any frontend change.** No eval result surfaced in the UI, no score in front of a user.
  Phoenix is the UI for this, and it already exists.
- **Deploying the eval anywhere.** `deploy.infra: false`, and no infra slice: `infra/` is a
  two-`.gitkeep` scaffold with no IaC tool chosen, so there is nothing to add a CronJob to.
  The best outcome this change can reach is `verified-local` — deliberate, not an oversight.
  The code is already deploy-ready in the only sense that matters: every input is an
  environment variable and there is no `APP_ENV` branch anywhere in it.
- **Retrieval precision, and any chunk-level metric.** Recall is scored and precision is
  not: with `retrieval_top_k: 4` the two are near-complements, and a chunk-level metric
  would need the eval to see chunks, which is the reach-around `docs/adr/0013` forbids.
- **Regression detection between runs.** The eval scores one build. "Is this worse than last
  week" is a question about a series, and Phoenix's experiment comparison already answers it
  for a human. Automating it needs a baseline policy, which is its own decision.
- **An eval collection concept in the backend.** The knowledge base is already account
  scoped, so the eval's account IS its collection. `docs/adr/0013` §2 records why a second
  isolation mechanism would be a weaker copy of the one that exists.
- **A vector-DB URL in the eval's configuration.** Asked for in the original task
  description and deliberately dropped — `docs/adr/0013` §1. The eval uploads through
  `POST /v1/documents` and reads `citations`; it never opens OpenSearch.
- **Reading routing and retrieval out of the TRACE.** Also asked for, also dropped:
  `Message.retrieval_consulted` and `Message.citations[].document_id` are promised by the
  contract for exactly this purpose, and span attributes explicitly are not contract.
- **A single `run_signature` over all the comparability factors.** Tempting, and it is the
  natural generalisation of criteria 15, 24 and 25 — one hash that says "these two
  experiments are comparable" instead of seven fields a reader compares by eye. Not built:
  it is a new concept nobody asked for, and every factor is already recorded individually,
  so the signature is derivable by anyone who wants it. Named here so the omission is a
  decision.
- **Deriving the image tag from the git SHA.** `git_sha` already reports that, and it
  answers a different question — "which commit" rather than "which build a person chose to
  cut". `docs/adr/0015` records why the hand-bumped version is the one that gates.
- **A version endpoint on the eval.** It is a one-shot process, not a service; it reads
  `EVAL_IMAGE_TAG` from its environment and records it. There is nothing to serve.
- **Deleting the eval's threads at the END of a run.** The purge is at the START, so the
  most recent run's transcripts survive for a person to read. Deleting on the way out would
  leave nothing to look at after a failure, and Phoenix's traces are not a substitute for
  the stored transcript.
- **Sampling, cost accounting, latency thresholds.** Every one is a later, additive
  evaluator against the same experiment. Named so an agent asked for "eval" does not build
  six.

## Contract changes

**One new path: `GET /v1/version`**, session-required, in `contracts/openapi.yaml`.

Additive: nothing that exists today changes meaning and no consumer is affected. It exists
because `docs/adr/0013` forbids the alternative — the eval reading the backend's environment
or its image label — and this is the shape that rule forces. When the API cannot answer a
question, the answer is to move the API.

It reports selectors and build identity only: `chat_model` and `chat_model_id`,
`embedding_model`, `retrieval_router`, `version`, `image_tag`, `git_sha`. **Deliberately not
the retrieval tuning values** — `retrieval_top_k`, the score floor, the fusion weights —
even though they change what a recall number means. Promising them makes them contract, and
they are internals that should move freely. `retrieval_router` is in because it is a
behavioural mode rather than a tuning value: a recall figure produced under an LLM router
and one produced under the lexical router are not the same measurement, and a reader of an
experiment has to be able to tell.

`contracts/README.md` gains one section saying what the endpoint promises and what may not
be inferred from it.

The freeze SHA does NOT go here. It goes in `change.yaml` as `freeze_sha`.

## Deployment

- Local stack, smoke and both jobs: always.
- Infra deploy: **no** — see § Out of scope. `verified-local` is the ceiling.

## Slices

- `chatbot-backend.md` — `GET /v1/version` and nothing else.
- `chatbot-eval.md` — the whole eval: toolchain, image, compose service, evalset, run flow,
  four evaluators, thresholds, exit codes.

The control repo also changes, and that is not a slice. It landed first, in
`62c9c21`: the fourth submodule and its ten hand-kept repo lists, `jobs:` as a stage of the
verify loop, `stack/compose.yml`'s `eval` service and owner label, `stack/dev.env`'s
variables, `make eval`, and `docs/adr/0013` and `docs/adr/0014`.

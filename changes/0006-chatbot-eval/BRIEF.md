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

1–5 and 8–19 are `smoke.yaml` steps. **6 and 7 are `jobs:` in `change.yaml`** — a one-shot
container whose exit code is the assertion, which is the harness capability this change
needed and `docs/adr/0014` decides.

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

- [ ] 13. An experiment exists on that dataset, filed under project
      `${EVAL_PHOENIX_PROJECT_NAME}` — the eval's own, not the backend's.
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
- [ ] 19. **Trace context propagated.** The trace id Phoenix recorded for an experiment run
      also resolves in the BACKEND's project, and the backend's
      `POST /v1/threads/{thread_id}/messages` span there has a NON-null parent — because the
      eval's task span is its parent. Note this is the opposite of 0005 criterion 4, which
      requires a null parent: these are different traces, and an ordinary request with no
      inbound `traceparent` is still rooted at the HTTP span.

## A gap in the oracle

Two things are real and not seam-visible, and saying so is part of the plan.

- **Seeding is idempotent, with no duplicates.** The second job re-seeds; a non-idempotent
  seed would leave two copies of every document. A regex cannot assert "no duplicate
  filenames" over a list, and hard-coding the corpus size in `stack/dev.env` would put the
  fixture's size in two places and drift. So **the eval asserts it and refuses (exit 2)**
  when its account's marked documents are not exactly its fixture after seeding — and the
  jobs stage reports exit 2 distinctly from exit 1, which is what makes that visible rather
  than being read as a threshold breach.
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

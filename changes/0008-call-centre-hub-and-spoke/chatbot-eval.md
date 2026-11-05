# 0008 — chatbot-eval slice

## What to build

The backend now answers from three spokes — `documents`, `calls`, `general` — and records
which on each assistant message as `route`; call sources arrive as `call_citations`. Refactor
the eval — code, sets and methodology — to measure that.

### 1. The test bed

- `evalset/documents/` (today's `corpus/`, moved) and **`evalset/calls/`**: fixture calls,
  one file each, in the event's shape but with **relative times** (`ended_offset_h`, at least
  1 h in the past, all within 6 days) so a run is always inside retention. Ids
  `CALL-EVAL<6 digits>`; **`CALL-EVAL000001` is reserved** — the control repo's suite reads
  it. Invented world, as the documents are: facts a base model cannot know.
- `questions.yaml`: every question has `expected_route` (`documents` | `calls` | `general`),
  `expected_doc_ids` or `expected_call_ids` as applicable, and a `stratum`. Stratified: at
  least 6 per route, plus at least 4 deliberate confusers (a document question using the
  word "call"; a calls question with no id but a queue and a date; small talk mentioning a
  document's topic loosely; a question naming a call id that does not exist → `calls`, no
  citations, answer says it found nothing). Calls strata: by-id lookup, metadata filter,
  semantic. No aggregate counting questions — the simulator makes them move every minute.
- `evalset/README.md` documents the methodology: strata, why each confuser exists, how to
  add a question, why times are relative, and what is deliberately not measured.

### 2. Seeding calls — through the queue, never around it

Publish each fixture as a `CallCompleted v1` event to `EVAL_CALL_QUEUE_URL` (required; exit 2
naming it when unset), validated against the vendored schema before sending, timestamps
computed from the run's start. Then poll `GET /v1/calls/{id}` until each reads back with the
`ended_at` just published; timeout or mismatch is exit 2 (seed invariant). SQS client: when
`EVAL_SQS_ACCESS_KEY_ID`/`EVAL_SQS_SECRET_ACCESS_KEY` are set, use them for that client
ONLY (the Bedrock judge keeps the default chain); endpoint = the queue URL's origin.

This is the one widening of your ADR 0001: a contracted event stream is an interface, not a
datastore. Record it in an ADR; the gate keeps refusing OpenSearch, S3 and postgres clients.
Calls are organisation data, so the eval account sees the simulator's calls too — the
questions must be anchored to fixture facts, never to "the latest call".

### 3. Evaluators — same four names, new meaning where routing changed

- `routing_accuracy`: `route == expected_route`. Absent `route` scores null.
- `retrieval_recall`: expected ids vs cited ids — document ids from `citations` for
  `documents`, call ids from `call_citations` for `calls`; null for `general`.
- `groundedness`: against the full stored content of what was cited — documents through
  `/content`, calls through `GET /v1/calls/{id}` transcripts.
- `answer_correctness`: unchanged.
- The summary prints per-route aggregates and a coordinator confusion matrix.
- Experiment metadata adds `calls_fixture_hash` (sha256, 64 hex) beside `fixture_hash`.

Existing exit-code doctrine unchanged; thresholds keep their names.

### 4. Documentation, skills, agents

- Update `docs/architecture.md` (the run order with call seeding, the evaluator table, the
  configuration table with the three new variables), `README.md`, `CLAUDE.md`; the ADR above.
- Add `.claude/skills/` and `.claude/agents/` (none today): e.g. a skill `add-an-eval-question`
  (strata, ids, fixture, README update, hashes) and an agent `experiment-analyst` that
  compares two Phoenix experiments and says first whether their metadata makes them
  comparable.
- Make this repo's gate fail when `src/` or `evalset/` changed against `origin/main` and none of
  `docs/`, `README.md`, `CLAUDE.md`, `evalset/README.md` did.

## Contract entries this depends on

- `contracts/events/call-completed.v1.schema.json` — what you publish.
- `contracts/openapi.yaml` → `getCall`, `listCalls`, `Message.route`,
  `Message.call_citations`, `CallCitation`.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and report
it rather than working around it.

## Verification

- [ ] unit: fixture loading and relative times; event validation before publish; the seed
      invariant (read-back mismatch → 2); each evaluator per route incl. nulls; per-route
      aggregation; `calls_fixture_hash` stable across runs and changing when a fixture does.
- [ ] `make contract` green (every path called is declared).
- [ ] the repo's own gates pass, including the new docs check.

## Smoke — what this slice is actually judged on

The two `jobs:` in `change.yaml` (thresholds met → 0; an impossible threshold → 1) and every
step with `owner: chatbot-eval`: the dataset covers all three `expected_route` values, the
experiment carries `calls_fixture_hash`, every example ran without error, all four evaluators
scored every example, and `CALL-EVAL000001` is readable through the API. The assertions
belong to the control repo: fix the cause, never the assertion.

## Notes

- The stack passes `EVAL_CALL_QUEUE_URL=http://elasticmq:9324/000000000000/calls` and the two
  `EVAL_SQS_*` values; waits for `call-worker` healthy before the eval starts.
- `EVAL_IMAGE_TAG` is bumped to `local-0.1.0` in the control repo.
- Routing accuracy is gated at 0.8 under the heuristic coordinator; the question set must be
  honest, not tuned to the heuristic — a confuser it gets wrong is a finding, report it.

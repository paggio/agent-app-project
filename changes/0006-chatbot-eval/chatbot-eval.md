# 0006 — chatbot-eval slice

## CORRECTED, 2026-09-09 — read this first

`make eval JUDGE=bedrock` failed with a message that blamed the credentials:

```
Could not load credentials to authenticate with AWS client ... You must specify a region.
```

The credentials were fine. `chatbot-eval/.env` held the three AWS credential names and **no
region**, boto3 resolves a region from the environment or refuses, and it reports that
inside a sentence beginning "could not load credentials" — so the message sent its reader
to look at the wrong thing.

**The control repo has already fixed the cause**: `stack/secrets.env` is now one gitignored
file holding the whole joined stack's provider credentials, delivered to this service by
`env_file:` in `stack/compose.yml`, and `docs/adr/0016` is the decision. You do not need to
change how you read AWS configuration — you still read none of it, boto3 does.

### The blocker from the 2026-09-09 dispatch, and its resolution

You reported that you cannot create `.env.example` because this repo's committed
`.claude/settings.json` denies `Edit(./.env*)`, which globs onto the template. **You were
right to report it rather than work around it, and your second option is the correct one:
narrow the rule.**

`.gitignore` here already carries `!.env.example`, so this repo has two committed config
files that contradict each other — the template is *meant* to be committed and the deny
rule makes it unwritable. That is the shape the control repo's `docs/adr/0008` exists to
dissolve: when the correct engineering action is the one a stated rule forbids, the rule is
wrong. **Fix the rule, in the same commit as the template**, and say why in the commit
message.

Narrow it so real credential files stay protected and the committed template does not:
replace `Edit(./.env*)` with rules that cover `.env` and `.env.local` and leave
`.env.example` writable. Do not simply delete the protection, and do not add an allow rule
that re-permits every `.env*` path.

**Two things ARE yours, and neither is large:**

1. **Ship a `.env.example`.** §3 has always required one and this repo has none — which is
   how a person came to write a credentials file with no region in it. It must name
   `AWS_REGION`, and it must say that in the joined stack the file to fill in is the control
   repo's `stack/secrets.env` and this one is only for running this repo standalone.

2. **Refuse EARLY and name the missing variable.** Under `EVAL_JUDGE=bedrock`, check before
   constructing the client that a region is resolvable — `AWS_REGION` or
   `AWS_DEFAULT_REGION` in the environment — and if not, refuse (**exit 2**) with a message
   that names the variable and points at `stack/secrets.env`. A pydantic validation dump is
   a correct refusal and an unreadable one; §6's exit codes already put this in the
   "refused to judge" class, so only the message changes.

   Do not go further than that. Do NOT default a region, do NOT read `~/.aws`, and do NOT
   probe AWS to find out whether the credentials work — a default region is a guess that
   succeeds in the wrong account, and boto3 remains the only thing here that touches an
   AWS_* variable.

**Nothing else changes.** No criterion is removed, no evaluator moves, and the corpus and
question set are untouched. Everything in the amendment of 2026-09-07 below still stands.


## AMENDED, 2026-09-07 — read this before the rest

Your branch already carries a working eval and its pull request is open. This amendment
changes four things. **Where this section and the sections below disagree, this wins.**
Nothing is removed — every criterion the first version passed still has to pass, and the
suite grew from 22 steps to 27.

1. **Threads are purged, and marked.** New, and it is the substantial one — §12 below.
   Measured before asking: the eval account had accumulated **36 threads** over two runs and
   nothing had ever deleted one, against a contract cap of 200 on `GET /v1/threads`.
2. **The experiment records the eval image's own version** — `eval_image_tag` from
   `EVAL_IMAGE_TAG`, §13. New metadata field.
3. **The printed summary must name the backend's model**, §14. It currently names the
   JUDGE's model and nothing about what produced the answers.
4. **`chat_model_id` in the metadata is now a requirement rather than a courtesy.** You
   already record it and the value is already right; a step now asserts it equals what
   `/v1/version` reported. No change expected — listed so you do not remove it as
   redundant.

Two things that are NOT changing, stated because they are the plausible misreadings:

- **No contract change, and no re-freeze.** `c0ff827` stands. `CreateThreadRequest.title`,
  `DELETE /v1/threads/{thread_id}` and `chat_model_id` are all already promised by the
  frozen tree. If you think otherwise, report `blocked-by-contract` with the entry.
- **The corpus and the question set do not change.** In particular `q-charter-quorum` must
  keep that exact id — see §12.

---

## 12. Threads: purge at the start, mark at creation

The eval creates one chat per example and has never removed one. A re-run must leave the
account as it found it, exactly as the document seed already does.

**Mark at creation, not afterwards.** `CreateThreadRequest.title` is optional, settable at
create and capped at 200 characters, so `POST /v1/threads` with
`{"title": "${EVAL_THREAD_PREFIX}<question-id>"}` costs no extra request. Do NOT rename
afterwards with `PATCH`; that is 18 avoidable calls.

**Purge at the START of a run**, right beside the document seed and with the same shape:

1. `GET /v1/threads`.
2. Partition on the title prefix. **Threads whose title does not start with
   `EVAL_THREAD_PREFIX` are ignored entirely and never deleted.** This is the safety rail,
   not a convention: an `EVAL_ACCOUNT_EMAIL` pointed at a real account must lose no
   conversation, and it is the same argument that governs the document prefix.
3. `DELETE /v1/threads/{thread_id}` for each marked one.
4. Create this run's threads as the task runs, titled as above.
5. **Then assert the invariant and refuse (exit 2) if it does not hold**: after the run, the
   account holds exactly one marked thread per example and none it did not create this run.
   The seam cannot check this — a regex cannot count duplicate titles across a list — so it
   is yours, and `BRIEF.md` § "A gap in the oracle" records that it is yours.

**At the START and not the end**, deliberately: the most recent run's transcripts survive
for a person to read after a failure. Deleting on the way out would leave nothing to look at,
and a Phoenix trace is not a substitute for the stored transcript.

`q-charter-quorum` is the **canary**: `two-runs-leave-one-runs-threads` asserts that
`${EVAL_THREAD_PREFIX}q-charter-quorum` appears exactly once in the thread list. Keep that
question id exactly as it is, and say in `evalset/README.md` that it is load-bearing and why
— it is the same deliberate coupling the four evaluator names already have.

## 13. The eval image's own version

`EVAL_IMAGE_TAG` from the environment, recorded in `experiment_metadata` as
`eval_image_tag`. **Never invent it** — null when nothing supplied one, the same rule the
backend's `image_tag` has and for the same reason: a build identity a process makes up for
itself is not one. Do not fall back to the package version, the git tree or a constant.

Why it matters, since it is one more string in a metadata blob: the evaluator code is as much
a factor in a score as the fixture is. Two runs over an identical corpus with a rewritten
groundedness evaluator are not comparable, and before this nothing recorded which evaluators
produced a number. `docs/adr/0015` is the decision.

## 14. The summary names what produced the answers

`render()` prints `judge <name> (<judge model id>) prompt v<n>` and says nothing about the
backend. That summary is the only evidence a failing job hands back, and a reader of it
cannot currently tell which model wrote the answers being scored — which is the question a
low `answer_correctness` immediately raises.

Add a line naming the backend's `chat_model` and, when it is not null, `chat_model_id`, and
the `image_tag` beside it. Keep the judge line: the two are different models and conflating
them is the confusion this fixes. Read from the `VersionResponse` you already fetch, never
from your own environment.


Your repo is a **scaffold**: `CLAUDE.md`, `.claude/` (settings, Stop hook, format hook),
`docs/architecture.md`, `docs/adr/0000-template.md`, `contracts/` (vendored, read-only),
`README.md`, `.gitignore`, `.github/workflows/ci.yml`. There is no toolchain, no image and
no code. This slice builds all of it.

**Read `docs/architecture.md` first.** It carries the decisions that are already made and
must not be re-derived — the black-box constraint, the account-as-collection, the two Phoenix
projects, the two judges. `CLAUDE.md` is the working agreement. Where this file and
`docs/architecture.md` agree, they agree on purpose; where you think they disagree, say so
rather than picking one.

---

## 1. The toolchain

Python 3.13, managed with `uv`. Mirror `chatbot-backend`'s shape, because the two repos are
read by the same people: `pyproject.toml` with `ruff` and `mypy --strict`, `pytest` with a
`provider` marker excluded by default, a `Makefile` where every command a person needs is a
target, a `Dockerfile`, a `docker-compose.yml`.

Pin `arize-phoenix` and every `openinference-*` package **exactly**, and say in `CLAUDE.md`
that they are bumped as a set. This repo's whole output is Phoenix API calls; a floating
minor there is a run that stops working for a reason nobody will look for.

`make help` must list, at minimum: `test`, `typecheck`, `lint`, `contract`, `build`, `run`.
`make run` is one eval run against the configured backend.

### The Makefile's `contract` target

`make contract` proves every path this repo calls is declared in `contracts/openapi.yaml`.
Keep it simple and keep it honest: collect the request paths the code can issue — a module
of path constants is the easy way — and check each against the vendored spec's `paths`,
allowing for `{param}` templating. It is not a schema check; it is the check that this repo
never calls surface the backend has not promised. A path that is not there is a contract
change in the control repo, not a change here.

---

## 2. The image, and the compose service

`Dockerfile`: a slim Python 3.13 base, `uv sync --frozen`, **`evalset/` copied in**. The test
bed ships inside the image as one unit with the code — that is what makes a `fixture_hash`
mean something.

`docker-compose.yml` declares **one service named `eval`**, and the name is load-bearing:
the control repo's `stack/compose.yml` labels it, waits on the backend and Phoenix for it,
and runs it by that name. Requirements:

- **`profiles: ["manual"]`**. Non-negotiable. Without it `docker compose up --wait` waits
  forever for a container whose job is to exit, and the joined stack never comes up.
- `build: {context: .}` and a pinned local image name, like the backend's `chatbot-eval:dev`.
- **No `depends_on`** on `backend`, `proxy` or `phoenix`. Your compose file cannot name
  services it does not ship — that is what makes it valid standalone — and the control repo's
  `stack/compose.yml` adds those waits. This is the same rule the backend follows for the
  proxy.
- **No host bind mount for data, and no `external: true` volume.** `docs/adr/0011` in the
  control repo makes `down` a clean slate, and its `check-docs.py` reads your compose file
  and fails on either. A read-only config mount is fine; state is not.
- `env_file: {path: .env, required: false}` for AWS credentials, exactly as the backend does
  it — optional, so a fresh clone and CI come up with no `.env` at all. Ship a `.env.example`
  listing what a real judge needs, and never a real value.
- Every other input comes from `environment:` with a **default that fails closed**, and it
  reads them from the process environment only. No `env_file` for configuration.

Read `stack/compose.yml`'s `eval:` block (it is on your `--add-dir`): it is the authority on
what the joined stack passes you, and the defaults there are the ones to agree with.

---

## 3. Configuration

Every input is an environment variable. **No `APP_ENV` branch anywhere**, ever — the same
image runs locally and as a k8s Job, and only these move.

| Variable | Required | Meaning |
| --- | --- | --- |
| `EVAL_BACKEND_BASE_URL` | **yes** | e.g. `http://proxy:8080/api`. Includes the `/api` prefix; every path is appended to it. |
| `EVAL_PHOENIX_BASE_URL` | **yes** | e.g. `http://phoenix:6006`. The OTLP traces path is built from it, not assumed. |
| `EVAL_PHOENIX_PROJECT_NAME` | yes | the project your OWN spans go to |
| `EVAL_DATASET_NAME` | yes | the Phoenix dataset the question set is upserted into |
| `EVAL_ACCOUNT_EMAIL` · `EVAL_ACCOUNT_PASSWORD` | **yes** | the eval's own account |
| `SIGNUP_CODE` | no | needed only to register on a cold stack |
| `EVAL_DOCUMENT_PREFIX` | yes | the filename marker; default `eval__` |
| `EVAL_THREAD_PREFIX` | yes | the thread-TITLE marker, and the only prefix it will delete; default `eval__` |
| `EVAL_IMAGE_TAG` | no | this image's own version. Recorded in the metadata; **never invented** — null when unset |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | for `bedrock` | not read by your code — boto3 reads them. Required for the bedrock judge, and their absence is what you now refuse on. From `stack/secrets.env` in the joined stack |
| `EVAL_JUDGE` | yes | `heuristic` or `bedrock`; default `heuristic` |
| `EVAL_JUDGE_MODEL_ID` | no | recorded in metadata even when unused |
| `EVAL_JUDGE_PROMPT_VERSION` | no | bumped by hand when the judge prompt changes |
| `EVAL_THRESHOLD_ROUTING_ACCURACY` · `_RETRIEVAL_RECALL` · `_GROUNDEDNESS` · `_ANSWER_CORRECTNESS` | no | floats. Absent means that evaluator does not gate. |

**Required means the process refuses — exit 2 — with the name of the variable.** Not a
default, not a guess. An eval that invented a backend URL would measure the wrong thing and
report a number.

**Thresholds are NOT range-validated.** `1.01` must be accepted and compared, because
breaching a threshold on purpose is how the exit code is proved — see §9 and the second job
in `change.yaml`. A validator that refused it would turn that assertion into a refusal.

---

## 4. The evaluation set

```
evalset/
  README.md
  corpus/<fixture-id>.md
  questions.yaml
```

**`evalset/README.md` is the deliverable here, not an afterthought.** It is the one place
that explains what the set is and how to extend it: how to add a document, how to add a
question, what each field means, what makes a good question and what makes a useless one.
Your Stop hook refuses a change to `corpus/` or `questions.yaml` that does not touch it.

### The corpus

`corpus/<fixture-id>.md` — the filename stem IS the fixture id, so there is no second
manifest file to drift out of step with the directory. Markdown and plain text; a PDF is
possible later and is not needed now.

**Write invented content**, and this matters more than it looks. A question the base model
can answer from its own training measures nothing about retrieval: the reply is right whether
or not the document was found. So the corpus is a small self-consistent fictional world —
`chatbot-backend`'s own tests use "The Quillhaven Charter" and that is the right instinct.
Eight to twelve documents, a few hundred words each, each about a distinct subject so that
lexical routing has something to decide on.

### The questions

`questions.yaml`:

```yaml
questions:
  - id: q-charter-quorum
    input: "What quorum does the Quillhaven Charter require?"
    reference_answer: "Two thirds of seated delegates."
    expected_doc_ids: [quillhaven-charter]
    should_retrieve: true
    notes: single-document lookup; the answer is one clause
```

- `expected_doc_ids` name **corpus entries by fixture id**, resolved to server-assigned
  document ids at seed time.
- `should_retrieve: false` for questions that must NOT trigger retrieval — general knowledge,
  small talk, arithmetic. **Include several.** Routing accuracy over a set where the answer
  is always "yes" is not a measurement, and the router is the component most likely to
  regress.
- Cover: single-document lookup, a question whose answer spans two documents, a question
  about something the corpus does not contain (`should_retrieve: true`, `expected_doc_ids:
  []` — the router should look and find nothing, which is a different fact from not looking),
  and the `should_retrieve: false` cases.
- 12–20 questions. Enough to make a mean mean something, small enough that a run is quick.

---

## 5. The run flow

Idempotent, in this order. Every step is HTTP.

### 5.1 Read the configuration, then read the backend

`GET {backend}/v1/version` **after signing in** — it is session-required. Take `image_tag`,
`chat_model`, `chat_model_id`, `embedding_model` and `retrieval_router` from it. **Never take
any of them from your own environment or from a flag.** A run told its own image tag records
what the caller believed; a run that reads it records what is serving. The control repo's
suite asserts that the tag in your experiment metadata equals the one the backend reported.

### 5.2 Sign in, or register

`POST /v1/auth/login` with `EVAL_ACCOUNT_EMAIL` / `EVAL_ACCOUNT_PASSWORD`. On 401,
`POST /v1/auth/register` with those plus `SIGNUP_CODE`, then proceed. Both paths must work,
because the joined stack forgets everything on `down` — a cold stack needs the register path
and a warm one needs the login path, from the same two committed values.

The session is an `httpOnly` cookie. Keep a cookie jar for the whole run.

### 5.3 Seed the account's knowledge base

**The eval's account IS its dedicated collection.** There is no collection concept in the
backend and you must not invent one. What that means concretely:

1. `GET /v1/documents`.
2. Partition on the filename prefix. **Documents without `EVAL_DOCUMENT_PREFIX` are ignored
   entirely and never deleted.** This is the safety rail: an `EVAL_ACCOUNT_EMAIL` pointed at
   a real account by mistake must cost nothing.
3. For the marked ones, `GET /v1/documents/{id}/content` and hash the bytes. If the set of
   (fixture id, content hash) matches `corpus/` exactly, **upload nothing** — that is the
   idempotent path and a second run in the same stack must take it.
4. On any mismatch — a missing document, an extra one, changed content — `DELETE` every
   marked document and upload the whole corpus fresh. Partial repair is not worth the
   complexity and a half-seeded collection is worse than a re-seeded one.
5. Upload with `POST /v1/documents`, `filename` = `{prefix}{fixture-id}.md`.
6. Keep the fixture-id → document-id map. `expected_doc_ids` are resolved through it.
7. **Then assert the invariant and refuse if it does not hold** (exit 2): after seeding, the
   account's marked documents are exactly the fixture, one document per fixture id, no
   duplicates. The control repo's suite cannot check this — a regex cannot count duplicate
   filenames — so it is yours, and `BRIEF.md` § "A gap in the oracle" records that it is
   yours.

`fixture_hash` = sha256 over the sorted `(fixture-id, bytes)` pairs of `corpus/`. Corpus
only, not the questions: Phoenix versions the question set and that is its job. Hash
`questions.yaml` separately as `questions_hash` and record both — Phoenix's version id is
opaque, and two runs should be comparable without opening Phoenix to find out.

### 5.4 Upsert the dataset

Upsert by **name** (`EVAL_DATASET_NAME`), so two runs leave ONE dataset and Phoenix adds a
version. The suite asserts exactly that: a create-instead-of-upsert leaves two datasets with
the same name and fails.

Each example: `input` holds the question, `output` holds the `reference_answer`, and
`metadata` holds `expected_doc_ids`, `should_retrieve` and the question `id`.

### 5.5 Run the experiment

`run_experiment` against that dataset. The task, per example:

1. `POST /v1/threads` → a fresh chat, **titled `${EVAL_THREAD_PREFIX}<question-id>`** (see
   §12). **One chat per example**, so no example sees another's history —
   `HISTORY_MAX_MESSAGES` is 20 and a shared chat would make later examples depend on
   earlier ones.
2. `POST /v1/threads/{thread_id}/messages` with the question, **with W3C trace context
   injected into the request headers** so the backend's spans nest under your task span.
3. Record from the response: the assistant `Message`'s `content`, its `retrieval_consulted`,
   its `citations`, and the `X-Trace-Id` response header.

**It must be this endpoint, not `POST /v1/chat`.** `/v1/chat` returns only `reply`;
`retrieval_consulted` and `citations` are on the `Message` in `SendMessageResponse`, and they
are the evidence two of the four evaluators are built on.

The task's output is what the evaluators read, so put all of it there: the answer, the
retrieval decision, the citations, and the trace id.

**Name the trace id field `backend_trace_id`.** The control repo's suite asserts that it
equals the trace id Phoenix assigned the run, which is the one assertion of trace propagation
that cannot race — see §10. Record the header's value verbatim, and record nothing when the
header is absent rather than inventing one.

`experiment_metadata` — and the suite asserts four of these:

```
image_tag, git_sha, chat_model, chat_model_id, embedding_model, retrieval_router,
fixture_hash, questions_hash, judge, judge_model, judge_prompt_version,
eval_image_tag
```

`eval_image_tag` is new in the 2026-09-07 amendment (§13) and `chat_model_id` is now
asserted rather than assumed (§14 of `BRIEF.md`'s criteria: 24 and 25).

`judge` is `heuristic` or `bedrock`. Everything from §5.1 is copied through unchanged.

Your own tracer provider exports to `EVAL_PHOENIX_PROJECT_NAME`. **Do not try to make the
backend export to your project** — a service's project is its own configuration, and a client
that could choose one would be a way to write into anybody's store. One example draws one
trace whose halves live in two projects; the trace id is the join.

### 5.6 The four evaluators

Names are **exact**. The control repo's suite queries Phoenix by these strings:

`routing_accuracy` · `retrieval_recall` · `groundedness` · `answer_correctness`

| Name | Kind | Score | Applies to |
| --- | --- | --- | --- |
| `routing_accuracy` | CODE | 1.0 when `retrieval_consulted` equals `should_retrieve`, else 0.0 | every example |
| `retrieval_recall` | CODE | \|cited ∩ expected\| / \|expected\| over `citations[].document_id` vs the resolved `expected_doc_ids` | examples with a non-empty `expected_doc_ids` |
| `groundedness` | LLM | is the answer supported by the cited documents | examples with a non-empty `citations` |
| `answer_correctness` | LLM | does the answer match `reference_answer` | every example |

Three things to get right:

- **`retrieval_consulted` may be ABSENT.** The contract says absence means "not applicable",
  not false. On a turn produced by a backend that answered from a version before knowledge
  bases existed there is no field. Treat absent as **no score**, not as a wrong answer.
- **An evaluator that does not apply records NO score for that example** — not a zero.
  Scoring a `should_retrieve: false` question as ungrounded would make the aggregate a
  measurement of the question set rather than of the backend. Phoenix's evaluation body takes
  either a result or an error; a not-applicable example simply gets no evaluation... **except**
  that the control repo asserts through `incomplete-evaluations` that no run is *missing* any
  of the four. So record a result with `score: null` and an `explanation` saying it did not
  apply. That is present-but-unscored, which is what the aggregate needs and what that
  endpoint needs.
- **Groundedness reads the WHOLE cited document**, fetched with
  `GET /v1/documents/{id}/content` — not `citations[].snippet`. The contract says the snippet
  is "truncated for display", so judging against it invents hallucinations that did not
  happen. The claim you are making is "supported by the cited documents", and that is the one
  the evidence supports.

### 5.7 The two judges

`EVAL_JUDGE` selects, one branch, no `APP_ENV` check — the same seam as the backend's
`CHAT_MODEL` and `RETRIEVAL_ROUTER`.

- **`heuristic`** — no credentials, no network, deterministic. Something honest and simple:
  content-word overlap of the answer against the reference for correctness, and of the answer
  against the grounding text for groundedness, with stop words removed. It exists so the
  whole pipeline — the experiment, four score columns, the thresholds, the exit code — runs
  in the control repo's loop and in CI on a machine with no AWS access. **It proves the
  mechanism and never the quality**, and the docstring should say so in those words, because
  the next reader will otherwise take its number seriously.
- **`bedrock`** — a real LLM judge. Ask for a 0–1 score and a one-line explanation, parse it
  strictly, and record an evaluation *error* rather than a zero when the response cannot be
  parsed. A judge that silently scores 0 on a malformed reply turns an outage into a
  regression.

Bump `EVAL_JUDGE_PROMPT_VERSION` by hand when a judge prompt changes, and say in
`evalset/README.md` that this is a thing a person has to do.

### 5.8 Aggregate, and exit

Mean per evaluator over the examples it applied to. Compare each against its threshold when
one is configured. Print a readable summary — per-evaluator mean, the threshold, pass or
fail, the example count, and the experiment's Phoenix URL — because that summary is the only
evidence a failing job hands back.

## 6. Exit codes

Load-bearing, and the same convention the control repo uses. `docs/adr/0003` there is the
reasoning; `CLAUDE.md` here already states them.

| Code | Means |
| --- | --- |
| **0** | every configured threshold met |
| **1** | the thing under test failed: a threshold breached, **or any example errored** |
| **2** | this process refused to judge: a required variable missing, the backend or Phoenix unreachable, the fixture unreadable, the seed invariant broken, or **zero examples ran** |

Two of those are the whole point and are easy to get wrong:

- **Any errored example is exit 1.** `run_experiment` records a per-example error and carries
  on, so a completely broken backend otherwise yields ten errors, zero applicable examples,
  and a green aggregate. That is the vacuous pass `docs/adr/0003` exists to forbid.
- **Zero examples ran is exit 2, not 0.** A pass over nothing is a refusal, not a pass.

**And the PRECEDENCE between them is load-bearing**, which the first version of this brief
failed to say. Two of these can be true at once and they mean opposite things: a backend that
answers 500 to every turn leaves every evaluator with nothing to average, so it is
simultaneously "everything errored" and "the threshold compared against nothing". Decide in
this order:

1. **Zero examples ran** → refuse (2). Nothing was measured.
2. **Anything errored** → **1**, and decide this BEFORE any threshold check. An errored
   example is a fact about the thing under test, and the errors *explain* the empty
   aggregate rather than being a separate missing precondition. Reporting a broken backend
   as this process declining to judge sends the failure to the wrong repo — the control
   repo's jobs stage reads exit 2 as "a precondition was missing".
3. **Only then**, with nothing errored, a configured threshold that still compared against
   nothing → refuse (2). That is reachable with no error at all — a question set where every
   example is not-applicable for one evaluator whose threshold is set — and it is a gate over
   nothing.

A refusal should still print the summary table. The message says why this process would not
judge; the table says what it saw when it decided.

## 7. Contract entries this depends on

- `contracts/openapi.yaml` → `POST /v1/auth/login`, `POST /v1/auth/register`,
  `POST /v1/auth/logout`
- `contracts/openapi.yaml` → `GET /v1/version` (**new in this change**) and
  `components.schemas.VersionResponse`
- `contracts/openapi.yaml` → `POST /v1/documents`, `GET /v1/documents`,
  `GET /v1/documents/{document_id}/content`, `DELETE /v1/documents/{document_id}`
- `contracts/openapi.yaml` → `POST /v1/threads`, `POST /v1/threads/{thread_id}/messages`
- `contracts/openapi.yaml` → `components.schemas.Message` — specifically
  `retrieval_consulted` and `citations`, and `components.schemas.Citation.document_id`
- `contracts/README.md` → § "Trace correlation" (the `X-Trace-Id` header, and that a
  consumer must tolerate its absence), § "Documents, the knowledge base, and what a citation
  promises", § "What `GET /v1/version` promises"

The contracts are FROZEN. If this slice appears to require a contract change, STOP and report
it rather than working around it — `blocked-by-contract`, with the exact entry.

**`X-Trace-Id` may be absent** and the contract says a consumer must tolerate that. Do not
require it: record it when present, and let the run continue without it. An eval that crashed
because tracing was off would be unusable in the one environment where tracing is off.

## 8. Out of scope for this slice

- Any datastore client — no `opensearchpy`, no `boto3` for S3, no postgres driver. Your Stop
  hook refuses the import. `boto3`/`langchain-aws` for **Bedrock** is fine: that is the judge,
  not the backend's storage.
- Comparing this run against a previous one. The eval scores one build; "is this worse than
  last week" is a question about a series, and Phoenix already answers it for a human.
- Deploying anything. No k8s manifests, no Helm chart. `infra/` can deploy nothing today.
  Say what an environment must supply — it is the table in §3 — in `docs/`, and stop there.
- Latency, cost or token evaluators. Additive later against the same experiment.

## 9. Verification

- [ ] `make test`, `make typecheck`, `make lint`, `make contract` all pass
- [ ] tests for both judges over recorded inputs, with the `bedrock` one behind the
      `provider` marker so the default run and the gate never call a real model
- [ ] a test that a missing required variable is **exit 2** and names the variable
- [ ] a test that an errored example is **exit 1** even when every score is above threshold
- [ ] a test that **zero examples is exit 2**
- [ ] a test that a threshold of `1.01` is accepted and breached rather than refused
- [ ] a test that a not-applicable evaluator records a null score and not a zero, and that
      the aggregate skips it
- [ ] a test that seeding ignores an unmarked document and never deletes one
- [ ] a test that a second seed over an unchanged corpus uploads nothing
- [ ] a test that the thread purge ignores an unmarked thread and never deletes one
- [ ] a test that the post-run thread invariant refuses (exit 2) on a marked thread the
      run did not create
- [ ] a test that `eval_image_tag` is null when `EVAL_IMAGE_TAG` is unset, and is the
      variable's value when set — the null case is what catches a fallback
- [ ] `evalset/README.md` says `q-charter-quorum` is load-bearing and why
- [ ] **a `.env.example` exists, names `AWS_REGION`, and says that the joined stack's
      credentials live in the control repo's `stack/secrets.env`**
- [ ] **a test that `EVAL_JUDGE=bedrock` with no resolvable region refuses (exit 2)
      with a message naming the variable**, and that it refuses BEFORE constructing a
      client — a refusal that costs a network round trip is a refusal that will be
      mistaken for an outage
- [ ] **a test that `chat_model_id` from the VersionResponse is copied into the metadata
      verbatim**, including the null case. The SEAM cannot assert this: the loop runs
      `CHAT_MODEL=echo`, where the correct value is null, and `smoke.py` stringifies a
      captured null so the assertion becomes unsatisfiable. `BRIEF.md` § "A gap in the
      oracle" names your tests as the oracle for it, so this one is load-bearing rather
      than routine — construct a `VersionResponse` carrying an id and check it survives.
- [ ] `evalset/README.md` explains how to add a document and a question, and what makes a
      good one
- [ ] `docs/architecture.md` is current — the run flow, the four evaluators, the exit codes
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`)

## 10. Smoke — what this slice is actually judged on

The control repo brings every repo up as one stack, **runs your container twice through
`change.yaml`'s `jobs:`**, and then runs `smoke.yaml` against one origin. Read both files —
they are on your `--add-dir`.

**The two jobs are assertions about your exit code**, and they are the two criteria nothing
else can reach:

- [ ] `eval-run-meets-its-thresholds` — one run, `expect_exit: 0`, with the thresholds in
      `stack/dev.env`
- [ ] `a-breached-threshold-exits-non-zero` — the same run with
      `EVAL_THRESHOLD_ROUTING_ACCURACY=1.01`, `expect_exit: 1`

An exit **2** where 0 was expected is reported separately, as your process refusing to judge
rather than as a breach. That distinction is deliberate and it is useful to you: it means a
missing precondition is never diagnosed as a bad score.

The smoke steps whose `owner:` is `chatbot-eval` are yours:

- [ ] `the-question-set-is-a-phoenix-dataset` · `two-runs-produced-one-dataset`
- [ ] `the-run-produced-an-experiment-in-its-own-project`
- [ ] `the-experiment-records-the-build-it-evaluated` — the tag equals the one the backend
      reported, captured from ITS response
- [ ] `the-experiment-records-the-fixture-it-used` — a 64-hex `fixture_hash`
- [ ] `the-experiment-records-what-judged-it`
- [ ] `every-example-ran-without-error-and-has-a-trace`
- [ ] `all-four-evaluators-scored-every-example` — through Phoenix's
      `incomplete-evaluations`, so an empty answer is the pass
- [ ] `the-backend-half-of-the-eval-trace-exists` ·
      `the-backend-span-is-nested-under-the-eval-task` — trace context propagated
- [ ] `the-eval-account-signs-in` · `the-eval-account-holds-the-marked-fixture` ·
      `nothing-unmarked-is-in-the-eval-account` · `logout-the-eval-account`
- [ ] **new** `the-experiment-records-the-exact-model-that-answered` — `chat_model_id`
      equals what the backend reported, captured from ITS response
- [ ] **new** `the-experiment-records-the-eval-images-own-version` — `eval_image_tag`
      equals `${EVAL_IMAGE_TAG}`
- [ ] **new** `every-thread-in-the-eval-account-is-marked` — no thread's title lacks the
      prefix
- [ ] **new** `two-runs-leave-one-runs-threads` — the canary title appears exactly once

These run against your code through a reverse proxy, not against your test doubles, and a
failure comes back to this repo with the request, the response, your container log **and the
tail of your job output** attached. The assertions belong to the control repo: fix the cause,
never the assertion.

## 11. Notes

- `CHAT_MODEL=echo` is the default in the joined stack, so the reply is the question echoed
  back. Routing accuracy and retrieval recall are still real — the router is lexical, the
  embedder is a local ONNX model, and the ingest summariser is deterministic with no model
  configured. Groundedness and correctness are near zero and their thresholds are `0.0` in
  `stack/dev.env` for exactly that reason. Do not "fix" that by softening what those two
  evaluators measure; the thresholds are where the decision belongs.
- Retrieval is capped at `retrieval_top_k: 4` and floored at `retrieval_score_floor: 0.15`
  in the backend, and the contract promises **at most one citation per document** per
  message. So `expected_doc_ids` longer than four can never reach recall 1.0. Keep them
  short, and say so in `evalset/README.md`.
- A first cold run pays for the embedding model and the OpenSearch index. `up --wait` absorbs
  most of it before your job starts, but the first upload is slower than the rest; the job's
  budget is 900s.
- The `.env.example` you ship is read by a person deciding how to run a real judge. Name the
  AWS variables and say that they reach the container through the Docker daemon and never
  through a control-repo process — that is `docs/adr/0006` in the control repo, and it is why
  no credential of yours is ever allowlisted there.

# 0006 — status

## Contract freeze

- SHA: recorded in `change.yaml` as `freeze_sha`, and nowhere else — nothing reads anywhere
  else. `./scripts/manifest.py changes/0006-chatbot-eval --get freeze_sha` prints it.
- Frozen: 2026-09-03
- What moved: `GET /v1/version` and `components.schemas.VersionResponse` in
  `contracts/openapi.yaml`, plus one section in `contracts/README.md`. Additive; no consumer
  is affected.

## A fourth repo

`chatbot-eval` was created and attached in this change, before the freeze. That is not a
slice and it is not implementation — the scaffold is `CLAUDE.md`, `.claude/`, `docs/`,
the vendored `contracts/` and CI, and the toolchain arrives through the dispatch, in a
session started inside that repo. `docs/init/README.md` § 2b is the procedure, written from
what this change actually did.

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| agent-app-project | `feat/0006-chatbot-eval` | opened by `prs.sh` | ☐ | ☐ |
| chatbot-backend | `feat/0006-chatbot-eval` | opened by `prs.sh` | ☐ | ☐ |
| chatbot-eval | `feat/0006-chatbot-eval` | opened by `prs.sh` | ☐ | ☐ |

No frontend or infra PR: neither is a slice. `BRIEF.md` § Out of scope says why.

**Merge order — and it matters more here than usual:**

1. **`chatbot-backend`.** `GET /v1/version` is additive and backward compatible on its own;
   nothing else needs it to exist.
2. **`chatbot-eval`.** Its CI verifies against the vendored contract that already carries
   `/v1/version`, so it can merge before or after the backend deploys — but it cannot RUN
   until the backend serves the endpoint. Merging it second keeps the record honest.
3. **`agent-app-project` (this repo) LAST.** It carries the suite that asserts the other two
   and the `jobs:` that run the eval. Merging it first leaves `main` asserting an endpoint
   that has not landed and running a container that does not exist.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
- **failed** — 20260910T160833Z, 1 attempt(s)
- first dispatch: chatbot-eval (`--only`)
- report: `changes/0006-chatbot-eval/runs/20260910T160833Z/report.md`
<!-- iterate:end -->

## What this change can and cannot reach

`deploy.infra: false`, so the best outcome is **`verified-local`** — a full pass, and not
evidence about any deployment. That is deliberate: `infra/` can deploy nothing, and the
eval's future as a k8s CronJob is named in `BRIEF.md` § Out of scope with that reason rather
than quietly dropped.

## Corrected, 2026-09-10 — /ship-correct

**What was wrong:** nothing new. Asked to check overall correctness rather than to fix a
named defect, and the triage found no missing and no weak criterion — the one outstanding
item was **already asserted and already failing**: `chatbot-eval.md` requires a
`.env.example`, the repo has none, and two dispatches reported exactly that. So this run is
shape three of phase 1's triage, routable as it stood.

**What changed is that the blocker cleared.** The template was unwritable because that repo
denied `Edit(./.env*)` — which globs onto the committed template its own `.gitignore`
un-ignores — and narrowing that rule was refused by a session-level guard above this
harness. A human removed the rule by hand, so the slice can finish. It was removed
*entirely* rather than narrowed, leaving real `.env` files unprotected and
`settings.json` uncommitted, so the slice is now told to restore it in the narrow form in
the same commit as the template.

**Also confirmed working, end to end, in the configured state:** `make eval JUDGE=bedrock`
with a real backend model and a real judge — 18 examples, 0 errored, exit 0, and the two
judge-based evaluators produced real numbers for the first time (groundedness 1.000,
answer_correctness 0.842, against 0.760/0.167 under echo + heuristic). Their thresholds stay
at `0.0`: the loop must run credential-free, so gating them is a separate decision.

**Two things this lane does not touch, both a person's:** `chatbot-backend/.env` still holds
a second copy of the AWS credentials the whole point was to keep in one place, and the two
prose references to `.env.example` in the eval repo are dangling until the slice lands.

## Corrected, 2026-09-09 — /ship-correct

**What was wrong:** `make eval JUDGE=bedrock` failed on a stack whose AWS credentials were
valid. `chatbot-eval/.env` held the three credential names and no region; boto3 refuses
without one and reports it inside a message beginning "could not load credentials", so the
error blamed the credentials. `chatbot-backend/.env` happened to carry `AWS_REGION`, so one
consumer of the same stack worked and the other did not.

**What the criterion turned out to be:** nothing asserted it. "The judge, judging" was
parked in `BRIEF.md` § A gap in the oracle because it needs credentials the loop must not
require — and a criterion in that list is a criterion nobody checks. The correction adds the
assertion that *can* live in the loop: `check-docs.py [provider-credentials]`, which failed
on four counts before the fix. Credentials now live once, in `stack/secrets.env`
(gitignored, `env_file:`-delivered, read by no control-repo process — `docs/adr/0016`),
`make creds` answers "configured, from where?" without printing a value, and `stack/dev.env`
is grouped by service instead of 179 lines of prose.

Not seam-assertable, and recorded as such: no HTTP client can see a credential-plumbing
defect, and the loop must run without credentials. `make eval JUDGE=bedrock` stays a
person's oracle.

## Amended, 2026-09-07 — /ship-iterate

Four questions on the shipped-but-unmerged change. Two were answered by measurement against
the stack the green run left up and needed no change; two were real gaps. Nothing merged, so
this supersedes rather than adds.

**Answered, no change:**

- **Documents are cleaned.** 9 documents, no duplicate filenames, after four runs — the
  hash-compare seed does what it claims.
- **The exact model was already recorded.** `chat_model_id` is in `GET /v1/version` and in
  every experiment's metadata: `eu.anthropic.claude-haiku-4-5-20251001-v1:0`. It was not
  *asserted*, and the run's printed summary named only the judge's model — both now fixed,
  but the field itself did not need adding.

**The two gaps:**

- **Threads accumulated forever.** 36 in the eval account over two runs, against a contract
  cap of 200 on `GET /v1/threads`. The eval now titles each thread with
  `${EVAL_THREAD_PREFIX}` at creation and purges its own marked threads at the START of every
  run — start, not end, so the last run's transcripts survive for a person to read.
  Criteria 21 and 22.
- **No image carried a version.** `BACKEND_IMAGE_TAG` was `dev` — the same string for every
  build, in the one field meant to distinguish builds — and the eval image had no tag at all
  in its metadata. Both are now `local-<major>.<minor>.<patch>` in `stack/dev.env`, the eval
  records its own as a comparability factor beside `fixture_hash`, and
  `check-docs.py [image-tags]` refuses a change that touches a product repo without bumping
  its tag. `docs/adr/0015` is the decision, including why the git SHA is not the answer.
  Criteria 23, 24 and 25.

**No re-freeze; `c0ff827` stands.** `CreateThreadRequest.title`,
`DELETE /v1/threads/{thread_id}` and `chat_model_id` are all already promised, so no
interface moved. Reasserted because "we changed our minds, therefore re-freeze" is the
reflex, and a second freeze over an identical tree would make the record say otherwise.

**Where the bump rule lives, and why not a product repo's `CLAUDE.md`.** The tag belongs to
the joined stack: a session inside `chatbot-backend` cannot edit `stack/dev.env`, so a rule
telling it to bump would be unactionable — the same contradiction `docs/adr/0008` dissolved
for `contracts/`. So the rule is a gate here plus one paragraph in `/ship` phase 1, and the
control repo's `CLAUDE.md` is deliberately untouched: it sits at exactly its 60-line budget
and the last retrospective said the next addition should shorten rather than squeeze.

The `chatbot-backend` slice requires **no change** in this amendment. Its brief says so at
the top and tells the session to verify and report rather than look for work.

## Corrected during the run, 2026-09-03

Three defects, all in THIS repo's half. Recorded because a diff of `smoke.yaml` shows a
step arriving and never why.

1. **`the-run-produced-an-experiment-in-its-own-project` passed for the wrong reason.**
   Phoenix names an experiment's project itself, as `Experiment-<hash>`, so the regex was
   matching the `project_name` the eval copies into its own metadata rather than the
   experiment's project. Measured against a live run, then split: an experiment exists and
   ran over examples, and separately a project named `${EVAL_PHOENIX_PROJECT_NAME}` holds
   spans the eval exported. Strengthened from a vacuous pass, not softened.
2. **Criterion 19 can race**, so criterion 20 was added beside it. Which project holds a
   trace shared by two exporters is decided by whichever span created the trace row first.
   20 compares two fields of one response — the trace id Phoenix assigned the run against
   the `X-Trace-Id` the backend returned — so no export race can touch it. 19 is kept as
   written and passed on a clean run.
3. **`chatbot-eval.md` never stated the exit-code precedence.** A backend erroring every
   turn is both "anything errored" (1) and "the threshold compared against nothing" (2),
   and the wrong reading routes the failure to the wrong repo. Now stated: zero examples,
   then errors, then thresholds.

And one in the harness, which is `docs/adr/0014`'s mechanism failing on its first outing:
**the jobs stage ran one of two jobs and reported a pass.** `docker compose run -T`
attaches stdin and the loop read its job list from a process substitution, so the first
job's container consumed the second job's line. Criterion 7 was not asserted and the run
still reported `verified-local`. Fixed in `74dbfe3`, and the stage now counts — `JOBS_RAN`
must equal what `change.yaml` declares, as `fault: harness`.

## What the eval actually measured

The green run, for the record — these are mechanism numbers, not quality ones
(`BRIEF.md` § "What we are NOT building"):

| evaluator | mean | threshold | scored | n/a |
| --- | --- | --- | --- | --- |
| `routing_accuracy` | 0.944 | 0.800 | 18 | 0 |
| `retrieval_recall` | 0.950 | 0.600 | 10 | 8 |
| `groundedness` | 0.760 | 0.000 | 13 | 5 |
| `answer_correctness` | 0.167 | 0.000 | 18 | 0 |

18 examples, 0 errored. `answer_correctness` is low because `CHAT_MODEL=echo` returns the
question, which is exactly why its threshold is `0.0` and exactly what
`BRIEF.md` says. The two code-based numbers are real.

**The run was started with `CHAT_MODEL=echo` in the environment, by hand.** Without it the
stack resolves `bedrock` from `chatbot-backend/.env`, whose credentials are expired: the
first attempt produced 44 `ExpiredTokenException`s, every example errored, and the failure
was charged to `chatbot-eval` — which cannot fix a credential in another repo's gitignored
file. Fifth occurrence of the retrospectives' standing R1.

## Blockers

**One, and it needs a human — a two-line edit no dispatched session can make.**

`chatbot-eval/.env.example` is unshipped. That repo's `.claude/settings.json` denies
`Edit(./.env*)`, which globs onto the template its own `.gitignore` un-ignores with
`!.env.example`; and editing `settings.json` to narrow the rule is refused by a
session-level guard on permission settings, which is above this harness. Two dispatches
reported the same thing, precisely, rather than working around either rule. A third would
buy a third identical report.

In `chatbot-eval/.claude/settings.json`, replace `"Edit(./.env*)"` with:

```json
      "Edit(./.env)",
      "Edit(./.env.local)"
```

Then `.env.example` can be written. It is a convenience, not the fix — `make eval
JUDGE=bedrock` works today via `stack/secrets.env` — but `README.md` and
`docs/architecture.md` in that repo already point at it, so it is a live dangling
reference until it exists.

The rule came from the scaffold this change wrote for that repo, copied from
`chatbot-backend`, whose template was already committed before the rule could bite. The
retrospective of 2026-09-09 found the same trap in **three** repos: `chatbot-eval`,
`chatbot-backend` and `frontend` all carry the pair. `chatbot-backend` escaped by
accident; `frontend`'s is waiting for the first change that needs a template there.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock` — it now pins four submodules
- [ ] `/realign`, which will want to promote the durable steps of this suite into
      `smoke/baseline.yaml`. Two cautions for whoever runs it:
      **(a)** every capture in `smoke.yaml` is `eval_`-prefixed to avoid colliding with the
      baseline's own `thread_id`/`document_id`/`chat_trace`; keep the prefixes on the way in.
      **(b)** `the-backend-span-is-nested-under-the-eval-task` asserts a NON-null parent,
      which is the opposite of 0005's `the-chat-trace-is-rooted-at-the-http-request`. Both
      are correct and they are about different traces. A reader who finds them side by side
      in the promoted baseline should not "fix" either.

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
- **verified-local** — 20260903T155755Z, 1 attempt(s)
- report: `changes/0006-chatbot-eval/runs/20260903T155755Z/report.md`
<!-- iterate:end -->

## What this change can and cannot reach

`deploy.infra: false`, so the best outcome is **`verified-local`** — a full pass, and not
evidence about any deployment. That is deliberate: `infra/` can deploy nothing, and the
eval's future as a k8s CronJob is named in `BRIEF.md` § Out of scope with that reason rather
than quietly dropped.

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

- None known at dispatch.

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

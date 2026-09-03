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
_Never run._
<!-- iterate:end -->

## What this change can and cannot reach

`deploy.infra: false`, so the best outcome is **`verified-local`** — a full pass, and not
evidence about any deployment. That is deliberate: `infra/` can deploy nothing, and the
eval's future as a k8s CronJob is named in `BRIEF.md` § Out of scope with that reason rather
than quietly dropped.

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

# 0004 — status


## Contract freeze

- SHA: `44e38bc6c2f773e081c7131c4b8adaf1964bde9c`
- Frozen: 2026-08-26

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0004-rag-knowledge-base` | https://github.com/Paggio/chatbot-backend/pull/7 | ☐ | ☐ |
| frontend | `feat/0004-rag-knowledge-base` | https://github.com/Paggio/frontend/pull/6 | ☐ | ☐ |

Merge order: **chatbot-backend first, then frontend.** The backend's change is additive on
its own — five new paths and two optional fields on an existing schema, with every existing
response unchanged — so it is safe in front of a frontend that knows nothing about it. The
frontend's is not safe in front of the backend: `/knowledge` would render against endpoints
that answer 404, and the transcript would look for citation fields nothing sends.

## Deploy verification

<!-- Maintained by ./scripts/iterate.sh — edits between the markers are overwritten.
     A green CI column means each repo is internally consistent; this line is the only
     thing that says they work together. -->

<!-- iterate:begin -->
- **verified** — 20260826T161953Z, 1 attempt(s)
- report: `changes/0004-rag-knowledge-base/runs/20260826T161953Z/report.md`
<!-- iterate:end -->

## What the green run does and does not say

`report.md` says `verified`. Read it as **verified-local**, which is what actually happened
and what `/ship`'s own outcome table defines: 61 assertions held through the single origin a
browser uses, `deploy.infra` is false, `remote_asserted` is false in `verify.json`, and no
remote environment was touched because there is none to touch. Nothing here is evidence that
the knowledge base works anywhere but on a laptop.

The run that produced it was `--verify-only`, so the dispatch was skipped and what was
asserted is the code already committed on the two branches. That is the right oracle — the
suite ran against the joined stack through the proxy — but it is worth knowing that no agent
session ran in the run that went green.

## Blockers

- None. Two notes rather than blockers: the outcome above is local-only, and the backend's
  first dispatch was killed at the harness's 3600s timeout AFTER it had committed its work,
  which is why attempt 1 of run `20260826T151424Z` reads `crashed` with a zero-byte log.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`
- [ ] The cloud knowledge base is unbuilt. `infra/` needs an OpenSearch domain, a bucket,
      and the IAM to reach both from the task role before any of this exists outside a
      laptop. Until then a deployed environment runs a backend whose knowledge-base
      endpoints cannot work — the follow-on change, not a blocker on this one.

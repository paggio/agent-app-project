# 0004 — status


## Contract freeze

- SHA: `44e38bc6c2f773e081c7131c4b8adaf1964bde9c`
- Frozen: 2026-08-26

## Pull requests

| Repo | Branch | PR | CI | Merged |
| --- | --- | --- | --- | --- |
| chatbot-backend | `feat/0004-rag-knowledge-base` | _opened in phase 5_ | ☐ | ☐ |
| frontend | `feat/0004-rag-knowledge-base` | _opened in phase 5_ | ☐ | ☐ |

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
_Never run._
<!-- iterate:end -->

## Blockers

- None yet.

## After merge

- [ ] `./scripts/lock.sh` and commit `repos.lock`
- [ ] The cloud knowledge base is unbuilt. `infra/` needs an OpenSearch domain, a bucket,
      and the IAM to reach both from the task role before any of this exists outside a
      laptop. Until then a deployed environment runs a backend whose knowledge-base
      endpoints cannot work — the follow-on change, not a blocker on this one.

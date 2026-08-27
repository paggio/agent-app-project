# 0004 — status


## Contract freeze

- SHA: `be87279ccdd39781a02fc3f917f235d487425df2`
- Frozen: 2026-08-27
- Supersedes `44e38bc…` (2026-08-26), which never merged.

## Amended, 2026-08-27 — `/ship-iterate`

The first version shipped text and markdown only, a 2000-byte cap in the joined stack, and a
citation per retrieved chunk. Looking at it produced four changes:

| Was | Is | Why |
| --- | --- | --- |
| text and markdown, JSON only | PDF too, over a second `multipart/form-data` intake | it is what people actually have. Base64 in JSON was rejected: at 10 MB it is a third larger and decoded in memory before it can be refused |
| `DOCUMENT_MAX_BYTES` 2000 in the stack | 10 MB everywhere | 2000 was an artefact of wanting a readable oversize fixture, and it was what the UI told people |
| a citation per matching chunk | at most one per document | two chunks of one file rendered as `[1] README.MD` / `[2] README.MD` — `evidence/duplicate-citations.png` |
| raw `<input type="file">`, no way to read a document | a real button, and content readable in the page | `evidence/choose-file-control.png` |

**What it cost, stated because a diff will not show it.** The oversize smoke step is gone —
10 MB is not expressible in a suite meant to be read as criteria — so criterion 12's size
half is now only a backend test. And PDF upload is asserted nowhere at the seam, because
`smoke.py` cannot send a file; Playwright is its only oracle. Both are in BRIEF.md
§ "A gap in the oracle".

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
- **verified** — 20260827T144501Z, 1 attempt(s)
- report: `changes/0004-rag-knowledge-base/runs/20260827T144501Z/report.md`
<!-- iterate:end -->

## What the green run does and does not say

`report.md` says `verified`, in both runs. Read it as **verified-local**, which is what happened
and what `/ship`'s own outcome table defines: 61 assertions held through the single origin a
browser uses, `deploy.infra` is false, `remote_asserted` is false in `verify.json`, and no
remote environment was touched because there is none to touch. Nothing here is evidence that
the knowledge base works anywhere but on a laptop.

The 2026-08-26 run that first went green was `--verify-only`, so no agent session ran in it.
The 2026-08-27 amendment run was a full dispatch and both slices reported OK on the first
attempt — the branches already existed, so each session continued its own work rather than
rebuilding from scratch.

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

# 0020 — The repo set is data, and a new repo is born inside `/ship`

**Status:** accepted
**Date:** 2026-11-14
**Relation:** supersedes the hand-kept-lists cost in `0013`; keeps `0005`'s lane count.

## Context

The next change adds an MCP server the agent calls — a new service, so a new repo.
Attaching `chatbot-eval` (`0013`) meant a hand procedure and editing ten repo lists, where
only the hook probe would notice a miss. By now the set was written down in ~20 places:
scripts, the Makefile, the write guard, the workflows' deploy keys and build steps,
`/realign`'s loops, and the GitHub owner in ten more.

## Decision

1. **`.gitmodules` is the one list.** Every script, the Makefile, the write guard and the
   workflows read it through `scripts/repos.py` (stdlib only — CI reads it before `uv`
   exists, the hook must stay dependency-free). Per-repo data git ignores lives there too:
   `images = <image>[:<dockerfile>] ...`. The owner is derived from the submodule urls.
   Not a separate `repos.yaml`: that would be a second list to drift from the real one.
2. **What cannot be derived is gated.** The Edit deny rules (static JSON) are checked by
   `test-hooks.py`; the README repo table and any hand list creeping back by
   `check-docs.py [repo-set]`. Service lists (`stack.sh`, `failure-brief.py`) stay hand-kept
   — primary vs supporting is a judgement — and `[stack-services]` already names a miss.
3. **No new lane.** A repo is created in `/ship` phase 1b, and only when the request
   explicitly asks; a plan that concludes one is needed stops and asks. The change records
   it (`new_repos:`), `scripts/new-repo.sh` creates, scaffolds from `templates/product-repo/`
   and attaches it, and `manifest.py --validate` refuses dispatch until it has. After the
   attach commit it is an ordinary submodule, so `/ship-correct`, `/ship-iterate` and
   `/realign` need nothing new. The attach commit is data, so it belongs to the change, not
   to a harness PR.
4. **A new kind of interface needs no script change.** Any `contracts/<kind>/*.json` with
   `x-consumers` is vendored like the event schemas.
5. **Grouping on GitHub is a topic, not an organisation.** `gh-setup.sh` tags every repo
   `agent-app-project`. An org was the stronger option (real grouping, org secrets instead
   of copying each deploy key everywhere) and was declined for now; the owner now lives in
   one place, so moving is a url edit in `.gitmodules` plus the product repos' callers.

## Consequences

**Makes easy.** A new repo is one command inside the change that needs it, and every gate
covers it from the attach commit. The MCP server's tool schemas have a home.

**Accepted costs.**

- `dev-push.yml` hands the deploy-key step `toJSON(secrets)` to find keys by name: one
  step sees every repository secret, masked in logs. Narrower would mean a hand list again.
- `/dev-push-<repo>` accepts any name at parse time; `deploy-set.py --only` refuses an
  unknown one a step later, after the job has started.
- Every attach regenerates every deploy key (`gh-setup.sh`).
- The scaffold's `make check` refuses until a toolchain lands, so a new repo's `main` CI is
  red until its first slice merges. Honest, and noisy.
- The template is a copy of conventions the existing repos have drifted from; it is
  maintained here, and a retro that finds a scaffold defect fixes it here.

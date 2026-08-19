---
name: align-contract
description: Promoting something already built into a frozen contract, or checking whether contracts/ still matches what the services actually serve. Use after building an endpoint in a product repo, before a consumer depends on it, or when contracts/ and reality may have drifted.
---

`freeze-contract` is for deciding an interface before it exists. This is the other
direction: something has been built, it works, and now it needs to become a promise.

Both end in the same place — a reviewed contract, committed alone. The difference is
only where the first draft comes from.

## When this is the right skill

Use it when the shape already exists somewhere real:

- an endpoint was built in a product repo and a second repo now needs to call it
- `contracts/` is suspected of having drifted from what is served
- a change is about to fan out and you want to know the contract is still true

Do NOT use it to design an interface that does not exist yet. A draft taken from an
implementation is a description of decisions already made; if nothing is built, there
are no decisions yet, and `freeze-contract` is the skill.

## The rule this skill exists to protect

**The harvest drafts. You decide.**

A contract auto-accepted from an implementation is no longer a promise — it is a
description of whatever the backend happens to do, accidents included, and it can never
fail a build again. That is the entire value described in `docs/adr/0001`. The tool is
therefore built so it cannot bless a breaking change on its own: `--write` refuses until
you pass `--accept-breaking`, which means you looked and decided.

## Order of work

1. Bring the stack up: `make up`. The draft is taken from a running service, not from
   reading source — FastAPI publishes an exact spec at `/openapi.json`, and an exact
   source beats an inferred one.

2. See what differs:

   ```
   ./scripts/harvest-contract.py --diff
   ```

   Findings are classified by what they would do to a consumer, and direction decides:
   a required field added to a *request* breaks callers; the same field added to a
   *response* is harmless. A field removed from a *response* breaks consumers; removed
   from a *request* it does not.

3. **If anything is BREAKING, stop and decide before writing.** The default answer is
   expand-and-contract, because the three repos deploy independently and production will
   run mismatched versions: add the new shape alongside the old, migrate every consumer,
   remove the old in a later change. Only reach for `--accept-breaking` when you have
   established that nothing consumes the old shape yet.

4. Draft it in:

   ```
   ./scripts/harvest-contract.py --write
   ```

5. **Review the draft — this is the step that matters.** Generated specs carry the
   implementation's vocabulary, and a contract is read by consumers who do not have the
   implementation in front of them. Every time, check:

   - `operationId` — generators turn these into client method names. FastAPI emits
     `chat_v1_chat_post`; write `postChat`.
   - `summary` / `description` — the generated ones describe internals ("Run one turn
     through the agent graph"), and often FastAPI's placeholder "Successful Response".
     Rewrite for someone calling the endpoint, and say what is deliberately NOT promised.
   - **Surface that should not be public.** Everything served gets harvested. An
     endpoint being reachable is not a decision to promise it forever; delete what should
     not be in the contract, and say so in the PR.
   - Error responses — the generated 422 is real, but whether a consumer may rely on its
     shape is a decision.

   Your wording survives the next harvest: re-running `--write` keeps `summary`,
   `description`, `operationId` and `tags` from the contract and takes only structure
   from the implementation. So review once, not every time.

6. Sanity-check against reality, then commit:

   ```
   make smoke                        # assertions now checked against the contract too
   git commit contracts/ -m "..."    # ALONE — no other files in the diff
   ```

   The commit that lands the contract change IS the freeze. Record its SHA as
   `freeze_sha` in the `change.yaml` of any change that depends on it.

## Notes

- `contracts/openapi.yaml` is rewritten by `--write`, so YAML comments inside it do not
  survive. Durable guidance belongs in `contracts/README.md`.
- Steps in a smoke suite that are not API surface — the app shell, a static asset — set
  `contract: false`. The contract promises the API and says nothing about those.
- The harvest reads one service. `--from` accepts another URL or a saved
  `.json`/`.yaml`, which is also how you diff a spec you have not deployed.

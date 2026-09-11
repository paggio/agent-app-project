# 0006 — chatbot-backend slice

## AMENDED, 2026-09-07 — read this first, then stop

**This amendment requires NO CHANGE in this repo. Nothing is added and nothing is removed.**

Your branch already carries `GET /v1/version` and its pull request is open. Every criterion
it passed still has to pass. Your six existing smoke steps are unchanged, and one is
added — `the-backend-image-tag-is-a-version` — which your code already satisfies.

What changed is a **value in the control repo**, not your code: `stack/dev.env` now sets
`BACKEND_IMAGE_TAG=local-0.0.1` instead of `dev`, and one new step asserts that `image_tag`
matches `local-<major>.<minor>.<patch>`. You already report `IMAGE_TAG` verbatim from the
environment with no fallback, which is exactly right and is what makes the new step pass
without you touching anything. `docs/adr/0015` is the decision.

**So: verify and report. Do not look for work.** Confirm your gates still pass, confirm
`make contract` is still green, and report `ok`. If you believe a change here IS required —
if some fallback or default would make the new assertion fail — say what and why in your
summary and report `failed` rather than guessing; a change to this repo in this amendment
would be a change nobody asked for.

One thing NOT to do, because it is the tempting reading: do not start deriving `image_tag`
or `git_sha` from your own version, your git tree or anything else. Null when nothing
supplied one remains correct and the contract says so.


One endpoint. That is the whole slice, and the smallness is the point: the eval is a
separate repo precisely so that measuring the backend does not mean changing it.

## What to build

### `GET /v1/version` — what build is this, and what is it running

A new route in `src/app/api/routes.py`, tagged `ops`, `operation_id="getVersion"`, and
**session-required** — take `CurrentAccount` exactly as `POST /v1/chat` does. It is the only
new surface in this change.

Why authenticated, since it is an `ops` endpoint: which build and which model an environment
runs is deployment information, and `/healthz` already answers liveness for an anonymous
caller. The one consumer signs in anyway. `smoke.yaml`'s first step asserts the 401.

Why it exists at all: the eval must record what it evaluated by **reading** it, never by
being passed it. A run told its own image tag by a flag records whatever the caller believed;
a run that reads it records what is serving. `docs/adr/0013` is the decision.

Response — a flat object, all of it selectors and identifiers:

| Field | Type | Source | Meaning |
| --- | --- | --- | --- |
| `version` | string | the app version in `pyproject.toml` | the release, not the build |
| `image_tag` | string \| null | the `IMAGE_TAG` environment variable | the container image tag. **No default and no fallback** — null when unset. An application that invents its own build identity is not reporting one, so do not derive it from the version, the git tree or the hostname. |
| `git_sha` | string \| null | the `GIT_SHA` environment variable | the commit the image was built from, or null |
| `chat_model` | string | `settings.chat_model` | `echo` or `bedrock` — the effective selector |
| `chat_model_id` | string \| null | `settings.bedrock_model_id` when `chat_model` is `bedrock`, else **null** | the provider model id. Null under `echo`, because there is no model |
| `embedding_model` | string | `settings.embedding_model` | `local` or `bedrock` |
| `retrieval_router` | string | `settings.retrieval_router` | `heuristic` or `llm` |

Two new settings in `core/config.py`: `image_tag: str | None = None` and
`git_sha: str | None = None`. Both default to None. The joined stack passes `IMAGE_TAG`; a
deploy passes both.

**Nothing else goes in this response, and this is the part to hold the line on.** Not
`retrieval_top_k`, not `retrieval_score_floor`, not the fusion weights, not the chunk size —
even though every one of them changes what a recall number means, which is exactly the
argument that will be made for adding them. Promising them makes them contract, and they are
internals that should move freely. If the eval turns out to need one, that is a contract
change in the control repo, not a field added here. `retrieval_router` is in because it is a
behavioural mode rather than a tuning value.

**No credential, ever.** `smoke.yaml` asserts the response body contains no field whose
*name* matches `secret|password|credential|signup_code|aws_access|session_token`. It is
written against names rather than values on purpose, so it fails the day a field is added
rather than once it holds a real key. `settings.signup_code` and the two S3 keys are
`SecretStr`; do not unwrap them here, and do not add a "config" sub-object that serialises
the settings object wholesale — that is the one implementation that would pass every other
criterion and fail this one.

Response model in `api/schemas.py` as `VersionResponse`, matching the frozen contract's
schema of the same name field for field.

## Contract entries this depends on

- `contracts/openapi.yaml` → `GET /v1/version`, `operationId: getVersion`, `cookieAuth`,
  200 `VersionResponse` / 401 `ErrorResponse`
- `contracts/openapi.yaml` → `components.schemas.VersionResponse`
- `contracts/README.md` → § "What `GET /v1/version` promises"

The contracts are FROZEN. If this slice appears to require a contract change, STOP and report
it rather than working around it.

Note that `verify.sh` runs `harvest-contract.py --diff` against your served
`/openapi.json` **before** the smoke suite, and a drift there fails the run and is routed to
this repo. So the served spec has to match the frozen one: the explicit `operation_id`, the
declared 401, and the response schema's field names and nullability all have to line up.

## Out of scope for this slice

- Anything in `src/app/graph/`, `src/app/knowledge/` or `src/app/threads/`. The eval measures
  what is already there. If this slice appears to need a change in any of them, the design is
  wrong — say so rather than making the diff.
- A readiness endpoint, or any change to `/healthz`. `/healthz` is frozen as process
  liveness and compose depends on it.
- Anything about the eval. It is a separate repo and it never imports backend code.

## Verification

- [ ] a test that the endpoint answers 401 with no session, before any settings are read
- [ ] a test that `image_tag` and `git_sha` are null when their variables are unset, and are
      the variables' values when set — the null case is the one that catches a fallback
      somebody added for convenience
- [ ] a test that `chat_model_id` is null under `CHAT_MODEL=echo`
- [ ] **a test that no field name in the response matches the credential pattern above**,
      written over the response keys rather than as a hand-listed allowlist, so a field added
      later is covered
- [ ] `make contract` passes — the implementation matches the vendored spec
- [ ] `docs/architecture.md` records the endpoint and why it is authenticated
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`)

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys all of them together and runs `smoke.yaml`
against one origin. The steps whose `owner:` is `chatbot-backend` are yours:

- [ ] `version-requires-a-session` — 401 `AUTH_REQUIRED` with no session
- [ ] `register-a-version-reader` — a session, so the steps below have one
- [ ] `version-reports-the-build-and-the-models` — 200, and `image_tag` equals the value the
      stack passed in as `IMAGE_TAG`
- [ ] `version-names-the-effective-chat-model` — `chat_model` is `echo` or `bedrock`
- [ ] `version-names-the-retrieval-configuration` — `embedding_model` and `retrieval_router`
      are both present and both from their declared sets
- [ ] `version-leaks-no-credential` — no credential-shaped field name in the body
- [ ] **new, 2026-09-07** `the-backend-image-tag-is-a-version` — `image_tag` matches
      `local-<major>.<minor>.<patch>`. It passes because you report `IMAGE_TAG` verbatim;
      the value comes from `stack/dev.env`, which is the control repo's to set

These run against your code through a reverse proxy, not against your test doubles, and a
failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- `version-reports-the-build-and-the-models` asserts `image_tag` against a value supplied
  from outside your image. If your implementation defaults it to `"dev"`, or to the app
  version, the step passes locally and lies in every deployed environment. Null is the
  correct answer to "no tag was supplied".
- The eval reads this endpoint and copies three of its fields into every Phoenix
  experiment's metadata. A field that is wrong here is wrong in a permanent record of what
  was measured, which is a worse failure than a wrong response — it is a wrong archive.

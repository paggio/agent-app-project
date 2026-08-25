# 0006 — A submodule's own `.env` is the joined stack's bottom layer of configuration

**Status:** accepted
**Date:** 2026-08-21
**Relation to 0002:** extends it. 0002 made this repo the owner of the joined stack; this
says what the joined stack is allowed to read, and in what order.

## Context

`chatbot-backend` keeps a gitignored `.env` holding live AWS credentials plus
`CHAT_MODEL`. Its own compose file passes that file in with `required: false`, so the repo
runs against a real Bedrock model locally and against `echo` in CI, with no branch on
`APP_ENV`. That decision is theirs and it is sound (`chatbot-backend/docs/adr/0004`).

What was never decided is what happens to that file when *this* repo joins the two compose
projects into one stack. The behaviour turned out to be right by accident and undocumented,
which is the worst combination: nobody could rely on it and nobody would notice it break.

Measured, and isolated in a two-file reproduction rather than inferred from the manual:
Compose resolves `${VAR}` inside an `include:`d file against **that file's** directory
`.env`, and the process environment still outranks it. So the effective order for
everything the backend's compose file interpolates was already:

| Precedence | Source |
| --- | --- |
| 1 (wins) | the real process environment |
| 2 | `chatbot-backend/.env` |
| 3 | the literal default in `chatbot-backend/docker-compose.yml` |

That is exactly the order we want. Three things were wrong with it anyway:

1. **It rests on `include:` interpolation scope**, which is a Compose implementation
   detail. A release that scoped interpolation to the top-level project instead would
   silently move the joined stack from Bedrock to `echo`, and the only symptom would be
   replies that look plausible.
2. **`scripts/dev-env.sh` did not know the file existed.** Everything that runs in this
   repo's own shell — `smoke.py`'s `${VAR}` interpolation, `verify.sh`'s decisions — saw
   `stack/dev.env` and nothing else. The container and the harness could disagree about
   the configuration of the thing being tested.
3. **A name declared in both files inverts the order.** `dev-env.sh` exports the
   `stack/dev.env` value into the process environment, which then outranks
   `chatbot-backend/.env` by rule 1 above. No name overlaps today;
   `chatbot-backend/.env.example` §2 lists five that plausibly could.

## Decision

**The precedence above is the decided contract of the joined stack, not a side effect of
Compose.** Written down here, implemented in `scripts/dev-env.sh`, and checked by
`scripts/check-docs.py`:

- `dev-env.sh` fills unset variables from `stack/dev.env` first, then from
  `chatbot-backend/.env`. The real environment still wins over both, unchanged.
- **From an allowlist of non-secret names only.** A credential must never enter a
  control-repo process, because this repo writes run artifacts — `verify.json`,
  `smoke.json`, container logs, repair prompts — and a value in the environment of the
  process that writes them is one careless dump away from being committed. The allowlist
  is in `dev-env.sh` beside the code that uses it.
- Credentials keep reaching the container the way they already did: over compose's
  `env_file`, read by the Docker daemon, never by a script here. That path is unchanged by
  this ADR and deliberately so.
- The names filled in from a submodule are recorded in `SUBMODULE_ENV_DEFAULTED`, separate
  from `DEV_ENV_DEFAULTED`. They mean different things: `DEV_ENV_DEFAULTED` means "this is
  a committed local placeholder", which is why `verify.sh` refuses a remote pass on the
  strength of it. A value from a gitignored `.env` is a real local value and must not
  trigger that refusal.
- `check-docs.py` fails when a name is declared in both `stack/dev.env` and
  `chatbot-backend/.env`, and when `dev-env.sh` stops reading the submodule file at all.
  The overlap is the failure mode nobody would find by reading.

## Consequences

**Easier.** The joined stack picks up whatever the backend developer already configured,
with no second copy of it here and no hand-exported variable — the pattern `stack/dev.env`
exists to eliminate. `CHAT_MODEL=echo make up` still overrides, so a cheap credential-free
run is one word. The harness and the container now agree on configuration by construction.

**Harder, and accepted:**

- **The allowlist is a maintenance surface.** A new non-secret variable in the backend's
  `.env` does not flow until someone adds the name here. That is the fail-closed
  direction and it is the point: the alternative, a denylist of secret-looking names,
  fails open the first time a secret is named something unexpected.
- **This repo now reads a file in a submodule.** A small violation of the rule that each
  product repo is self-describing. Narrowed by only ever reading it, never writing it, and
  by tolerating its absence — a fresh clone, or CI, has no `.env` and must still come up.
- **Configuration for the joined stack can now come from a gitignored file**, so two
  developers can get different behaviour from the same commit. That was already true via
  compose; this makes it legible instead of surprising, which is the trade we are making
  rather than a cost we are avoiding.
- **`.env` parsing here is deliberately dumb** — `KEY=VALUE`, `#` comments, an optional
  `export ` prefix, no quote stripping, no interpolation. It is not a shell and must not
  become one; the file it reads is not ours to define a grammar for.

## Alternatives considered

- **Leave it to Compose.** Rejected: it already worked, and that was the problem. An
  undocumented behaviour nothing asserts is a behaviour that regresses without a failure.
- **Copy the values into `stack/dev.env`.** Rejected outright: that file is committed, and
  the values in question are live credentials.
- **Load the whole `.env`, secrets included, and rely on care.** Rejected. The control
  repo's whole job is writing evidence files about failures; putting credentials in the
  environment of the process that does that is asking for the one bad artifact.
- **Read `.env` for every submodule, not just `chatbot-backend`.** Rejected as premature.
  `frontend` and `infra` have no such file today, and a generic loop over three
  hypothetical files is harder to reason about than one named path. When the second one
  exists, generalise then.
- **Have the backend's compose file stop setting the keys its `.env` also sets**, so
  `env_file` wins outright. Rejected: it is the wrong repo. Their compose file must keep
  working standalone with no `.env` at all, and this repo does not get to edit it.

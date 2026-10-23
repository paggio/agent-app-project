# 0017 — The credentials file carries the mode those credentials are for

**Status:** accepted
**Date:** 2026-09-14
**Relation to 0016:** completes it. 0016 put the credentials in one file and proved they
reach the containers. It did not notice that arriving is not the same as being used.

## Context

`stack/secrets.env` was populated with valid AWS credentials, the per-repo `.env` files were
deleted as 0016 intended, `make up` ran — and the backend served `CHAT_MODEL=echo`. The
reasonable reading, and the one offered, was that the credentials had not been found.

They had. Two separate things were true and neither was visible:

1. **The backend never sniffs for credentials.** Which model it builds is an explicit
   selector — `chatbot-backend`'s `docs/adr/0001` makes the chat model a constructor
   argument and `docs/adr/0004` makes `CHAT_MODEL` choose the provider. There is no
   fallback path from "credentials present" to "use them", by design, because a model that
   silently starts costing money when a file appears is worse than one that has to be
   asked. `CHAT_MODEL=bedrock` had been arriving from `chatbot-backend/.env` all along, and
   deleting that file removed the *selector* along with the credentials it also held.

2. **Putting `CHAT_MODEL` in `stack/secrets.env` does nothing**, and does it silently.
   Measured in an isolated reproduction rather than inferred: **`environment:` beats
   `env_file:`**, and `chatbot-backend/docker-compose.yml` declares
   `CHAT_MODEL: ${CHAT_MODEL:-echo}` under `environment:`. So the same file delivers
   `AWS_REGION` — which no compose file declares — and drops `CHAT_MODEL` on the floor. A
   credentials file that carries some of its names and not others, with no error either
   way, is a worse trap than one that carries none.

0016's own § Decision 2 says compose's `env_file` is the file's only reader, and that is
what made the second problem unfixable without revisiting it.

## Decision

**`stack/secrets.env` carries the mode selectors as well as the credentials, and
`scripts/dev-env.sh` reads exactly those through an allowlist.**

1. **`SECRETS_ENV_ALLOW="CHAT_MODEL EVAL_JUDGE"`** — the same mechanism `docs/adr/0006`
   established for `chatbot-backend/.env`, applied to the file that replaced it. A name not
   on that list never reaches a process in this repo. `AWS_*` is absent and must stay
   absent.

2. **The safety property is unchanged and is now stated precisely.** It was ever only this:
   *a credential must never enter a control-repo process*, because this repo writes
   `verify.json`, `smoke.json`, container logs and repair prompts. 0016 enforced it as
   "`dev-env.sh` must not name `secrets.env`", which is a blunt proxy — it forbids the
   working fix along with the dangerous one. The gate now checks the allowlist is
   credential-free, which is the property itself. The credentials still reach the
   containers over `env_file`, read by the Docker daemon and by nothing here.

3. **The mode has to travel through the process environment**, not `env_file`, because of
   the precedence measured above: compose interpolates `${CHAT_MODEL}` from the process
   environment, and that is the only way to reach an `environment:` entry a submodule
   declares. This is the whole technical reason the allowlist exists rather than the file
   simply being handed to more services.

4. **It is loud, and that is a condition of the decision rather than a nicety.**
   `make creds` prints what `CHAT_MODEL` and `EVAL_JUDGE` resolve to *and from which
   layer*, and says so explicitly when credentials are configured while the model is still
   `echo` — the exact state that prompted this. `verify.json` records both under
   `configuration`, so a run that reached for a provider says so afterwards.

## Consequences

**Makes easy.** One file to fill in, and `make up` runs what it says. "Is this stack
configured, and for what?" has one answer from one command, with provenance, and no value
printed.

**Accepted costs.**

- **A developer with credentials now gets `bedrock` in `make verify` and in the loop**,
  which costs money and makes a run non-deterministic. This is the cost that has already
  been paid four times in a worse form: an expired token, charged to a product repo,
  burning a repair dispatch that could not possibly succeed. It is accepted here only
  because §4 makes it visible — the previous occurrences were silent, and `verify.json`
  recording the configuration is what turns "why did that fail" into a one-line answer. If
  it bites again *with* the reporting in place, the answer is a `fault: environment` class
  in `docs/adr/0003`, which two retrospectives have now asked for.
  It bit again in 0008, routed to `chatbot-eval`; `verify.sh` now sets `fault: environment`
  when a container log shows the provider rejecting the credentials, and no repair is dispatched.
- **A fourth layer in `dev-env.sh`.** Three was already the number 0006 said to justify
  before generalising. The justification is that this layer reads a file that did not exist
  then and is the one place a person is now told to put local configuration.
- **Two names are configurable in two places** — `EVAL_JUDGE` is in `stack/dev.env`
  (committed, `heuristic`) and may be overridden in `secrets.env`. `check-docs.py
  [dev-env-duplicates]` cannot see across the two files, so nothing catches a name declared
  in both; the precedence is defined (the credentials file is read last and only fills what
  is still unset, so `dev.env` wins) and that is the opposite of what a reader might guess.
  Named here rather than fixed because the alternative — forbidding the overlap — would
  stop `secrets.env` overriding the committed default, which is the point of it.
- **`stack/secrets.env.example` now ships `CHAT_MODEL=bedrock`.** A person who copies the
  template and fills in keys gets a real model, which is what they were asking for and is
  also a bill. The comment above it says so.

## Alternatives considered

- **Auto-select `bedrock` when credentials are present.** What the reported behaviour
  suggests should happen, and rejected: it makes a stack start spending money because a
  gitignored file appeared, and it removes the ability to hold credentials while
  deliberately running `echo` — which is how every cheap local run and every CI run works.
- **Declare `CHAT_MODEL` in `stack/dev.env`.** Committed, so every machine and CI would get
  the same value; `echo` there is already the effective default and `bedrock` there would
  break CI.
- **A fourth file for non-secret local overrides.** Correct on purity — modes are not
  secrets — and rejected because the request was explicitly for *one* file, and a fourth
  would be one more place to look when something does not take effect.
- **Have `chatbot-backend` stop defaulting `CHAT_MODEL` under `environment:`** so `env_file`
  could supply it. It is the cleanest fix and it is not available: that compose file must
  keep working standalone with no `.env`, and it is a product repo this session may not
  edit.

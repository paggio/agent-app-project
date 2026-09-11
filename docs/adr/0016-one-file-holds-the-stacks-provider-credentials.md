# 0016 — One gitignored file holds the joined stack's provider credentials

**Status:** accepted
**Date:** 2026-09-09
**Relation to 0006:** completes it. 0006 decided what the joined stack may READ and in what
order, and deferred one question — "read `.env` for every submodule? Rejected as premature;
when the second one exists, generalise then." The second one now exists, and the
generalisation is not the one 0006 imagined.

## Context

`make eval JUDGE=bedrock` failed:

```
Could not load credentials to authenticate with AWS client. Please check that the
specified profile name and/or its credentials are valid. Service error: You must
specify a region.
```

The credentials were fine. `chatbot-eval/.env` held `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`, and compose's `env_file` delivered all
three. What it did not hold was a **region**, and boto3 resolves one from the environment or
refuses — reporting it inside a message that leads with "could not load credentials", which
sends a reader to look at the credentials.

`chatbot-backend/.env` happened to carry `AWS_REGION` and `AWS_DEFAULT_REGION`, so the
backend called Bedrock successfully from the same stack. One consumer worked and the other
did not, for a reason neither file made visible, and the eval shipped no `.env.example` to
name the missing variable in. Nothing asserted any of it: `changes/0006`'s brief put "the
judge, judging" under *A gap in the oracle* because it needs credentials the loop must not
require — and a criterion in that list is a criterion nobody checks.

Underneath the bug is a structural problem the bug is a symptom of. Credentials lived **per
product repo**, so:

- a second consumer meant a second copy, and a third would mean a third;
- each copy is an independent chance to omit something, which is exactly what happened;
- nothing could answer "is this stack configured for Bedrock?" without opening two
  gitignored files in two repos.

The constraint that makes this non-obvious is 0006's, and it is not negotiable: **a
credential must never enter a control-repo process.** This repo writes `verify.json`,
`smoke.json`, container logs and repair prompts, so a value in the environment of the
process that writes them is one careless dump from being committed. That is why
`dev-env.sh` has an allowlist of non-secret names and why AWS credentials are deliberately
absent from it.

So the tempting generalisation — teach `dev-env.sh` to read every submodule's `.env` — is
the wrong direction. It pulls secrets *toward* the harness process.

## Decision

**`stack/secrets.env` is the joined stack's single source of provider credentials. It is
gitignored, and compose's `env_file` is its only reader.**

1. **One file, at the stack level**, with `stack/secrets.env.example` committed beside it as
   the template. `stack/dev.env` remains the committed non-secret configuration; the two
   files are split by whether a value can be committed, which is a line anybody can apply.

2. **Delivered by `env_file:` in `stack/compose.yml`**, to every service that may call a
   provider, `required: false` so a fresh clone and CI come up with none and run
   credential-free. Nothing in `scripts/` reads it, and **`dev-env.sh` naming it is a gate
   failure** — that clause is the load-bearing one, because it is what preserves 0006's
   property while moving the file.

3. **It layers on top of a submodule's own `.env` rather than replacing it.** Measured in a
   two-file reproduction rather than inferred from the manual, the way 0006 measured its own
   precedence: compose **appends** `env_file` across `include:`, and the stack-level entry
   **wins** on a shared name while the submodule's other names still arrive. So
   `cd chatbot-backend && make up` keeps working from that repo's own file, and the joined
   stack takes its values from here.

   The full order, highest first: `environment:` in compose → the real process environment →
   `stack/secrets.env` → `<submodule>/.env`.

4. **The region is part of the credential set, and its absence is a named failure.**
   `secrets.env.example` declares `AWS_REGION` and `AWS_DEFAULT_REGION` with real defaults
   and a comment saying why the failure reads as a credentials error, and
   `check-docs.py [provider-credentials]` refuses a template that omits the region.

5. **`make creds` answers "is this configured, and from where"** in one command, printing
   names and provenance and never a value. It exists because the failure above cost a run
   and could not be diagnosed from any single place.

6. **`stack/dev.env` is grouped by service and free of prose.** It had grown to 179 lines,
   most of it commentary, and a reader could not see which variable configured which
   service. Two parser traps are now gates rather than lore: a name declared twice resolves
   to the FIRST (`[dev-env-duplicates]`, which already cost a run), and a trailing comment
   becomes part of the value because the parser strips nothing
   (`[dev-env-inline-comments]`, added because making the file terse is exactly what invites
   one).

## Consequences

**Makes easy.** One place to put credentials, one command to check them, and `make up`,
`make eval`, `make iterate` and the loop all pick them up with no extra step. A second
provider consumer costs a line in `PROVIDER_SERVICES` rather than a new copy of the secrets.
And the split between `dev.env` and `secrets.env` is decided by a question with an
unambiguous answer — can this be committed? — instead of by judgement.

**Accepted costs.**

- **`PROVIDER_SERVICES` is a fifth hand-kept list**, after the four `docs/adr/0013` already
  counted. A service absent from it is silently ungated. Named in the check itself, and it
  is the same trade `IMAGE_TAG_OWNERS` makes.
- **A credential file now sits in the control repo's own tree.** 0006 kept them entirely
  inside the product repos, and this is a real narrowing of that separation. What holds the
  property is that no process here reads it — enforced, not intended — plus `.gitignore` by
  name, checked with `git check-ignore` rather than by eye.
- **Two places can still supply a credential**, because a submodule's `.env` keeps working
  and must, for standalone runs. So "where did this value come from" has two answers, and
  `make creds` exists precisely because the answer stopped being obvious. The alternative —
  forbidding the per-repo files — would break every product repo's own `make up`.
- **The example file carries a plausible default region**, which is a value in a committed
  file. It is not a secret and the alternative is an empty variable that fails the same way
  the original bug did.
- **It does not make `EVAL_JUDGE=bedrock` assertable in the loop.** Nothing can: the loop
  must run without credentials. The gap `changes/0006`'s brief recorded is unchanged, and
  this ADR only removes the configuration mistake that made the gap bite. `make eval
  JUDGE=bedrock` and `make creds` are the oracle, and they are a person's to run.

## Alternatives considered

- **Teach `dev-env.sh` to read every submodule `.env`.** 0006's own deferred option, and
  the wrong direction: it pulls credentials into the environment of the process that writes
  this repo's run artifacts, which is the one thing 0006 exists to prevent.
- **Leave credentials per repo and just add `AWS_REGION` to `chatbot-eval/.env`.** Fixes the
  symptom in ten seconds and leaves the structure that produced it — N copies, N chances to
  omit one, nothing able to answer whether the stack is configured.
- **Put the credentials in `stack/dev.env` and gitignore that file.** Rejected: it is
  committed and must stay committed, because it is the declared source of every `${VAR}` a
  smoke suite interpolates and CI has no secrets at all.
- **A single `AWS_PROFILE` and a mounted `~/.aws`.** Genuinely tidier for a developer, and
  rejected because it does not survive the destination: a k8s Job has no home directory and
  takes its identity from a service account. Environment variables are what both ends
  understand.
- **Have the eval read a region from its own settings and default it.** Rejected for the
  reason `image_tag` is never derived: a default region is a guess that succeeds in the
  wrong account, and a refusal naming the variable is strictly better than a call to
  somewhere nobody chose.

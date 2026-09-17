# 0018 — Exactly one script may hold a credential, and it is the one that writes nothing

**Status:** accepted
**Date:** 2026-09-17
**Relation to 0016:** amends it. 0016's file stays exactly as it is and nothing here reads
it. What is amended is the absolute in 0006 that 0016 restates — *a credential must never
enter a control-repo process* — which now has one named exception with a mechanical boundary.

## Context

The `dev` environment is a company AWS account. Deploying it from GitHub Actions needs
credentials in the repository's Actions secrets, and a long-lived access key for a company
account must not sit in a private repo's secret store — not because the store is weak, but
because the key outlives every context anybody reasoned about when creating it.

Identity Center already issues short-lived session credentials for that account
(`sample-agent-dev` → `AdministratorAccess`, one hour by default). So the credential that
reaches GitHub can be a *session*: it expires on its own, and nothing long-lived is ever
created. Something has to carry it from the SSO cache to GitHub, and that something is a
script in this repo — which 0006 and 0016 forbid.

The prohibition is not arbitrary and it is not about trust. Its reason is stated in 0016:

> This repo writes `verify.json`, `smoke.json`, container logs and repair prompts, so a
> value in the environment of the process that writes them is one careless dump from being
> committed.

That reason is about **what the process does with what it holds**, not about the process's
address. A script that holds a credential and writes no artifact, logs nothing, and exits is
outside the failure the rule exists to prevent. The rule was written as a property of the
repo because, until now, every process here wrote something.

Two facts made this concrete rather than theoretical. The credentials pasted into
`stack/secrets.env` by hand were already expired when first checked — `ExpiredToken` from
`sts get-caller-identity` — and so was the SSO session behind them. Hand-carried credentials
rot, silently, and the local stack fails in a way that reads as a Bedrock problem.

## Decision

**One script may hold a credential: `scripts/push-gh-creds.sh`. It is permitted because it
writes nothing, and that is enforced rather than intended.**

1. **The credential's whole life is one pipe.** `aws configure export-credentials` on one
   end, `gh secret set` reading stdin on the other. Never a file — not a temp file, not a
   dotenv, not `gh secret set --env-file`. Never argv, which is world-readable through `ps`,
   which is why `--body` is absent and stdin is used instead. Never a shell variable that
   outlives one pipeline. The only thing the script will say about a credential is its name.

2. **It reads the SSO profile, not `stack/secrets.env`.** 0016's rule that no script here
   names that file is untouched, and stays enforced by
   `check-docs.py [provider-credentials]`. The two files have nothing to do with each other:
   one is for the Docker daemon, this is for GitHub.

3. **`check-docs.py [credential-handling]` is the boundary.** Only
   `scripts/push-gh-creds.sh` may name `export-credentials`; that file may not contain
   `set -x`, may not pipe a credential to `tee`, and may not redirect one to a file. A second
   script acquiring credentials is a gate failure, so the exception cannot spread by
   imitation — which is the failure mode of every exception written as prose.

4. **Only a SESSION is pushable.** The script refuses a profile that exports no
   `Expiration`, so static keys cannot be laundered through it, and it refuses to push an
   already-expired session — pushing one is worse than pushing nothing, because the deploy workflow
   would take it at face value and die in the middle of an apply.

5. **The expiry is published as a VARIABLE, not a secret.** `AWS_CREDS_EXPIRY` and
   `AWS_REGION` are repository variables so a workflow can print them in a refusal. A
   deployment that stops with "these credentials expired at 14:02, run `make login && make
   push-gh-creds`" costs a minute; one that stops with an opaque AWS error mid-apply costs
   an afternoon and possibly a half-applied environment.

6. **`scripts/secrets-refresh.sh` writes a credential to disk, and is the stated exception
   to the exception.** It rewrites the five AWS names in `stack/secrets.env` from the same
   profile. That file is the one place in this repo whose entire job is to hold a credential;
   it is gitignored by name and checked with `git check-ignore`; and the script writes it
   0600 through a temp file rather than a truncating redirect. It exists because the
   alternative — pasting from the console — is what produced the expired file above. It
   touches only those five names, so `CHAT_MODEL` and `EVAL_JUDGE` survive a refresh, which
   ADR 0017 requires.

## Consequences

**Makes easy.** `make login` once, then `make push-gh-creds` and `make secrets-refresh`, and
both the cloud deploy and the local Bedrock stack are working from the same session with the
same expiry. There is no long-lived credential for this account anywhere in the system, and
no step where one could be created by accident.

**Accepted costs.**

- **The credentials expire, and re-pushing is manual.** This is the direct cost of refusing
  a long-lived key, and it is paid every session. GitHub OIDC removes it entirely — it stores
  no credential at all, only a role ARN — and was rejected for this environment, so this ADR
  is the place that records what that choice costs. The trigger to revisit is a the deploy workflow
  that routinely outruns the session, or the first time an expired secret wastes a debugging
  hour.
- **The session length is not ours to set.** It is the Identity Center permission set's
  `SessionDuration`, and the directory is company-managed, so the real ceiling may be one
  hour and may not be raisable. That number bounds how long a single the deploy workflow may take,
  which is a design constraint on the workflow rather than a preference.
- **Anything that can read the repo's Actions secrets can deploy as an administrator of that
  account for the remaining lifetime of the session.** The blast radius is bounded by the
  expiry and by nothing else. `AdministratorAccess` is what the profile grants; a narrower
  deploy role would be better and is deferred, not rejected.
- **The absolute is gone.** "No credential in a control-repo process" was a rule you could
  check by reading a file list. It is now a rule with an exception, and an exception is
  something a future reader has to be told about. The gate is the mitigation: the boundary
  is a check that fails, not a paragraph somebody has to remember.
- **Two scripts now know how to acquire a credential**, and one of them writes to disk. They
  are named here, named in the check, and named in `CLAUDE.md`, which is three places to keep
  in step — the same trade `PROVIDER_SERVICES` and `IMAGE_TAG_OWNERS` already make.

## Alternatives considered

- **GitHub OIDC with an IAM role.** Strictly better on every axis that matters here: nothing
  is stored, nothing expires mid-run, nothing is rotated, and the trust policy can be
  conditioned on repository and branch. It needs an OIDC provider created in the company
  account, which is possible with `AdministratorAccess` but may be blocked by an
  organisation SCP. Rejected for this iteration by preference, not by obstacle, and it is
  the first thing to reach for when the manual re-push becomes annoying.
- **Keep the absolute and have a human paste the secrets into the GitHub UI.** No script
  holds a credential, and the rule survives intact. Rejected because it is the same
  hand-carrying that produced an expired `stack/secrets.env`, performed three times per
  session, with no mechanism able to say whether what is stored is current.
- **A long-lived IAM user with a narrow deploy policy.** Removes the expiry problem
  completely, and is what most projects do. Rejected on the stated requirement: no long-lived
  credential for a company account in a private repo's secrets.
- **Let `dev-env.sh` acquire and export the credentials.** Rejected for 0006's original
  reason, undiminished: that process is the one that writes `verify.json`, `smoke.json` and
  repair prompts, and the exception above is available precisely because
  `push-gh-creds.sh` writes none of them.
- **Push the credentials as an environment secret with a required reviewer.** A real
  improvement to the blast radius, and deferred rather than rejected — it belongs with the
  narrower deploy role, and both are cheaper to add once the deploy workflow exists and is boring.

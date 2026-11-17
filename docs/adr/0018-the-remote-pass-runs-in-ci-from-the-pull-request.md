# 0018 — The remote pass runs in CI, against one `dev` environment, from the pull request

**Status:** accepted
**Date:** 2026-09-23
**Relation to 0004:** supersedes §1's *where* (the local loop applies) and §7's lock. Keeps
everything about *what* the remote pass asserts: the plan gate, outputs-vs-contract, the
image-tag cross-check, the same suite asserted twice, `destroy` never called by a loop.

## Context

ADR 0004 put `terraform apply` inside the local verify loop. That made the control session
the most privileged session in the system, made every repair attempt a real apply, and was
only ever reachable in theory: `infra/` stayed a scaffold. 0004 listed "deploy from CI only"
as the right end state, deferred until the environment mattered.

It matters now. There is one AWS account — a company one, reached through IAM Identity
Center — and it is treated as `dev`. Long-lived AWS keys must not sit in GitHub. The
deploy has to run in GitHub Actions and be triggered from the pull request under review.
Every repo is private on GitHub Free, which has no Environments: no environment secrets,
no environment variables, no protection rules.

## Decision

1. **One environment, `dev`.** `ENVIRONMENTS = ("dev",)`. `staging` never existed and
   goes. `prod` stays absent; `release-prod.yml` exists, refuses any ref but `main`, and
   deploys nothing yet.

2. **The remote pass moves out of `verify.sh` into `scripts/verify-remote.sh`**, which
   `.github/workflows/dev-push.yml` runs. Same stages as 0004 — publish, plan (exit 3
   refused), deploy, outputs vs contract, cross-check, readiness, the suites with
   `--exclude-tag local` — and it writes `verify-remote.json` with the same fields
   `verify.json` has. `verify.sh` keeps the local pass only. The local loop's best
   outcome is therefore `verified-local`; **`verified` is minted only by a green
   `dev-push` run**, and its evidence is that run's artifact.

3. **`/dev-push` is a pull-request comment, and the lanes use it too.** On the control
   PR of a change, or on a product repo's PR for a single-repo change. `/dev-push-<repo>`
   (`backend`, `frontend`, `infra`) rebuilds only that repo and *carries* the others at
   what `dev` already runs; its outcome is `deployed-partial`, never `verified`.
   `scripts/dev-push.sh` posts the same comment, waits for the run and prints its verdict,
   so a lane and a human trigger the one path.

4. **What is deployed is resolved, never assumed from the gitlinks.** Mid-change the
   gitlinks point at the last merged `main` and the change lives on `feat/<change>`
   (concept.md §6). `scripts/deploy-set.py` turns the trigger into `{repo: sha}`:

   | Trigger | Slice repos | Every other repo |
   | --- | --- | --- |
   | control PR of a change | head of `feat/<change>` on the remote | the PR head's gitlink |
   | product PR | that PR's head | control `main`'s gitlink |
   | no PR (`--lock`) | — | the gitlinks of the control ref under test |

   It exits 2 when a slice branch is not pushed, or when a gitlink and `repos.lock`
   disagree. The set is posted on the PR and uploaded as `deploy-set.json`.

5. **Images are built in CI, tagged with the full 40-character SHA, into immutable ECR
   repositories.** (12 until change 0009: a semantic release is named by the commit that
   built it, and a 12-character tag is not one.) A tag that already exists is not rebuilt. Each repo owns its
   `Dockerfile`; the control workflow builds them because it is the only place that can
   see every repo at the resolved SHAs.

6. **Credentials are pushed, short-lived, and used once.** `make login` is `aws sso login`
   plus a rewrite of the credential lines in `stack/secrets.env` — its only writer besides
   a human, and it prints no value. `make push-gh-creds` copies that session and its
   expiry into **repository** secrets of every repo that can trigger a deploy, named
   `DEV_AWS_*` so the environment survives in the name GitHub Free gives it nowhere else.
   Every job refuses (exit 2) with under 30 minutes left, then immediately assumes
   `agentapp-dev-deployer` — least privilege, created by bootstrap — and uses nothing else.
   A chained role session lasts at most an hour, so `verify-remote.sh` re-assumes it from
   the pushed session before each stage that reaches AWS; a run that outlives the pushed
   session fails there as `fault: harness`.

7. **Cross-repo access is read-only deploy keys**, one per repo, created by
   `make gh-setup` through the API. `dev-push.yml` is reusable (`workflow_call`); a
   product repo's workflow is a caller of a few lines.

8. **One deploy at a time:** `concurrency: env-dev`, never cancelled in progress. It
   replaces `.locks/` for anything that reaches AWS. A concurrency group is per
   repository, so a product repo's run is not serialised against the control repo's: the
   Terraform state lock serialises their applies, and `verify-remote.sh` re-reads what
   `dev` runs after the suite and fails (`fault: harness`) if it was replaced underneath.

9. **Bootstrap is the one manual apply**, local, with `make login` credentials:
   `make -C infra bootstrap ENV=dev` — state bucket (native S3 locking), ECR, the deployer
   role, a $100/month budget, the CUR 2.0 export. It survives teardown and costs cents.

10. **Teardown is one command, from either side:** `make dev-down` locally or the
    `dev-down` workflow. Both run `make -C infra destroy ENV=dev CONFIRM=dev`, then
    `make -C infra leftovers ENV=dev`, which lists billable resources still tagged for
    `dev` and exits 1 if there are any. `dev` forgets its data on `down`, exactly as the
    local stack does (ADR 0011). No loop calls either.

11. **After a merge, the realign PR is deployed from the lock** — every repo at its
    gitlinks, the bump under review — and the baseline asserted remotely. Squash merges
    mint new SHAs, so the images a PR verified are never the merged ones; this run is what
    makes "shipped" (ADR 0002) true of merged code. *Amended 2026-09-24:* `/realign` no
    longer starts it; the user comments `/dev-push`. *Reverted 2026-10-12:* `/realign`
    starts it again, as `/ship` does, and the user is asked to review only once it is
    green. A human gate on every deploy made "green" a hand-off rather than a result. It
    comments `/dev-push` on the realign PR (`dev-push.sh --lock --pr`), then `/dev-eval`
    (§13), so every run a lane starts is visible in the PR.

12. **Every AWS resource is tagged** through provider `default_tags`: `Project=agentapp`,
    `Environment=dev`, `ManagedBy=terraform`, `Repository=<infra|bootstrap>`. A
    tag-based Resource Group lists them.

13. **`/dev-eval` on a PR runs `chatbot-eval` against what `dev` runs** (added 2026-09-24).
    `dev-eval.yml`, same guard and credentials as `dev-push.yml`; its own concurrency group, since
    sharing `env-dev` would let a queued eval cancel a queued deploy — it re-reads what `dev`
    runs afterwards instead, and refuses if that changed.
    The eval commit is resolved like a deploy set (§4); the backend is whatever `dev`
    runs, read from `deployed-set.json` and named in the comment, with a warning when it is
    not this PR's. It runs on the runner, judged by Bedrock under the deployer role, and
    files the experiment in `dev`'s Phoenix (`phoenix_base_url`, bearer from
    `phoenix_api_key_secret_ref`). Exit 0 thresholds met · 1 breached · 2 refused (no
    state, no Phoenix outputs, no session). It deploys nothing.

## Consequences

`verified` now means the PR's exact SHAs ran together in AWS and both suites held through
the CloudFront origin. The control session never holds deploy credentials for a loop.

Accepted costs:

- **No automatic repair against `dev`.** A red `dev-push` is a `/ship-correct` lane,
  routed by `owners_failing` in `verify-remote.json` — one apply per human-visible attempt.
- **Pushed credentials carry the SSO role's rights until they expire.** The deployer role
  narrows what a job does, not what a leaked secret could do. The user chose this over
  OIDC; revisit if the session duration grows or the account stops being a sandbox.
- **`make push-gh-creds` before each working session.** Expired credentials are an exit 2
  naming the command, never a failed deploy routed to `infra`.
- **The workflow runs PR code with deploy credentials, and no Environment gates it.**
  Gated to comments by `OWNER`/`MEMBER`/`COLLABORATOR`; tolerable because every repo is
  private and single-owner.
- **The comment carries the dev sign-in**: app and Phoenix URLs, users, and the operator
  password, read from Secrets Manager. PR only — masked in the log, absent from the step
  summary and the artifact. Tolerable: private repos, a dev-only account.
- **Workflow changes take effect only once merged**: `issue_comment` runs `main`'s file.
- **`dev` is shared and last-writer-wins.** A `/dev-push` replaces what another PR
  deployed; the comment names what it replaced.
- **A concurrency group holds one pending run.** A third `/dev-push` queued behind a
  running one cancels the second, which never runs. `dev-push.sh` identifies its run by
  `trigger.json`, so a cancelled one is never mistaken for a verdict — re-comment.
- **About $0.30/hour while up** (EKS, NAT, nodes, RDS, ALB). `dev-down` when idle.
- **A linked account cannot activate cost-allocation tags**, and myApplications no longer
  creates applications. Cost is read from a CUR 2.0 data export (bootstrap) queried in
  Athena by resource id.

## Alternatives considered

- **GitHub OIDC role.** No stored secret and one-hour tokens per job; the stronger design,
  rejected by the user in favour of pushed session credentials. One trust policy away.
- **Keep the apply in the local loop (0004).** Rejected for the privileges and the cost
  per repair attempt above.
- **Each product repo builds and pushes its own image.** Cleaner ownership, but a deploy
  would then wait on N pipelines it cannot see, and a missing image would surface as a
  failed rollout instead of a refused build.
- **Deploy on every push.** Rejected: one shared environment, and a deploy is a decision.

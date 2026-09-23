# 0004 — Deploying to a real environment inside the verify loop

**Status:** accepted — where the remote pass runs, and its lock, superseded by 0018
**Date:** 2026-08-20
**Relation to 0002:** extends it. Nothing in 0002 is superseded; its costs were written for
a Docker-only world, and the costs below are of a different kind.

## Context

ADR 0002 §4 decided that "the infra path is a contract before it is an implementation":
when `deploy.infra: true`, verify runs `make -C infra deploy` then `make -C infra outputs`
and checks the produced JSON against `contracts/infra-outputs.yaml`. That was the right
shape, and the checker and the fail-loudly gate were built. Three things were not:

- **`contracts/infra-outputs.yaml` promised nothing** (`outputs: {}`), so the check it
  gated returned 0 with "promises nothing yet; none of them checkable".
- **The remote assertion path was a comment describing code that did not exist.**
  `verify.sh` said infra-tagged steps "reach [the deployed environment] via `${...}`
  variables resolved from the environment, which the outputs above are exported into." The
  only `export` in `scripts/` was in `dev-env.sh`. The outputs were written to a file that
  only the checker read, and the stage ran against `--base "$BASE"` — localhost. It also
  dropped `--contract` and dropped the change's configured timeout.
- **Nothing carried an `infra` tag**, in any suite, so the stage selected zero steps and
  `smoke.py` returned `ok: true` over an empty set.

So the infra path was simultaneously unreachable (the infra repo has no `Makefile`, which
correctly hard-fails) and, had it been reachable, vacuous.

Meanwhile a fourth gap had no owner at all: **nothing publishes the application images.**
`make -C infra deploy` cannot build the app — that repo has no access to application source
and must not have any. Without a publish step the remote pass asserts whatever image is
already deployed, while the local pass asserts the code under test.

## Decision

**A change that deploys reaches a real environment inside the same loop, and the same smoke
suite is asserted twice: against the local stack, then against the deployed origin.**

The alternative — apply, then assert separately — was rejected because the gap between the
two is precisely where "deployed but never asserted" lives, which is the failure ADR 0002
exists to prevent.

1. **Terraform**, and the environment lives in the invocation:
   `make -C infra deploy ENV=staging`, `make -C infra outputs ENV=staging`. The contract
   stays one flat map of names, so the checker needs no second code path, and the names are
   invariant while only the values move. Terraform's `output -json` *is* the flat object
   the checker already wanted, which is most of why it was chosen over CDK or Pulumi; the
   accepted cost is a state backend.

2. **The infra interface is six Make targets** — `plan`, `deploy`, `outputs`, `bootstrap`,
   `destroy`, and the usual `fmt`/`validate`/`lint`. `outputs` prints a flat JSON object on
   stdout and *nothing else*; a single stray `echo` in the recipe corrupts it into the
   parse-failure path. `ENV` has no default, because a default `ENV` is how prod gets
   applied by a typo.

3. **`plan` gates `deploy` by exit code.** 0 is additive, 3 contains a destroy or replace
   and is refused unless `--allow-destroy`. This is the single most important guardrail
   here: it stands between "a repair agent rewrote a module on attempt 2" and "the database
   was replaced". The exit code rather than the control repo parsing `terraform show -json`,
   so Terraform-schema knowledge stays inside the repo that owns it — at the cost of a
   narrow channel that cannot say *which* resource, which the saved plan answers.

4. **The control repo publishes images**, tagged with the submodule SHA, because it is the
   only place that can see both submodules at once. The infra repo then promises
   `deployed_backend_image` and `deployed_frontend_image`, and verify asserts their tags
   equal the SHAs it just verified locally, before the remote pass runs. That check is what
   makes "the remote pass asserted the code under test" a machine-checked fact instead of an
   assumption.

5. **Only `kind: value` outputs are exported** into the environment a suite can
   interpolate, as `INFRA_*`. A secret reference is promised by name and never becomes
   interpolable into a request body. The export is written as a *product* of the passing
   check, so the exported set is exactly the checked set.

6. **`deploy.infra: true` implies `--max-attempts 1`** unless a human overrides. Automatic
   repair that costs a real apply per attempt is a different product from automatic repair
   that costs a container rebuild.

7. **An environment lock, held for the whole run.** Terraform's state lock prevents state
   corruption; it does not prevent two runs interleaving their smoke data against one
   origin.

8. **`prod` is not in the allowlist.** What actually stops a production deploy is
   credentials — the harness's role can assume the staging role and nothing else. The
   allowlist, the `CONFIRM=` requirement on `destroy`, and the loop's refusal to call
   `destroy` under any flag are guardrails against absent-mindedness, in the same sense
   `.claude/hooks/no-subrepo-edits.sh` says of itself. They are not a security boundary and
   must not be read as one.

## Consequences

A green `verified` now means the repos were deployed together to a real environment and the
acceptance criteria held through the origin a browser would use. `verified-local` exists for
runs that skipped that, so a report can never claim a remote verification that did not
happen.

Accepted costs — these are the ones ADR 0002 could not have named:

- **A repair attempt is a real `terraform apply`,** with a real bill and a real blast
  radius. Bounded attempts stop being a convenience and become a spend control. Mitigated
  by the attempt budget of 1, the plan gate, and skipping the apply on attempt 2+ when the
  infra slice has not moved.
- **Terraform state is a serialisation point.** Two changes cannot iterate against one
  environment concurrently — a constraint the parallel-fanout model otherwise permits.
- **The control session becomes the most privileged session in the system.** ADR 0001
  deliberately made it powerless: it edits documents and dispatches. It now holds deploy
  credentials. This is the largest single change to the threat model in this repo's history,
  and it is the reason `prod` is absent and the reason credentials rather than allowlists are
  named as the real control.
- **The fast inner loop is gone for the infra part.** `verify.sh --keep-up` plus
  `stack.sh rebuild` has no analogue for a cloud apply.
- **A failed apply can leave the environment partially changed,** and there is no
  `compose down -v` equivalent. Teardown is a declared target that the loop never calls, so
  a broken environment is a human's problem by design.
- **`contracts/infra-outputs.yaml` is now load-bearing,** so a fourth contract type needs
  the same freeze discipline as `openapi.yaml`: one commit, alone, recorded as `freeze_sha`.
- **The remote suite mutates a shared environment.** It creates one account per run, and
  cleaning that up needs a delete surface the contract does not have — so it is a later
  change, and until then staging accumulates rows. Identities are namespaced with a run
  nonce and confined to `smoke-*@auth.test` (`.test` is RFC 2606 reserved) so a smoke run
  can never collide with a real user, and verify refuses a remote pass when `SIGNUP_CODE`
  came from the committed local placeholder.
- **The rate limiter is asserted locally only.** Its buckets are per-process, so above one
  replica the effective limit multiplies and the 429 may never arrive. Asserting it remotely
  would make the suite flake as a function of replica count, which looks like a security
  regression. The trigger to revisit is the limiter moving to a shared store.
- **A green run is not an infrastructure audit.** Nothing here asserts IAM
  least-privilege, cost, multi-AZ, backups, TLS cipher policy or WAF. Those belong to the
  infra repo's own CI (`tfsec`, `checkov`) and to review. Stated explicitly because
  `verified` is a strong word and someone will read more into it than it says.

## Alternatives considered

- **CDK or Pulumi.** CDK shares TypeScript with the frontend, which is a real benefit. But
  `terraform output -json` is exactly the flat JSON object `infra-outputs.py` already
  demands, and a `terraform plan` is a stronger review artifact than `cdk diff`. Rejected on
  the strength of the plan gate, which is the guardrail this design leans on hardest.
- **Two loops: apply, then smoke separately.** Cheaper and safer per invocation. Rejected
  because the gap between them is where "deployed but never asserted" lives.
- **Deploy from CI only, never from a developer's loop.** The right end state, and deferred
  rather than rejected. It removes the loop's ability to repair, and repair is the mechanism
  ADR 0002 is built around. Revisit when the environment matters enough that a human should
  be the one to press the button — at which point this ADR is superseded, not amended.
- **An `environments:` block in the contract.** Rejected: it lets staging promise less than
  prod, which institutionalises the drift it claims to describe. The contract is schema;
  environments are data.
- **Let the loop tear down a failed environment.** Rejected. `destroy` is the one operation
  whose blast radius exceeds the value of any automation, and a partially-applied
  environment is evidence.
